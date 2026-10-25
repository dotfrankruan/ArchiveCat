//
//  ArchiveFileSystemTests.swift
//  ArchiveCoreTests
//
//  The read-only virtual filesystem: enumeration, resolution, identity,
//  metadata, unsafe-path exclusion, and bounded content access.
//
//  The point of these tests is that browsing an archive is a pure metadata
//  operation: no payload is read, no file is written, and a hostile path can
//  never appear as a browsable node.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("virtual archive filesystem")
struct ArchiveFileSystemTests {

    // MARK: - Fixtures

    /// A small tree with every node shape that matters:
    /// explicit dirs, an implicit dir, an empty dir, a symlink and duplicates.
    private func makeDocument(
        in workspace: TempWorkspace,
        extra: [FixtureEntry] = []
    ) async throws -> (url: URL, document: ArchiveDocument) {
        var entries: [FixtureEntry] = [
            .directory("docs/"),
            .directory("empty/"),
            .file("docs/readme.txt", "hello from docs"),
            // `docs/guides` is never stored: it exists only by implication.
            .file("docs/guides/deep.txt", "deep"),
            .file("root.txt", "root file"),
            .symlink("link", to: "docs/readme.txt"),
        ]
        entries.append(contentsOf: extra)
        let url = try workspace.writeArchive(entries, format: .tar)
        let document = try await ArchiveSession().open(url: url)
        return (url, document)
    }

    // MARK: - Enumeration

    @Test("root lists directories before entries, in archive order")
    func rootEnumeration() async throws {
        let workspace = TempWorkspace()
        let (_, document) = try await makeDocument(in: workspace)
        let vfs = ArchiveFileSystem(document: document)

        let children = vfs.children(ofDirectoryAt: "")
        let names = children.map(\.name)

        #expect(names == ["docs", "empty", "root.txt", "link"])
        #expect(children[0].isDirectory)
        #expect(children[1].isDirectory)
        #expect(children[2].isFile)
        #expect(children[3].isFile)
        // Enumeration is deterministic: a second call returns the same order.
        #expect(vfs.children(ofDirectoryAt: "").map(\.id) == children.map(\.id))
    }

    @Test("children of a directory, and of an empty directory")
    func nestedEnumeration() async throws {
        let workspace = TempWorkspace()
        let (_, document) = try await makeDocument(in: workspace)
        let vfs = ArchiveFileSystem(document: document)

        let docs = vfs.children(ofDirectoryAt: "docs")
        #expect(docs.map(\.name) == ["guides", "readme.txt"])
        #expect(docs[0].isImplicitDirectory)

        #expect(vfs.children(ofDirectoryAt: "empty").isEmpty)
        #expect(vfs.children(ofDirectoryAt: "does/not/exist").isEmpty)
    }

    @Test("subdirectories only")
    func subdirectories() async throws {
        let workspace = TempWorkspace()
        let (_, document) = try await makeDocument(in: workspace)
        let vfs = ArchiveFileSystem(document: document)

        #expect(vfs.subdirectories(ofDirectoryAt: "").map(\.name) == ["docs", "empty"])
        #expect(vfs.subdirectories(ofDirectoryAt: "docs").map(\.name) == ["guides"])
    }

    // MARK: - Resolution

    @Test("resolve a file, an explicit directory, an implicit directory and the root")
    func resolution() async throws {
        let workspace = TempWorkspace()
        let (_, document) = try await makeDocument(in: workspace)
        let vfs = ArchiveFileSystem(document: document)

        let root = try #require(vfs.node(at: ""))
        #expect(root.isRoot)
        #expect(root.isDirectory)
        #expect(root.name == document.fileName)

        let file = try #require(vfs.node(at: "docs/readme.txt"))
        #expect(file.kind == .file)
        #expect(file.entry?.path == "docs/readme.txt")

        let explicitDirectory = try #require(vfs.node(at: "docs"))
        #expect(explicitDirectory.kind == .directory)
        #expect(!explicitDirectory.isImplicitDirectory)
        #expect(explicitDirectory.entry != nil)

        let implicitDirectory = try #require(vfs.node(at: "docs/guides"))
        #expect(implicitDirectory.kind == .directory)
        #expect(implicitDirectory.isImplicitDirectory)
        #expect(implicitDirectory.entry == nil)

        #expect(vfs.node(at: "docs/missing.txt") == nil)
        #expect(vfs.contains("docs/readme.txt"))
        #expect(!vfs.contains("docs/missing.txt"))
        #expect(vfs.isDirectory(at: "docs/guides"))
        #expect(!vfs.isDirectory(at: "docs/readme.txt"))
    }

