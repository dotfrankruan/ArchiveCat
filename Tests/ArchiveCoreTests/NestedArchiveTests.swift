//
//  NestedArchiveTests.swift
//  ArchiveCoreTests
//
//  Archives inside archives: materialisation, limits, pinning, reuse and cleanup.
//
//  Every test opens real nested archives built by the fixture writer, then reads
//  them back through the normal engine — there is no mocked filesystem and no
//  special-cased path.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("nested archives")
struct NestedArchiveTests {

    // MARK: - Fixtures

    /// Bytes of a small TAR.GZ that contains one text file.
    private func innerTarGzBytes(in workspace: TempWorkspace, text: String = "nested payload") throws -> Data {
        let url = try workspace.writeArchive([
            .file("inside.txt", text),
            .directory("folder/"),
        ], format: .tarGzip, named: "inner")
        return try Data(contentsOf: url)
    }

    /// An archive whose only member is another archive.
    private func makeOuterArchive(
        in workspace: TempWorkspace,
        memberName: String,
        memberBytes: Data,
        format: FixtureFormat = .zip
    ) throws -> URL {
        try workspace.writeArchive([
            .directory("artifacts/"),
            FixtureEntry(path: "artifacts/\(memberName)", kind: .file, contents: memberBytes),
            .file("readme.md", "outer archive"),
        ], format: format)
    }

    private func makeStore(in workspace: TempWorkspace, options: NestedArchiveOptions? = nil) throws -> NestedArchiveStore {
        let cache = workspace.makeDirectory("nested-cache")
        if let options {
            var custom = options
            custom.cacheDirectory = cache
            return try NestedArchiveStore(options: custom)
        }
        return try NestedArchiveStore(options: NestedArchiveOptions(cacheDirectory: cache))
    }

    private func openNested(
        store: NestedArchiveStore,
        entryPath: String,
        session: ArchiveSession,
        document: ArchiveDocument,
        depth: Int = 0
    ) async throws -> OpenedNestedArchive {
        let vfs = ArchiveFileSystem(document: document)
        let entry = try #require(vfs.node(at: entryPath)?.entry)
        return try await store.open(entry: entry, document: document, session: session, depth: depth)
    }

    // MARK: - Opening

    @Test("ZIP inside ZIP opens and browses without touching the parent")
    func zipInsideZip() async throws {
        let workspace = TempWorkspace()
        let innerURL = try workspace.writeArchive([
            .file("inside.txt", "found me"),
        ], format: .zip, named: "inner")
        let innerBytes = try Data(contentsOf: innerURL)

        let outerURL = try makeOuterArchive(in: workspace, memberName: "inner.zip", memberBytes: innerBytes)
        let bytesBefore = try Data(contentsOf: outerURL)

        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace)
        let nested = try await openNested(
            store: store,
            entryPath: "artifacts/inner.zip",
            session: session,
            document: document
        )

        #expect(nested.depth == 1)
        #expect(nested.document.entries.contains { $0.path == "inside.txt" })

        let nestedVFS = ArchiveFileSystem(document: nested.document)
        #expect(nestedVFS.children(ofDirectoryAt: "").map(\.name) == ["inside.txt"])

        // Reading through the nested session works like any other archive.
        let entry = try #require(nested.document.entries.first { $0.path == "inside.txt" })
        let data = try await nested.session.readEntryData(entry, maxBytes: 64)
        #expect(String(decoding: data, as: UTF8.self) == "found me")

        // Extraction from the nested archive works too.
        let destination = workspace.makeDirectory("extracted")
        let report = try await nested.session.extract(
            entries: [entry],
            to: destination,
            options: ExtractionOptions(conflictPolicy: .replace)
        )
        #expect(report.failures.isEmpty)
        #expect(workspace.contents(at: "extracted/inside.txt").map { String(decoding: $0, as: UTF8.self) } == "found me")

        // Obligatory invariant: opening a nested archive never modifies the
        // parent archive.
        let bytesAfter = try Data(contentsOf: outerURL)
        #expect(bytesAfter == bytesBefore)

        // The parent is still browsable after the nested level was created.
        #expect(ArchiveFileSystem(document: document).children(ofDirectoryAt: "").count >= 2)

