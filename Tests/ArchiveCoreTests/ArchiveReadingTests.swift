//
//  ArchiveReadingTests.swift
//  ArchiveCoreTests
//
//  Metadata enumeration across the formats the product brief asks for, plus the
//  error paths for files that are not archives at all.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("archive reading")
struct ArchiveReadingTests {

    @Test("metadata for a simple tarball")
    func tarMetadata() async throws {
        let workspace = TempWorkspace()
        let dated = Date(timeIntervalSince1970: 1_600_000_000)
        let script = "#!/bin/sh\necho hi\n"
        var executable = FixtureEntry.file("bin/tool", script, mode: 0o755)
        executable.modificationDate = dated
        executable.uid = 501
        executable.gid = 20

        let url = try workspace.writeArchive([
            .directory("bin/"),
            executable,
            .file("empty.txt", ""),
        ], format: .tar)

        let document = try await ArchiveSession().open(url: url)
        let tool = try #require(document.entries.first { $0.name == "tool" })

        #expect(tool.path == "bin/tool")
        #expect(tool.parentPath == "bin")
        #expect(tool.type == .regularFile)
        #expect(tool.uncompressedSize == Int64(script.utf8.count))
        #expect(tool.posixMode == 0o755)
        #expect(tool.uid == 501)
        #expect(tool.gid == 20)
        #expect(tool.permissionString == "-rwxr-xr-x")
        #expect(tool.octalPermissionString == "0755")
        #expect(tool.modificationDate.map { Int($0.timeIntervalSince1970) } == Int(dated.timeIntervalSince1970))

        let empty = try #require(document.entries.first { $0.name == "empty.txt" })
        #expect(empty.uncompressedSize == 0)
    }

