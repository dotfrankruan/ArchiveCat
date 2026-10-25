//
//  CompressionTests.swift
//  ArchiveCoreTests
//
//  Archive creation, end to end.
//
//  Two rules shape these tests:
//
//   * every created archive is validated by reopening it through the normal
//     reading engine, and file contents are compared by hash — not by trusting
//     the writer;
//   * the safety properties are asserted directly: no absolute paths, no
//     followed symlinks, no partial output, no silent overwrite.
//

import CryptoKit
import Foundation
import Testing

@testable import ArchiveCore

@Suite("archive creation")
struct CompressionTests {

    // MARK: - Helpers

    private let service = CompressionService()

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a tree:
    ///   project/
    ///     README.md
    ///     source/main.swift
    ///     source/nested/util.swift
    ///     empty-folder/
    ///     ünïcode.txt
    ///     no-extension
    private func makeProjectTree(in workspace: TempWorkspace) throws -> URL {
        let project = workspace.makeDirectory("project")
        try Data("# Project\n".utf8).write(to: project.appendingPathComponent("README.md"))

        let source = project.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("print(\"main\")\n".utf8).write(to: source.appendingPathComponent("main.swift"))

        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("// util\n".utf8).write(to: nested.appendingPathComponent("util.swift"))

        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("empty-folder", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("unicode\n".utf8).write(to: project.appendingPathComponent("ünïcode.txt"))
        try Data("no extension\n".utf8).write(to: project.appendingPathComponent("no-extension"))
        return project
    }

    private func scan(_ url: URL) async throws -> (session: ArchiveSession, document: ArchiveDocument) {
        let session = ArchiveSession()
        let document = try await session.open(url: url)
        return (session, document)
    }

    private func paths(in document: ArchiveDocument) -> Set<String> {
        Set(document.entries.map(\.path))
    }

    /// Extracts a single member and returns its bytes.
    private func bytes(of path: String, from document: ArchiveDocument, session: ArchiveSession, in workspace: TempWorkspace) async throws -> Data {
        let entry = try #require(document.entries.first { $0.path == path })
        let destination = workspace.makeDirectory("verify-\(UUID().uuidString.prefix(8))")
        let report = try await session.extract(
            entries: [entry],
            to: destination,
            options: ExtractionOptions(conflictPolicy: .replace)
        )
        #expect(report.failures.isEmpty)
        return try Data(contentsOf: destination.appendingPathComponent(path))
    }

    private func partialFiles(in directory: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return contents.filter { $0.hasSuffix(".partial") }
    }

    // MARK: - ZIP

    @Test("single file → ZIP → reopened with identical bytes")
    func singleFileZip() async throws {
        let workspace = TempWorkspace()
        let payload = Data(repeating: 0x41, count: 12_345)
        let source = workspace.path("payload.bin")
        try payload.write(to: source)

        let destination = workspace.path("out.zip")
        let result = try await service.compress(
            sources: [source],
            to: destination,
            options: CompressionOptions(formatID: "zip")
        )

        #expect(result.fileCount == 1)
        #expect(result.directoryCount == 0)
        #expect(result.archiveBytes > 0)
        #expect(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(partialFiles(in: workspace.url).isEmpty)

        let (session, document) = try await scan(destination)
        #expect(paths(in: document) == ["payload.bin"])
        let verified = try await bytes(of: "payload.bin", from: document, session: session, in: workspace)
        #expect(verified == payload)
    }

    @Test("multiple files → ZIP keeps each at the root")
    func multipleFilesZip() async throws {
        let workspace = TempWorkspace()
        let one = try workspace.write("one", to: "one.txt")
        let two = try workspace.write("two", to: "two.txt")
        let destination = workspace.path("both.zip")

        let result = try await service.compress(
            sources: [one, two],
            to: destination,
            options: CompressionOptions(formatID: "zip")
        )
        #expect(result.fileCount == 2)

        let (_, document) = try await scan(destination)
        #expect(paths(in: document) == ["one.txt", "two.txt"])
        #expect(document.entries.allSatisfy { $0.type == .regularFile })
    }

    @Test("directory → ZIP preserves the hierarchy, empty folders and unicode names")
    func directoryZip() async throws {
        let workspace = TempWorkspace()
        let project = try makeProjectTree(in: workspace)
        let destination = workspace.path("project.zip")

        let result = try await service.compress(
            sources: [project],
            to: destination,
            options: CompressionOptions(formatID: "zip")
        )
        #expect(result.directoryCount >= 4)

        let (session, document) = try await scan(destination)
        let paths = paths(in: document)

        #expect(paths.contains("project/README.md"))
        #expect(paths.contains("project/source/main.swift"))
        #expect(paths.contains("project/source/nested/util.swift"))
        #expect(paths.contains("project/empty-folder"))
        #expect(paths.contains("project/ünïcode.txt"))
        #expect(paths.contains("project/no-extension"))

        // Content is byte-identical.
        let readme = try await bytes(of: "project/README.md", from: document, session: session, in: workspace)
        #expect(String(decoding: readme, as: UTF8.self) == "# Project\n")
    }

    // MARK: - TAR.GZ

    @Test("directory → TAR.GZ → reopened with metadata and structure intact")
    func directoryTarGz() async throws {
        let workspace = TempWorkspace()
        let project = try makeProjectTree(in: workspace)

        // Give one file a distinctive mode and date so preservation is visible.
        let script = project.appendingPathComponent("source/main.swift")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: script.path(percentEncoded: false))

        let destination = workspace.path("project.tar.gz")
        let result = try await service.compress(
            sources: [project],
            to: destination,
            options: CompressionOptions(formatID: "tar.gz", compressionLevel: 6)
        )
        #expect(result.fileCount >= 5)
        #expect(result.archiveBytes > 0)

        let (session, document) = try await scan(destination)
        #expect(document.entries.contains { $0.path == "project/source/nested/util.swift" })

        let entry = try #require(document.entries.first { $0.path == "project/source/main.swift" })
        #expect(entry.posixMode == 0o755, "tar preserves the executable bit")
        #expect(entry.modificationDate?.timeIntervalSince1970 == 1_600_000_000)

        let bytesOfMain = try await bytes(
            of: "project/source/main.swift",
            from: document,
            session: session,
            in: workspace
        )
        #expect(String(decoding: bytesOfMain, as: UTF8.self) == "print(\"main\")\n")
    }

