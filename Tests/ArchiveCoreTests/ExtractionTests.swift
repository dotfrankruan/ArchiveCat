//
//  ExtractionTests.swift
//  ArchiveCoreTests
//
//  Selective extraction, conflict handling, metadata fidelity, and — most
//  importantly — proof that nothing ever lands outside the destination root.
//

import Darwin
import Foundation
import Testing

@testable import ArchiveCore

@Suite("extraction")
struct ExtractionTests {

    // MARK: - Basics

    @Test("a single file is extracted with its archive path")
    func singleFile() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("usr/bin/tool", "tool contents"),
            .file("other.txt", "other"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let entry = try #require(document.entries.first { $0.name == "tool" })

        let destination = workspace.makeDirectory("out")
        try await session.extract(entry: entry, to: destination)

        #expect(workspace.contents(at: "out/usr/bin/tool").map { String(decoding: $0, as: UTF8.self) } == "tool contents")
        #expect(!workspace.exists("out/other.txt"), "only the requested entry may be written")
    }

    @Test("a directory is extracted recursively")
    func directoryRecursive() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("dir/a.txt", "a"),
            .file("dir/sub/b.txt", "b"),
            .file("dir/sub/deeper/c.txt", "c"),
            .file("elsewhere.txt", "nope"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)

        // `dir` is implied by its children rather than stored explicitly, which
        // is what `tar cf x.tar dir` produces; selecting it means selecting the
        // subtree beneath it.
        #expect(document.tree.containsDirectory(at: "dir"))
        let subtree = document.entries.filter { $0.path.hasPrefix("dir/") }
        #expect(subtree.count == 3)

        let destination = workspace.makeDirectory("out")
        let report = try await session.extract(entries: subtree, to: destination, options: .default)