    @Test("breadcrumb walks from the root to the current directory")
    func breadcrumb() async throws {
        let workspace = TempWorkspace()
        let (_, document) = try await makeDocument(in: workspace)
        let vfs = ArchiveFileSystem(document: document)

        let crumbs = vfs.breadcrumb(to: "docs/guides")
        #expect(crumbs.map(\.path) == ["", "docs", "docs/guides"])
        #expect(crumbs.first?.isRoot == true)
    }

    // MARK: - Metadata

    @Test("metadata is the entry the archive stored, including mode and date")
    func metadata() async throws {
        let workspace = TempWorkspace()
        var executable = FixtureEntry.file("bin/tool", "#!/bin/sh\necho hi\n", mode: 0o755)
        executable.modificationDate = Date(timeIntervalSince1970: 1_600_000_000)
        let url = try workspace.writeArchive([executable], format: .tar)
        let document = try await ArchiveSession().open(url: url)
        let vfs = ArchiveFileSystem(document: document)

        let entry = try #require(vfs.metadata(at: "bin/tool"))
        #expect(entry.posixMode == 0o755)
        #expect(entry.modificationDate?.timeIntervalSince1970 == 1_600_000_000)
        #expect((entry.uncompressedSize ?? 0) > 0)
        #expect(vfs.directoryEntry(atDirectoryPath: "bin") == nil, "the bin/ directory was implied, not stored")

        let impliedBin = try #require(vfs.node(at: "bin"))
        #expect(impliedBin.isImplicitDirectory)
        #expect(impliedBin.entry == nil)
    }

    // MARK: - Duplicates