    @Test("all advertised creatable formats round-trip")
    func everyCreatableFormatRoundTrips() async throws {
        let workspace = TempWorkspace()
        let source = try workspace.write("round trip", to: "value.txt")

        for descriptor in ArchiveFormatCatalog.creatableFormats {
            let destination = workspace.path("round-trip-\(descriptor.id).\(descriptor.fileExtension)")
            let result = try await service.compress(
                sources: [source],
                to: destination,
                options: CompressionOptions(formatID: descriptor.id)
            )
            #expect(result.formatID == descriptor.id)

            let (session, document) = try await scan(destination)
            #expect(document.entries.contains { $0.path == "value.txt" }, "\(descriptor.id) should contain the file")
            let data = try await bytes(of: "value.txt", from: document, session: session, in: workspace)
            #expect(String(decoding: data, as: UTF8.self) == "round trip")
        }
    }

    // MARK: - Selection semantics

    @Test("duplicate basenames from different folders are disambiguated, not merged")
    func duplicateBasenames() async throws {
        let workspace = TempWorkspace()
        let first = workspace.makeDirectory("first")
        let second = workspace.makeDirectory("second")
        let firstFile = first.appendingPathComponent("src")
        let secondFile = second.appendingPathComponent("src")
        try Data("from first".utf8).write(to: firstFile)
        try Data("from second".utf8).write(to: secondFile)

        let destination = workspace.path("duplicates.zip")
        let result = try await service.compress(
            sources: [firstFile, secondFile],
            to: destination,
            options: CompressionOptions(formatID: "zip")
        )
        #expect(!result.warnings.isEmpty)

        let (session, document) = try await scan(destination)
        #expect(paths(in: document) == ["src", "src 2"])

        // Both copies are intact; neither overwrote the other.
        let firstBytes = try await bytes(of: "src", from: document, session: session, in: workspace)
        let secondBytes = try await bytes(of: "src 2", from: document, session: session, in: workspace)
        #expect(String(decoding: firstBytes, as: UTF8.self) == "from first")
        #expect(String(decoding: secondBytes, as: UTF8.self) == "from second")
    }