        await store.release(cacheKey: nested.cacheKey)
        _ = await store.purgeExpired(now: Date().addingTimeInterval(optionsAge()))
    }

    @Test("TAR.GZ inside ZIP opens")
    func tarGzInsideZip() async throws {
        let workspace = TempWorkspace()
        let bytes = try innerTarGzBytes(in: workspace)
        let outerURL = try makeOuterArchive(in: workspace, memberName: "backup.tar.gz", memberBytes: bytes)

        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace)
        let nested = try await openNested(
            store: store,
            entryPath: "artifacts/backup.tar.gz",
            session: session,
            document: document
        )

        #expect(nested.document.entries.contains { $0.name == "inside.txt" })
        await store.release(cacheKey: nested.cacheKey)
    }

    @Test("three levels of nesting open in order")
    func deepNesting() async throws {
        let workspace = TempWorkspace()

        let deepestURL = try workspace.writeArchive([.file("bottom.txt", "bottom")], format: .tar, named: "deepest")
        let deepestBytes = try Data(contentsOf: deepestURL)

        let middleURL = try workspace.writeArchive([
            FixtureEntry(path: "deepest.tar", kind: .file, contents: deepestBytes),
        ], format: .tarGzip, named: "middle")
        let middleBytes = try Data(contentsOf: middleURL)

        let outerURL = try makeOuterArchive(in: workspace, memberName: "middle.tar.gz", memberBytes: middleBytes)

        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace, options: NestedArchiveOptions(cacheDirectory: workspace.url, maximumDepth: 3))

        let levelOne = try await openNested(
            store: store,
            entryPath: "artifacts/middle.tar.gz",
            session: session,
            document: document,
            depth: 0
        )
        #expect(levelOne.depth == 1)

        let levelTwo = try await openNested(
            store: store,
            entryPath: "deepest.tar",
            session: levelOne.session,
            document: levelOne.document,
            depth: levelOne.depth
        )
        #expect(levelTwo.depth == 2)
        #expect(levelTwo.document.entries.contains { $0.path == "bottom.txt" })

        await store.release(cacheKey: levelTwo.cacheKey)
        await store.release(cacheKey: levelOne.cacheKey)
    }

    // MARK: - Limits

    @Test("the nesting depth limit is enforced")
    func depthLimit() async throws {
        let workspace = TempWorkspace()
        let deepestURL = try workspace.writeArchive([.file("bottom.txt", "bottom")], format: .tar, named: "deepest")
        let deepestBytes = try Data(contentsOf: deepestURL)
        let middleURL = try workspace.writeArchive([
            FixtureEntry(path: "deepest.tar", kind: .file, contents: deepestBytes),
        ], format: .tarGzip, named: "middle")
        let middleBytes = try Data(contentsOf: middleURL)
        let outerURL = try makeOuterArchive(in: workspace, memberName: "middle.tar.gz", memberBytes: middleBytes)

        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace, options: NestedArchiveOptions(cacheDirectory: workspace.url, maximumDepth: 2))

        let levelOne = try await openNested(
            store: store,
            entryPath: "artifacts/middle.tar.gz",
            session: session,
            document: document,
            depth: 0
        )
        let levelTwo = try await openNested(
            store: store,
            entryPath: "deepest.tar",
            session: levelOne.session,
            document: levelOne.document,
            depth: levelOne.depth
        )

        // Opening level three would exceed maximumDepth == 2.
        let deepestEntry = try #require(levelTwo.document.entries.first { $0.path == "bottom.txt" })
        await #expect(throws: ArchiveError.self) {
            _ = try await store.open(
                entry: deepestEntry,
                document: levelTwo.document,
                session: levelTwo.session,
                depth: levelTwo.depth
            )
        }

        await store.release(cacheKey: levelTwo.cacheKey)
        await store.release(cacheKey: levelOne.cacheKey)
    }

    @Test("a member larger than the per-member cap is refused")
    func memberSizeLimit() async throws {
        let workspace = TempWorkspace()
        // The inner archive itself is comfortably larger than 1 KiB.
        let innerURL = try workspace.writeArchive([
            .file("big.bin", bytes: 8192),
        ], format: .tar, named: "big")
        let innerBytes = try Data(contentsOf: innerURL)
        #expect(innerBytes.count > 1024)

        let outerURL = try makeOuterArchive(in: workspace, memberName: "big.tar", memberBytes: innerBytes)
        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(
            in: workspace,
            options: NestedArchiveOptions(cacheDirectory: workspace.url, maximumMemberBytes: 1024)
        )

        await #expect(throws: ArchiveError.self) {
            _ = try await openNested(
                store: store,
                entryPath: "artifacts/big.tar",
                session: session,
                document: document
            )
        }
        let sizeAfterRefusal = await store.currentSize()
        #expect(sizeAfterRefusal == 0, "nothing should be materialised when the cap refuses it")
    }

    @Test("the total temporary budget is enforced")
    func totalBudgetLimit() async throws {
        let workspace = TempWorkspace()
        let innerURL = try workspace.writeArchive([.file("payload.bin", bytes: 16_384)], format: .tar, named: "payload")
        let innerBytes = try Data(contentsOf: innerURL)
        let outerURL = try makeOuterArchive(in: workspace, memberName: "payload.tar", memberBytes: innerBytes)

        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(
            in: workspace,
            options: NestedArchiveOptions(cacheDirectory: workspace.url, totalBudgetBytes: 2048)
        )

        await #expect(throws: ArchiveError.self) {
            _ = try await openNested(
                store: store,
                entryPath: "artifacts/payload.tar",
                session: session,
                document: document
            )
        }
        let sizeAfterBudgetRefusal = await store.currentSize()
        #expect(sizeAfterBudgetRefusal == 0)
    }

    // MARK: - Failures

    @Test("a corrupt nested archive reports a typed failure and leaves no cache entry")
    func corruptNestedArchive() async throws {
        let workspace = TempWorkspace()
        let outerURL = try makeOuterArchive(
            in: workspace,
            memberName: "broken.zip",
            memberBytes: Data("this is definitely not a zip file".utf8)
        )
        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace)

        await #expect(throws: ArchiveError.self) {
            _ = try await openNested(
                store: store,
                entryPath: "artifacts/broken.zip",
                session: session,
                document: document
            )
        }
        let sizeAfterFailure = await store.currentSize()
        let pinnedAfterFailure = await store.pinnedKeys()
        #expect(sizeAfterFailure == 0, "a failed materialisation must not be cached")
        #expect(pinnedAfterFailure.isEmpty)
    }

    @Test("an unsupported nested format reports a typed failure")
    func unsupportedNestedFormat() async throws {
        let workspace = TempWorkspace()
        let outerURL = try makeOuterArchive(
            in: workspace,
            memberName: "mystery.rar",
            memberBytes: Data(repeating: 0x99, count: 512)
        )
        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace)

        await #expect(throws: ArchiveError.self) {
            _ = try await openNested(
                store: store,
                entryPath: "artifacts/mystery.rar",
                session: session,
                document: document
            )
        }
    }

    @Test("a directory is not openable as a nested archive")
    func directoryIsNotNestedArchive() async throws {
        let workspace = TempWorkspace()
        let outerURL = try makeOuterArchive(
            in: workspace,
            memberName: "inner.zip",
            memberBytes: try innerTarGzBytes(in: workspace)
        )
        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace)
        let directoryEntry = try #require(ArchiveFileSystem(document: document).node(at: "artifacts")?.entry)

        await #expect(throws: ArchiveError.self) {
            _ = try await store.open(entry: directoryEntry, document: document, session: session, depth: 0)
        }
    }

    // MARK: - Cache behaviour

    @Test("reopening the same member reuses the materialised file")
    func cacheReuse() async throws {
        let workspace = TempWorkspace()
        let bytes = try innerTarGzBytes(in: workspace)
        let outerURL = try makeOuterArchive(in: workspace, memberName: "backup.tar.gz", memberBytes: bytes)

        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace)

        let first = try await openNested(
            store: store,
            entryPath: "artifacts/backup.tar.gz",
            session: session,
            document: document
        )
        let sizeAfterFirst = await store.currentSize()
        #expect(sizeAfterFirst > 0)

        let second = try await openNested(
            store: store,
            entryPath: "artifacts/backup.tar.gz",
            session: session,
            document: document
        )
        #expect(second.url == first.url)
        let sizeAfterSecond = await store.currentSize()
        #expect(sizeAfterSecond == sizeAfterFirst, "reuse must not duplicate the materialised file")

        await store.release(cacheKey: first.cacheKey)
        await store.release(cacheKey: second.cacheKey)
        let pinnedAfterRelease = await store.pinnedKeys()
        #expect(pinnedAfterRelease.isEmpty)
    }

    @Test("a pinned level survives purge; releasing allows removal")
    func pinningProtectsLiveLevels() async throws {
        let workspace = TempWorkspace()
        let bytes = try innerTarGzBytes(in: workspace)
        let outerURL = try makeOuterArchive(in: workspace, memberName: "backup.tar.gz", memberBytes: bytes)

        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace)
        let nested = try await openNested(
            store: store,
            entryPath: "artifacts/backup.tar.gz",
            session: session,
            document: document
        )

        let pinned = await store.pinnedKeys()
        #expect(pinned == [nested.cacheKey])
        await store.purgeAll()
        #expect(FileManager.default.fileExists(atPath: nested.url.path(percentEncoded: false)))

        // The live session still works after the purge attempt.
        let entry = try #require(nested.document.entries.first { $0.path == "inside.txt" })
        _ = try await nested.session.readEntryData(entry, maxBytes: 32)

        await store.release(cacheKey: nested.cacheKey)
        await store.purgeAll()
        #expect(!FileManager.default.fileExists(atPath: nested.url.path(percentEncoded: false)))
        let sizeAfterPurge = await store.currentSize()
        #expect(sizeAfterPurge == 0)
    }

    @Test("expired unreferenced entries are purged")
    func expiry() async throws {
        let workspace = TempWorkspace()
        let bytes = try innerTarGzBytes(in: workspace)
        let outerURL = try makeOuterArchive(in: workspace, memberName: "backup.tar.gz", memberBytes: bytes)

        let session = ArchiveSession()
        let document = try await session.open(url: outerURL)
        let store = try makeStore(in: workspace)
        let nested = try await openNested(
            store: store,
            entryPath: "artifacts/backup.tar.gz",
            session: session,
            document: document
        )

        await store.release(cacheKey: nested.cacheKey)
        let removed = await store.purgeExpired(now: Date().addingTimeInterval(48 * 60 * 60))
        #expect(removed == 1)
        let sizeAfterExpiry = await store.currentSize()
        #expect(sizeAfterExpiry == 0)
    }

    // MARK: - Helpers

    private func optionsAge() -> TimeInterval {
        48 * 60 * 60
    }
}