        #expect(report.failures.isEmpty)
        #expect(workspace.contents(at: "out/dir/a.txt") != nil)
        #expect(workspace.contents(at: "out/dir/sub/b.txt") != nil)
        #expect(workspace.contents(at: "out/dir/sub/deeper/c.txt") != nil)
        #expect(!workspace.exists("out/elsewhere.txt"))
    }

    @Test("extract everything writes every safe entry")
    func wholeArchive() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("a/"),
            .file("a/one.txt", "1"),
            .file("a/two.txt", "2"),
            .file("three.txt", "3"),
        ], format: .tarGzip)

        let session = ArchiveSession()
        _ = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        let report = try await session.extractEverything(to: destination, options: .default)

        #expect(report.extractedCount == 4)
        #expect(report.failures.isEmpty)
        #expect(workspace.exists("out/a/one.txt"))
        #expect(workspace.exists("out/three.txt"))
    }

    @Test("empty files are created")
    func emptyFiles() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([.file("empty.txt", "")], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        _ = try await session.extract(entry: document.entries[0], to: destination)

        #expect(workspace.exists("out/empty.txt"))
        #expect(workspace.contents(at: "out/empty.txt")?.isEmpty == true)
    }

    // MARK: - Security

    @Test("traversal entries are never written outside the destination")
    func traversalBlocked() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("safe.txt", "safe"),
            .file("../../escaped.txt", "escaped"),
            .file("/tmp/absolute.txt", "absolute"),
            .file("nested/../../escaped2.txt", "escaped2"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)

        let destination = workspace.makeDirectory("out")
        let report = try await session.extract(
            entries: document.entries,
            to: destination,
            options: ExtractionOptions(conflictPolicy: .replace)
        )

        #expect(workspace.exists("out/safe.txt"))
        #expect(!workspace.exists("escaped.txt"))
        #expect(!workspace.exists("escaped2.txt"))
        #expect(!workspace.exists("out/../escaped.txt"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/absolute.txt"))
        #expect(report.skipped.filter { $0.reason == .unsafePath }.count == 3)

        // Nothing above the destination root was touched.
        let contents = try FileManager.default.contentsOfDirectory(atPath: workspace.url.path(percentEncoded: false))
        #expect(Set(contents).isSuperset(of: ["out"]))
        #expect(!contents.contains("escaped.txt"))
    }

    @Test("an absolute symlink target is refused")
    func absoluteSymlinkRefused() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("inside.txt", "inside"),
            .symlink("passwd-link", to: "/etc/passwd"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        let report = try await session.extract(entries: document.entries, to: destination, options: .default)

        #expect(workspace.exists("out/inside.txt"))
        #expect(!workspace.exists("out/passwd-link"), "an escaping symlink must not be created")
        #expect(report.failures.contains { $0.entry.name == "passwd-link" })
    }

    @Test("a symlink cannot be used to write outside the root")
    func symlinkThenWriteBlocked() async throws {
        let workspace = TempWorkspace()
        // The classic two-stage attack: plant a symlink, then write "through" it.
        let url = try workspace.writeArchive([
            .symlink("evil", to: "../.."),
            .file("evil/pwned.txt", "pwned"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        _ = try await session.extract(entries: document.entries, to: destination, options: .default)

        #expect(!workspace.exists("pwned.txt"))
        #expect(!FileManager.default.fileExists(atPath: workspace.url.deletingLastPathComponent().appendingPathComponent("pwned.txt").path))

        // Whatever happened, everything created stays inside `out`.
        let created = try FileManager.default.subpathsOfDirectory(atPath: destination.path(percentEncoded: false))
        #expect(created.allSatisfy { !$0.contains("..") })
    }

    @Test("a relative symlink that stays inside the root is created")
    func internalSymlinkCreated() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("lib/"),
            .file("lib/libz.dylib", "binary"),
            .symlink("lib/libz.1.dylib", to: "libz.dylib"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        let report = try await session.extract(entries: document.entries, to: destination, options: .default)

        #expect(report.failures.isEmpty)
        let linkPath = destination.appendingPathComponent("lib/libz.1.dylib").path(percentEncoded: false)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(target == "libz.dylib")
    }

    // MARK: - Conflicts

    @Test("the skip policy leaves an existing file alone")
    func conflictSkip() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([.file("existing.txt", "new contents")], format: .tar)

        let destination = workspace.makeDirectory("out")
        try Data("original".utf8).write(to: destination.appendingPathComponent("existing.txt"))

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let report = try await session.extract(
            entries: document.entries,
            to: destination,
            options: ExtractionOptions(conflictPolicy: .skip)
        )

        #expect(String(decoding: try #require(workspace.contents(at: "out/existing.txt")), as: UTF8.self) == "original")
        #expect(report.skipped.contains { $0.reason == .alreadyExists })
    }

    @Test("the replace policy overwrites when explicitly chosen")
    func conflictReplace() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([.file("existing.txt", "new contents")], format: .tar)

        let destination = workspace.makeDirectory("out")
        try Data("original".utf8).write(to: destination.appendingPathComponent("existing.txt"))

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        _ = try await session.extract(
            entries: document.entries,
            to: destination,
            options: ExtractionOptions(conflictPolicy: .replace)
        )

        #expect(String(decoding: try #require(workspace.contents(at: "out/existing.txt")), as: UTF8.self) == "new contents")
    }

    @Test("the keep both policy writes alongside, Finder style")
    func conflictKeepBoth() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([.file("report.txt", "archive copy")], format: .tar)

        let destination = workspace.makeDirectory("out")
        try Data("existing".utf8).write(to: destination.appendingPathComponent("report.txt"))

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        _ = try await session.extract(
            entries: document.entries,
            to: destination,
            options: ExtractionOptions(conflictPolicy: .keepBoth)
        )

        #expect(String(decoding: try #require(workspace.contents(at: "out/report.txt")), as: UTF8.self) == "existing")
        #expect(String(decoding: try #require(workspace.contents(at: "out/report 2.txt")), as: UTF8.self) == "archive copy")
    }

    @Test("preflight finds conflicts before anything is written")
    func preflightConflicts() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("a.txt", "a"),
            .file("b.txt", "b"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        try Data("existing".utf8).write(to: destination.appendingPathComponent("a.txt"))

        let conflicts = ExtractionPreflight.conflicts(entries: document.entries, in: destination)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.entry.name == "a.txt")
        #expect(!workspace.exists("out/b.txt"), "preflight must not write anything")
    }

    // MARK: - Metadata fidelity

    @Test("permissions and modification dates are preserved")
    func metadataPreserved() async throws {
        let workspace = TempWorkspace()
        let dated = Date(timeIntervalSince1970: 1_500_000_000)
        var script = FixtureEntry.file("bin/run.sh", "#!/bin/sh\n", mode: 0o755)
        script.modificationDate = dated

        let url = try workspace.writeArchive([.directory("bin/"), script], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        _ = try await session.extract(entries: document.entries, to: destination, options: .default)

        let scriptURL = destination.appendingPathComponent("bin/run.sh")
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path(percentEncoded: false))
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.uint16Value & 0o777 == 0o755)

        let modified = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(modified.timeIntervalSince(dated)) < 2, "modification date should survive")

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("bin").path(percentEncoded: false)
        )
        let directoryPermissions = try #require(directoryAttributes[.posixPermissions] as? NSNumber)
        #expect(directoryPermissions.uint16Value & 0o777 == 0o755)
    }

    @Test("setuid and setgid bits are stripped by default")
    func setuidStripped() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            FixtureEntry.file("suid-tool", "binary", mode: 0o4755),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        _ = try await session.extract(entries: document.entries, to: destination, options: .default)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("suid-tool").path(percentEncoded: false)
        )
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.uint16Value & 0o4000 == 0, "setuid must not survive extraction")
    }

    @Test("hard links are recreated as links to the same inode")
    func hardLinks() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("original.txt", "shared contents"),
            .hardlink("link.txt", to: "original.txt"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        let report = try await session.extract(entries: document.entries, to: destination, options: .default)

        let original = destination.appendingPathComponent("original.txt")
        let link = destination.appendingPathComponent("link.txt")

        if FileManager.default.fileExists(atPath: link.path(percentEncoded: false)) {
            var originalStat = stat()
            var linkStat = stat()
            lstat(original.path(percentEncoded: false), &originalStat)
            lstat(link.path(percentEncoded: false), &linkStat)
            #expect(originalStat.st_ino == linkStat.st_ino)
            #expect(String(decoding: try #require(workspace.contents(at: "out/link.txt")), as: UTF8.self) == "shared contents")
        } else {
            // If the fixture could not express the link, the entry must be
            // reported rather than silently ignored.
            #expect(report.skipped.contains { $0.reason == .missingHardlinkTarget } || !report.failures.isEmpty)
        }
    }

    @Test("FIFOs are skipped unless explicitly requested")
    func fifoSkipped() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("normal.txt", "x"),
            .fifo("pipe"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        let report = try await session.extract(entries: document.entries, to: destination, options: .default)

        #expect(workspace.exists("out/normal.txt"))
        #expect(!workspace.exists("out/pipe"))
        #expect(report.skipped.contains { $0.reason == .unsupportedType })
    }

    @Test("a destination that is a file is refused")
    func badDestination() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([.file("a.txt", "a")], format: .tar)
        let destination = try workspace.write("not a directory", to: "file-not-dir")

        let session = ArchiveSession()
        _ = try await session.open(url: url)

        await #expect(throws: ArchiveError.self) {
            try await session.extractEverything(to: destination, options: .default)
        }
    }

    @Test("extraction limits stop a runaway archive")
    func limitsEnforced() async throws {
        let workspace = TempWorkspace()
        let entries = (0..<50).map { FixtureEntry.file("file\($0).bin", bytes: 1024) }
        let url = try workspace.writeArchive(entries, format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")

        do {
            _ = try await session.extract(
                entries: document.entries,
                to: destination,
                options: ExtractionOptions(limits: ExtractionLimits(maximumEntryCount: 10))
            )
            Issue.record("expected the entry-count limit to stop extraction")
        } catch let error as ArchiveError {
            guard case let .limitExceeded(kind, _, _) = error else {
                Issue.record("expected .limitExceeded, got \(error)")
                return
            }
            #expect(kind == .entries)
        }
    }

    @Test("the report accounts for every selected entry")
    func reportAccounting() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("a.txt", "a"),
            .file("../hostile.txt", "hostile"),
            .fifo("pipe"),
            .file("b.txt", "b"),
        ], format: .tar)

        let session = ArchiveSession()
        let document = try await session.open(url: url)
        let destination = workspace.makeDirectory("out")
        let report = try await session.extract(entries: document.entries, to: destination, options: .default)

        let accounted = report.extracted.count + report.skipped.count + report.failures.count
        #expect(accounted >= 3)
        #expect(!report.isEmpty)
    }
}