    @Test("two selected folders with the same name become “name” and “name 2”")
    func sameNamedFolders() async throws {
        let workspace = TempWorkspace()
        let parentA = workspace.makeDirectory("a")
        let parentB = workspace.makeDirectory("b")
        let folderA = parentA.appendingPathComponent("shared", isDirectory: true)
        let folderB = parentB.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try Data("A".utf8).write(to: folderA.appendingPathComponent("a.txt"))
        try Data("B".utf8).write(to: folderB.appendingPathComponent("b.txt"))

        let destination = workspace.path("shared.zip")
        _ = try await service.compress(
            sources: [folderA, folderB],
            to: destination,
            options: CompressionOptions(formatID: "zip")
        )

        let (_, document) = try await scan(destination)
        let paths = paths(in: document)
        #expect(paths.contains("shared/a.txt"))
        #expect(paths.contains("shared 2/b.txt"))
    }

    @Test("overlapping selections archive a child exactly once")
    func overlappingSelection() async throws {
        let workspace = TempWorkspace()
        let project = try makeProjectTree(in: workspace)
        let readme = project.appendingPathComponent("README.md")

        let destination = workspace.path("overlap.zip")
        _ = try await service.compress(
            sources: [project, readme],
            to: destination,
            options: CompressionOptions(formatID: "zip")
        )

        let (_, document) = try await scan(destination)
        let readmeCount = document.entries.filter { $0.path == "project/README.md" }.count
        #expect(readmeCount == 1)
        // The child was covered by the folder, so it is not added at the root.
        #expect(!document.entries.contains { $0.path == "README.md" })
    }

    // MARK: - Symlinks

    @Test("symlinks are stored as links and never followed")
    func symlinkPolicy() async throws {
        let workspace = TempWorkspace()
        let tree = workspace.makeDirectory("tree")
        try Data("real content".utf8).write(to: tree.appendingPathComponent("real.txt"))

        // One link inside the tree, one pointing far outside it.
        try FileManager.default.createSymbolicLink(
            atPath: tree.appendingPathComponent("inside-link").path(percentEncoded: false),
            withDestinationPath: "real.txt"
        )
        try FileManager.default.createSymbolicLink(
            atPath: tree.appendingPathComponent("outside-link").path(percentEncoded: false),
            withDestinationPath: "/etc/passwd"
        )

        let destination = workspace.path("links.tar.gz")
        let result = try await service.compress(
            sources: [tree],
            to: destination,
            options: CompressionOptions(formatID: "tar.gz")
        )
        #expect(result.symlinkCount == 2)
        #expect(result.fileCount == 1)

        let (_, document) = try await scan(destination)
        let inside = try #require(document.entries.first { $0.path == "tree/inside-link" })
        let outside = try #require(document.entries.first { $0.path == "tree/outside-link" })

        #expect(inside.type == .symbolicLink)
        #expect(inside.symlinkTarget == "real.txt")
        #expect(outside.type == .symbolicLink)
        #expect(outside.symlinkTarget == "/etc/passwd")
        // The *contents* of /etc/passwd must not have been read into the archive.
        #expect(!document.entries.contains { $0.path.contains("passwd") && $0.type == .regularFile })
        #expect(document.entries.filter { $0.type == .regularFile }.count == 1)
    }

    @Test("a symlink loop does not make the walk recurse")
    func symlinkLoop() async throws {
        let workspace = TempWorkspace()
        let tree = workspace.makeDirectory("loop")
        try Data("x".utf8).write(to: tree.appendingPathComponent("x.txt"))
        let sub = tree.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // sub/back → .. forms a cycle if followed.
        try FileManager.default.createSymbolicLink(
            atPath: sub.appendingPathComponent("back").path(percentEncoded: false),
            withDestinationPath: ".."
        )

        let destination = workspace.path("loop.zip")
        let result = try await service.compress(
            sources: [tree],
            to: destination,
            options: CompressionOptions(formatID: "zip")
        )
        #expect(result.symlinkCount == 1)
        let (_, document) = try await scan(destination)
        #expect(document.entries.count <= 6)
    }