    @Test("duplicate paths stay distinct nodes with distinct identities")
    func duplicatePaths() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("dup.txt", "first"),
            .file("dup.txt", "second"),
        ], format: .tar)
        let document = try await ArchiveSession().open(url: url)
        let vfs = ArchiveFileSystem(document: document)

        let duplicates = vfs.nodes(at: "dup.txt")
        #expect(duplicates.count == 2)
        #expect(Set(duplicates.map(\.id)).count == 2)
        #expect(duplicates.map(\.entry?.id.ordinal) == [0, 1])
        // `node(at:)` is documented to return the first occurrence.
        #expect(vfs.node(at: "dup.txt")?.entry?.ordinal == 0)
        // Both appear in the parent listing, as they do in the archive.
        #expect(vfs.children(ofDirectoryAt: "").filter { $0.path == "dup.txt" }.count == 2)
    }

    // MARK: - Unsafe entries

    @Test("a traversal entry is reported but never becomes a browsable node")
    func unsafeEntryExcluded() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("safe.txt", "safe"),
            .file("../../escape.txt", "escape"),
        ], format: .tar)
        let document = try await ArchiveSession().open(url: url)
        let vfs = ArchiveFileSystem(document: document)

        #expect(vfs.contains("../../escape.txt") == false)
        #expect(vfs.node(at: "../../escape.txt") == nil)
        #expect(vfs.children(ofDirectoryAt: "").map(\.name) == ["safe.txt"])
        #expect(document.unsafeEntries.count == 1)
        #expect(document.unsafeEntries.first?.rawPath == "../../escape.txt")
    }

    // MARK: - Capabilities

    @Test("ZIP reports random access; a gzip-wrapped TAR reports a stream")
    func readingCapabilities() async throws {
        let workspace = TempWorkspace()
        let zipURL = try workspace.writeArchive([.file("a.txt", "a")], format: .zip, named: "c")
        let targzURL = try workspace.writeArchive([.file("a.txt", "a")], format: .tarGzip, named: "c")

        let zipDocument = try await ArchiveSession().open(url: zipURL)
        let targzDocument = try await ArchiveSession().open(url: targzURL)

        let zipCapabilities = ArchiveCapabilities.reading(format: zipDocument.format)
        let targzCapabilities = ArchiveCapabilities.reading(format: targzDocument.format)

        #expect(zipCapabilities.canRead)
        #expect(zipCapabilities.canExtract)
        #expect(zipCapabilities.canCreate == false, "reading a format never implies creating it")
        #expect(zipCapabilities.supportsRandomAccess)
        #expect(zipCapabilities.supportsStreamingReads)

        #expect(!targzCapabilities.supportsRandomAccess)
        #expect(targzCapabilities.limitation?.contains("stream") == true)
    }

    @Test("archive-name heuristic recognises compound extensions")
    func archiveCandidateHeuristic() {
        #expect(ArchiveFormatCatalog.isArchiveCandidate(fileName: "backup.zip"))
        #expect(ArchiveFormatCatalog.isArchiveCandidate(fileName: "backup.tar.gz"))
        #expect(ArchiveFormatCatalog.isArchiveCandidate(fileName: "BACKUP.TAR"))
        #expect(!ArchiveFormatCatalog.isArchiveCandidate(fileName: "notes.txt"))
        #expect(!ArchiveFormatCatalog.isArchiveCandidate(fileName: "zipper.doc"))
    }

    @Test("VFS flags only archive-looking files as nested candidates")
    func nestedCandidates() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("artifacts/"),
            .file("artifacts/backup.tar.gz", "not really an archive"),
            .file("artifacts/readme.md", "docs"),
        ], format: .tar)
        let document = try await ArchiveSession().open(url: url)
        let vfs = ArchiveFileSystem(document: document)

        let backup = try #require(vfs.node(at: "artifacts/backup.tar.gz"))
        let readme = try #require(vfs.node(at: "artifacts/readme.md"))
        #expect(vfs.isArchiveCandidate(backup))
        #expect(!vfs.isArchiveCandidate(readme))
        #expect(!vfs.isArchiveCandidate(vfs.root))
    }

    // MARK: - Content access

    @Test("readEntryData returns exactly the requested member, and honours the cap")
    func boundedContentRead() async throws {
        let workspace = TempWorkspace()
        let first = String(repeating: "A", count: 4096)
        let second = String(repeating: "B", count: 8192)
        let url = try workspace.writeArchive([
            .file("first.txt", first),
            .file("second.txt", second),
        ], format: .tar)
        let session = ArchiveSession()
        let document = try await session.open(url: url)

        let firstEntry = try #require(document.entries.first { $0.name == "first.txt" })
        let secondEntry = try #require(document.entries.first { $0.name == "second.txt" })

        // Reading the second entry must not return the first one's bytes.
        let headOfSecond = try await session.readEntryData(secondEntry, maxBytes: 64)
        #expect(headOfSecond.count == 64)
        #expect(headOfSecond.allSatisfy { $0 == UInt8(ascii: "B") })

        // A cap smaller than the member truncates rather than failing.
        let partial = try await session.readEntryData(firstEntry, maxBytes: 100)
        #expect(partial.count == 100)

        // A cap larger than the member returns the whole member.
        let whole = try await session.readEntryData(firstEntry, maxBytes: 1_000_000)
        #expect(whole.count == 4096)
    }

    @Test("reading a duplicate path uses the entry's ordinal, not its name")
    func contentReadUsesOrdinal() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("dup.txt", "FIRST-CONTENT"),
            .file("dup.txt", "SECOND-CONTENT"),
        ], format: .tar)
        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let nodes = ArchiveFileSystem(document: document).nodes(at: "dup.txt")
        #expect(nodes.count == 2)

        let first = try #require(nodes.first?.entry)
        let second = try #require(nodes.last?.entry)

        let firstBytes = try await session.readEntryData(first, maxBytes: 64)
        let secondBytes = try await session.readEntryData(second, maxBytes: 64)
        #expect(String(decoding: firstBytes, as: UTF8.self) == "FIRST-CONTENT")
        #expect(String(decoding: secondBytes, as: UTF8.self) == "SECOND-CONTENT")
    }

    @Test("reading an unsafe entry is refused")
    func contentReadRefusesUnsafeEntry() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("../../escape.txt", "escape"),
        ], format: .tar)
        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let unsafeEntry = try #require(document.unsafeEntries.first)

        await #expect(throws: ArchiveError.self) {
            _ = try await session.readEntryData(unsafeEntry, maxBytes: 10)
        }
    }

    // MARK: - Performance

    @Test("enumeration stays proportional to the directory, not the archive")
    func enumerationPerformance() async throws {
        let workspace = TempWorkspace()
        var entries: [FixtureEntry] = []
        for directory in 0..<100 {
            entries.append(.directory("dir\(directory)/"))
            for file in 0..<20 {
                entries.append(.file("dir\(directory)/file\(file).txt", "x"))
            }
        }
        let url = try workspace.writeArchive(entries, format: .tar)
        let document = try await ArchiveSession().open(url: url)
        let vfs = ArchiveFileSystem(document: document)
        #expect(document.entries.count == 2100)

        let started = ContinuousClock.now
        for _ in 0..<500 {
            #expect(vfs.children(ofDirectoryAt: "").count == 100)
            #expect(vfs.node(at: "dir42") != nil)
        }
        let elapsed = ContinuousClock.now - started

        // Generous bound: this is a regression guard against enumeration walking
        // the whole entry list, not a micro-benchmark.
        #expect(elapsed < .seconds(2), "500 root listings + lookups took \(elapsed)")
    }
}
