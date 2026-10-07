//
//  LargeArchiveTests.swift
//  ArchiveCoreTests
//
//  The product promise is "open a 100 000 entry archive and browse it
//  immediately". These tests generate genuinely large archives and check that
//  building the index stays linear and that nothing is extracted.
//
//  The default size keeps the suite quick. Set ARCHIVECAT_LARGE_ENTRY_COUNT to
//  a bigger number (for example 100000) to run the full-scale version.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("large archives", .serialized)
struct LargeArchiveTests {

    /// Entry count used by the scale test.
    static var entryCount: Int {
        if let raw = ProcessInfo.processInfo.environment["ARCHIVECAT_LARGE_ENTRY_COUNT"],
           let value = Int(raw), value > 0 {
            return value
        }
        return 20_000
    }

    private func makeTreeArchive(directoryCount: Int, filesPerDirectory: Int, format: FixtureFormat) throws -> (workspace: TempWorkspace, url: URL) {
        let workspace = TempWorkspace(name: "ArchiveCatLarge")
        var entries: [FixtureEntry] = []
        entries.reserveCapacity(directoryCount * (filesPerDirectory + 1))

        for directory in 0..<directoryCount {
            let path = "pkg\(directory % 50)/sub\(directory % 17)/dir\(directory)"
            entries.append(.directory(path + "/"))
            for file in 0..<filesPerDirectory {
                entries.append(.file("\(path)/file\(file).dat", "payload \(directory)/\(file)"))
            }
        }

        let url = try workspace.writeArchive(entries, format: format, named: "large")
        return (workspace, url)
    }

    @Test("scanning a large archive builds the full index")
    func largeScanIndex() async throws {
        // The workspace must stay alive for the duration of the test: its
        // deinit removes the fixture directory.
        let fixture = try makeTreeArchive(directoryCount: 500, filesPerDirectory: 20, format: .tar)
        let url = fixture.url
        // 500 directories + 10 000 files
        let session = ArchiveSession()

        let started = Date()
        let document = try await session.open(url: url)
        let elapsed = Date().timeIntervalSince(started)

        #expect(document.entries.count == 10_500)
        #expect(document.summary.fileCount == 10_000)
        #expect(document.summary.directoryCount == 500)
        #expect(document.tree.containsDirectory(at: "pkg0/sub0/dir0"))
        #expect(document.entries(in: "pkg0/sub0/dir0").count == 20)

        // Reading metadata must not read payloads: this is milliseconds of work
        // per thousand entries, not seconds.
        #expect(elapsed < 20, "scan took \(elapsed)s, which suggests payloads were read")
    }

    @Test("a compressed large archive is indexed just as fast in metadata terms")
    func compressedLargeScan() async throws {
        let fixture = try makeTreeArchive(directoryCount: 200, filesPerDirectory: 10, format: .tarZstd)
        let url = fixture.url
        let session = ArchiveSession()

        let document = try await session.open(url: url)
        #expect(document.entries.count == 2_200)
        #expect(document.format.compressionName != nil)
    }

    @Test("scale test: index size scales with the entry count")
    func scaleTest() async throws {
        let count = Self.entryCount
        let workspace = TempWorkspace(name: "ArchiveCatScale")
        var entries: [FixtureEntry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            entries.append(.file("bucket\(index % 1000)/file\(index).txt", "x"))
        }

        let url = try workspace.writeArchive(entries, format: .tar, named: "scale")

        let session = ArchiveSession()
        let started = Date()
        let document = try await session.open(url: url)
        let elapsed = Date().timeIntervalSince(started)

        #expect(document.entries.count == count)
        #expect(document.tree.directories.count == 1001, "one root plus 1000 buckets")
        #expect(document.summary.totalUncompressedSize == Int64(count))
        #expect(elapsed < 120, "indexing \(count) entries took \(elapsed)s")

        // Extraction of a single entry out of a huge archive must not walk the
        // whole payload set into memory either.
        let entry = try #require(document.entries.first)
        let destination = workspace.makeDirectory("out")
        let report = try await session.extract(entries: [entry], to: destination, options: .default)
        #expect(report.failures.isEmpty)
        #expect(report.extractedCount == 1)
    }

    @Test("search over a large index is fast and correct")
    func largeSearch() async throws {
        let workspace = TempWorkspace(name: "ArchiveCatSearch")
        var entries: [FixtureEntry] = []
        for index in 0..<5_000 {
            let kind = index % 3 == 0 ? "libssl" : "other"
            entries.append(.file("sources/\(kind)/file\(index).md", "x"))
        }
        let url = try workspace.writeArchive(entries, format: .tar, named: "search")

        let document = try await ArchiveSession().open(url: url)
        let index = ArchiveSearchIndex(entries: document.entries)

        let started = Date()
        let results = index.search("libssl", limit: 5_000)
        let elapsed = Date().timeIntervalSince(started)

        #expect(results.count > 1000)
        #expect(results.count < 2000)
        #expect(elapsed < 2, "searching 5 000 entries took \(elapsed)s")
    }
}