    // MARK: - Safety

    @Test("archive paths are relative and never leak the source location")
    func noAbsolutePaths() async throws {
        let workspace = TempWorkspace()
        let project = try makeProjectTree(in: workspace)
        let destination = workspace.path("paths.tar")
        _ = try await service.compress(
            sources: [project],
            to: destination,
            options: CompressionOptions(formatID: "tar")
        )

        let (_, document) = try await scan(destination)
        let workspacePath = workspace.url.path(percentEncoded: false)
        for entry in document.entries {
            #expect(!entry.path.hasPrefix("/"), "\(entry.path) must be relative")
            #expect(!entry.path.contains(workspacePath), "\(entry.path) must not contain the source path")
            #expect(!entry.path.contains("/Users/"), "\(entry.path) must not contain a home directory")
        }
        #expect(document.entries.contains { $0.path == "project/source/main.swift" })
    }

    @Test("an existing destination is never replaced silently")
    func refusesToOverwrite() async throws {
        let workspace = TempWorkspace()
        let source = try workspace.write("new content", to: "value.txt")
        let destination = workspace.path("existing.zip")
        let original = Data("do not touch me".utf8)
        try original.write(to: destination)

        await #expect(throws: ArchiveError.self) {
            _ = try await self.service.compress(
                sources: [source],
                to: destination,
                options: CompressionOptions(formatID: "zip")
            )
        }