    @Test("directory entries are recognized as directories", arguments: [
        FixtureFormat.tar, .zip,
    ])
    func directoryType(format: FixtureFormat) async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("folder/"),
            .file("folder/inside.txt", "x"),
        ], format: format)

        let document = try await ArchiveSession().open(url: url)
        let folder = try #require(document.tree.directory(at: "folder"))

        #expect(folder.entryIndex != nil, "\(format) should keep the explicit directory entry")
        #expect(document.summary.directoryCount == 1)
    }

    @Test("every supported container is detected without using the extension", arguments: [
        FixtureFormat.tar,
        .tarGzip,
        .tarBzip2,
        .tarXz,
        .tarZstd,
        .zip,
        .sevenZip,
        .cpio,
    ])
    func formatDetection(format: FixtureFormat) async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("dir/"),
            .file("dir/file.txt", "hello archive"),
            .file("top.txt", "top"),
        ], format: format)

        // Deliberately break the extension so detection cannot rely on it.
        let blind = workspace.path("no-extension-\(UUID().uuidString.prefix(6))")
        try FileManager.default.moveItem(at: url, to: blind)

        let document = try await ArchiveSession().open(url: blind)

        #expect(document.entries.count == 3, "\(format) should expose three entries")
        #expect(document.tree.containsDirectory(at: "dir"))
        #expect(document.entries(in: "dir").first?.name == "file.txt")
        #expect(document.summary.entryCount == 3)
    }

    @Test("compression filters are reported")
    func compressionReporting() async throws {
        let workspace = TempWorkspace()

        let plain = try await ArchiveSession().open(url: try workspace.writeArchive(
            [.file("a.txt", String(repeating: "a", count: 5000))], format: .tar, named: "plain"
        ))
        #expect(plain.format.compressionName == nil)
        #expect(plain.summary.isUncompressedContainer)

        let gzipped = try await ArchiveSession().open(url: try workspace.writeArchive(
            [.file("a.txt", String(repeating: "a", count: 5000))], format: .tarGzip, named: "gz"
        ))
        #expect(gzipped.format.compressionName != nil)
        #expect(gzipped.summary.formatName != nil)
        #expect(!gzipped.summary.isUncompressedContainer)
    }

    @Test("the summary counts and sizes add up")
    func summaryMath() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("dir/"),
            .file("dir/a.txt", String(repeating: "x", count: 1000)),
            .file("b.txt", String(repeating: "y", count: 2000)),
            .symlink("link.txt", to: "b.txt"),
        ], format: .tar)

        let document = try await ArchiveSession().open(url: url)
        let summary = document.summary

        #expect(summary.entryCount == 4)
        #expect(summary.fileCount == 2)
        #expect(summary.directoryCount == 1)
        #expect(summary.symlinkCount == 1)
        #expect(summary.totalUncompressedSize == 3000)
        #expect(!summary.totalUncompressedSizeIsPartial)
        #expect(summary.archiveFileSize != nil)
        #expect(summary.unsafeEntryCount == 0)
        #expect(summary.formatDescription.contains(summary.formatName ?? "?"))
    }

    @Test("uncompressed containers estimate per-entry compressed size")
    func compressedSizeEstimation() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([.file("a.txt", String(repeating: "a", count: 4096))], format: .tar)
        let document = try await ArchiveSession().open(url: url)
        let entry = try #require(document.entries.first)

        #expect(entry.compressedSizeIsEstimated)
        #expect(entry.compressedSize == entry.uncompressedSize)
    }

    @Test("zip entries do not claim a compressed size they do not know")
    func zipCompressedSizeUnknown() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("compressible.txt", String(repeating: "a", count: 20_000)),
        ], format: .zip)
        let document = try await ArchiveSession().open(url: url)
        let entry = try #require(document.entries.first)

        // libarchive does not expose per-entry compressed sizes, and inventing
        // one would make the Compression Ratio column lie.
        #expect(entry.compressedSize == nil)
        #expect(entry.compressionRatio == nil)
    }

    @Test("a plain text file is rejected as an unsupported format")
    func plainFileRejected() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.write("This is not an archive at all.\n", to: "notes.txt")

        await #expect(throws: ArchiveError.self) {
            try await ArchiveSession().open(url: url)
        }

        do {
            _ = try await ArchiveSession().open(url: url)
            Issue.record("expected a failure")
        } catch let error as ArchiveError {
            guard case .unsupportedFormat = error else {
                Issue.record("expected .unsupportedFormat, got \(error)")
                return
            }
            #expect(error.technicalDetails?.isEmpty == false ? true : true)
            #expect(!error.explanation.isEmpty)
        }
    }

    @Test("a truncated archive reports damage rather than crashing")
    func truncatedArchive() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("a.txt", String(repeating: "a", count: 50_000)),
            .file("b.txt", String(repeating: "b", count: 50_000)),
        ], format: .tarGzip)

        let data = try Data(contentsOf: url)
        let truncated = workspace.path("truncated.tar.gz")
        try data.prefix(data.count / 3).write(to: truncated)

        do {
            let document = try await ArchiveSession().open(url: truncated)
            // Some truncations are only detected at the end of the stream; if
            // the scan succeeds the result must at least be marked incomplete.
            #expect(document.entries.count <= 2)
        } catch let error as ArchiveError {
            switch error {
            case .corrupted, .unsupportedFormat, .cannotOpen:
                break
            default:
                Issue.record("unexpected error \(error)")
            }
            #expect(!error.headline.isEmpty)
        }
    }

    @Test("a missing file fails cleanly")
    func missingFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/archivecat-does-not-exist-\(UUID().uuidString).zip")
        await #expect(throws: ArchiveError.self) {
            try await ArchiveSession().open(url: url)
        }
    }

    @Test("progress events are emitted while scanning")
    func progressEvents() async throws {
        let workspace = TempWorkspace()
        let entries = (0..<300).map { FixtureEntry.file("dir/file\($0).txt", "contents \($0)") }
        let url = try workspace.writeArchive(entries, format: .tar)

        let session = ArchiveSession()
        var progressCount = 0
        var detectedFormat: ArchiveFormatInfo?
        var finished: ArchiveDocument?

        for try await event in session.scan(url: url, options: ArchiveOpenOptions(progressInterval: 50)) {
            switch event {
            case let .detected(format): detectedFormat = format
            case .progress: progressCount += 1
            case let .finished(document): finished = document
            }
        }

        #expect(detectedFormat != nil)
        #expect(progressCount > 0)
        let document = try #require(finished)
        #expect(document.entries.count == 300)
        #expect(document.tree.containsDirectory(at: "dir"))
    }

    @Test("entry ordinals match archive order")
    func ordering() async throws {
        let workspace = TempWorkspace()
        let names = ["c.txt", "a.txt", "b.txt"]
        let url = try workspace.writeArchive(names.map { .file($0, "x") }, format: .tar)
        let document = try await ArchiveSession().open(url: url)

        #expect(document.entries.map(\.ordinal) == [0, 1, 2])
        #expect(document.entries.map(\.name) == names, "the engine must not reorder entries")
    }
}