        let surviving = try Data(contentsOf: destination)
        #expect(surviving == original, "the existing file must be untouched")
        #expect(partialFiles(in: workspace.url).isEmpty)
    }

    @Test("replacing is allowed only when the caller confirms it")
    func overwriteWhenConfirmed() async throws {
        let workspace = TempWorkspace()
        let source = try workspace.write("new content", to: "value.txt")
        let destination = workspace.path("existing.zip")
        try Data("old".utf8).write(to: destination)

        let result = try await service.compress(
            sources: [source],
            to: destination,
            options: CompressionOptions(formatID: "zip", overwriteExisting: true)
        )
        #expect(result.archiveBytes > 0)

        let (_, document) = try await scan(destination)
        #expect(paths(in: document) == ["value.txt"])
    }

    @Test("a missing source fails before anything is written")
    func missingSource() async throws {
        let workspace = TempWorkspace()
        let destination = workspace.path("missing.zip")
        let ghost = workspace.path("ghost.txt")

        await #expect(throws: ArchiveError.self) {
            _ = try await self.service.compress(
                sources: [ghost],
                to: destination,
                options: CompressionOptions(formatID: "zip")
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test("an unreadable source fails without leaving a partial archive")
    func unreadableSource() async throws {
        // Root can read anything, so the test is meaningless there.
        try #require(geteuid() != 0)

        let workspace = TempWorkspace()
        let source = try workspace.write("secret", to: "locked.txt")
        let destination = workspace.path("locked.zip")
        let sourcePath = source.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sourcePath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourcePath) }

        await #expect(throws: ArchiveError.self) {
            _ = try await self.service.compress(
                sources: [source],
                to: destination,
                options: CompressionOptions(formatID: "zip")
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(partialFiles(in: workspace.url).isEmpty, "the temporary output must be removed")
    }

    // MARK: - Streaming, progress and cancellation

    @Test("a large file streams through with identical bytes")
    func largeFileRoundTrip() async throws {
        let workspace = TempWorkspace()
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<(4 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let source = workspace.path("large.bin")
        try payload.write(to: source)

        let destination = workspace.path("large.zip")
        let result = try await service.compress(
            sources: [source],
            to: destination,
            options: CompressionOptions(formatID: "zip")
        )
        #expect(result.sourceBytes == Int64(payload.count))

        let (session, document) = try await scan(destination)
        let extracted = try await bytes(of: "large.bin", from: document, session: session, in: workspace)
        #expect(extracted.count == payload.count)
        #expect(sha256(extracted) == sha256(payload))
    }

    @Test("progress is monotonic and ends at the total")
    func progressReporting() async throws {
        let workspace = TempWorkspace()
        let project = try makeProjectTree(in: workspace)
        let destination = workspace.path("progress.zip")

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var samples: [CompressionProgress] = []
            func append(_ progress: CompressionProgress) {
                lock.lock(); samples.append(progress); lock.unlock()
            }
            func snapshot() -> [CompressionProgress] {
                lock.lock(); defer { lock.unlock() }; return samples
            }
        }
        let recorder = Recorder()

        let result = try await service.compress(
            sources: [project],
            to: destination,
            options: CompressionOptions(formatID: "zip")
        ) { progress in
            recorder.append(progress)
        }

        let samples = recorder.snapshot()
        #expect(!samples.isEmpty)
        let final = try #require(samples.last)
        #expect(final.completedItems == result.itemCount)
        #expect(final.completedBytes == final.totalBytes)
        #expect(final.fractionCompleted == 1)

        // Bytes never go backwards.
        var previous: Int64 = 0
        for sample in samples {
            #expect(sample.completedBytes >= previous)
            previous = sample.completedBytes
        }
    }

    @Test("cancellation stops the operation and leaves nothing behind")
    func cancellation() async throws {
        let workspace = TempWorkspace()
        // Big enough that cancellation lands mid-run, small enough to be quick.
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<(16 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let source = workspace.path("cancel.bin")
        try payload.write(to: source)
        let destination = workspace.path("cancelled.zip")

        let task = Task {
            try await self.service.compress(
                sources: [source],
                to: destination,
                options: CompressionOptions(formatID: "zip")
            )
        }
        // Give the writer time to start, then cancel.
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()

        let error = await task.result
        switch error {
        case .success:
            // A very fast machine may finish before cancellation lands; then the
            // archive must at least be complete and valid.
            let (_, document) = try await scan(destination)
            #expect(paths(in: document) == ["cancel.bin"])
        case let .failure(thrown):
            #expect((thrown as? ArchiveError)?.isCancellation == true)
            #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
            #expect(partialFiles(in: workspace.url).isEmpty)
        }
    }

    // MARK: - Format capabilities and levels

    @Test("ZIP and TAR.GZ are both offered, and levels change the result")
    func compressionLevels() async throws {
        let workspace = TempWorkspace()
        let payload = Data(String(repeating: "compressible text line\n", count: 40_000).utf8)
        let source = workspace.path("text.txt")
        try payload.write(to: source)

        let store = workspace.path("level0.zip")
        let best = workspace.path("level9.zip")
        let resultStore = try await service.compress(
            sources: [source],
            to: store,
            options: CompressionOptions(formatID: "zip", compressionLevel: 0)
        )
        let resultBest = try await service.compress(
            sources: [source],
            to: best,
            options: CompressionOptions(formatID: "zip", compressionLevel: 9)
        )

        #expect(resultBest.archiveBytes < resultStore.archiveBytes)
        #expect(resultBest.sourceBytes == Int64(payload.count))

        let (_, document) = try await scan(best)
        #expect(paths(in: document) == ["text.txt"])
    }

    @Test("creatable formats declare creation capabilities, not reading ones")
    func creationCapabilities() throws {
        let creatable = ArchiveFormatCatalog.creatableFormats
        #expect(creatable.contains { $0.id == "zip" })
        #expect(creatable.contains { $0.id == "tar.gz" })

        for descriptor in creatable {
            let capabilities = descriptor.capabilities
            #expect(capabilities.canCreate)
            #expect(capabilities.canRead)
            #expect(capabilities.supportsCompressionLevel == (descriptor.compressionLevelRange != nil))
        }

        // The reader-only default (no writer probe) must not claim creation.
        #expect(ArchiveCapabilities.unreadable.canCreate == false)
    }
}
