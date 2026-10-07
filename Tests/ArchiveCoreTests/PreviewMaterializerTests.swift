//
//  PreviewMaterializerTests.swift
//  ArchiveCoreTests
//
//  The preview cache is what makes Space instantaneous and keeps ArchiveCat
//  from ever unpacking a whole archive. Its contract is small and worth
//  pinning down: extract one entry, key it so it cannot collide, reuse it while
//  it is still valid, and never touch the user's own files.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("preview materialisation")
struct PreviewMaterializerTests {

    private func makeSession(cacheRoot: URL) -> ArchiveSession {
        ArchiveSession(previewConfiguration: PreviewMaterializer.Configuration(
            cacheDirectory: cacheRoot,
            maximumCacheBytes: 32 * 1024 * 1024,
            maximumAge: 60 * 60,
            reuseExisting: true
        ))
    }

    @Test("only the requested entry is extracted")
    func singleEntryOnly() async throws {
        let workspace = TempWorkspace()
        let cacheRoot = workspace.makeDirectory("cache")
        let url = try workspace.writeArchive([
            .file("a.txt", "first"),
            .file("b.txt", "second"),
            .file("nested/c.txt", "third"),
        ], format: .tar)

        let session = makeSession(cacheRoot: cacheRoot)
        let document = try await session.open(url: url)
        let entry = try #require(document.entries.first { $0.name == "b.txt" })

        let materialised = try await session.materializeForPreview(entry: entry)
        #expect(materialised.lastPathComponent == "b.txt")
        #expect(String(decoding: try Data(contentsOf: materialised), as: UTF8.self) == "second")

        // Nothing else from the archive is present anywhere in the cache. The
        // cache directory itself ends with the entry name, so match on the full
        // relative path of a payload rather than on the file name alone.
        let cached = try FileManager.default.subpathsOfDirectory(atPath: cacheRoot.path(percentEncoded: false))
        #expect(!cached.contains { $0.hasSuffix("/a.txt") })
        #expect(!cached.contains { $0.hasSuffix("/nested/c.txt") })
        #expect(cached.contains { $0.hasSuffix("/b.txt") })
    }

    @Test("cached entries are reused rather than re-extracted")
    func cacheReuse() async throws {
        let workspace = TempWorkspace()
        let cacheRoot = workspace.makeDirectory("cache")
        let url = try workspace.writeArchive([.file("a.txt", "contents")], format: .tarGzip)

        let session = makeSession(cacheRoot: cacheRoot)
        let document = try await session.open(url: url)
        let entry = try #require(document.entries.first)

        let first = try await session.materializeForPreview(entry: entry)
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: first.path(percentEncoded: false))
        let firstInode = (firstAttributes[.systemFileNumber] as? NSNumber)?.intValue

        let second = try await session.materializeForPreview(entry: entry)
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: second.path(percentEncoded: false))
        let secondInode = (secondAttributes[.systemFileNumber] as? NSNumber)?.intValue

        #expect(first == second)
        #expect(firstInode == secondInode, "a cache hit must not rewrite the file")
    }

    @Test("two archives with the same name cannot collide")
    func noCollisionAcrossArchives() async throws {
        let workspace = TempWorkspace()
        let cacheRoot = workspace.makeDirectory("cache")

        let firstArchive = try workspace.writeArchive([.file("report.txt", "from A")], format: .tar, named: "one")
        let secondArchive = try workspace.writeArchive([.file("report.txt", "from B")], format: .tar, named: "two")

        // One session per archive, exactly as the app does it: a session is
        // bound to a single document.
        let firstSession = makeSession(cacheRoot: cacheRoot)
        let secondSession = makeSession(cacheRoot: cacheRoot)

        let firstDocument = try await firstSession.open(url: firstArchive)
        let secondDocument = try await secondSession.open(url: secondArchive)

        let firstURL = try await firstSession.materializeForPreview(entry: try #require(firstDocument.entries.first))
        let secondURL = try await secondSession.materializeForPreview(entry: try #require(secondDocument.entries.first))

        #expect(firstURL != secondURL)
        #expect(String(decoding: try Data(contentsOf: firstURL), as: UTF8.self) == "from A")
        #expect(String(decoding: try Data(contentsOf: secondURL), as: UTF8.self) == "from B")
    }

    @Test("duplicate paths inside one archive get distinct cache entries")
    func duplicatePathsDistinct() async throws {
        let workspace = TempWorkspace()
        let cacheRoot = workspace.makeDirectory("cache")
        let url = try workspace.writeArchive([
            .file("dup.txt", "first"),
            .file("dup.txt", "second"),
        ], format: .tar)

        let session = makeSession(cacheRoot: cacheRoot)
        let document = try await session.open(url: url)
        let entries = document.entries
        #expect(entries.count == 2)

        let first = try await session.materializeForPreview(entry: entries[0])
        let second = try await session.materializeForPreview(entry: entries[1])

        #expect(first != second)
        #expect(String(decoding: try Data(contentsOf: first), as: UTF8.self) == "first")
        #expect(String(decoding: try Data(contentsOf: second), as: UTF8.self) == "second")
    }

    @Test("a folder preview is a folder, and extracts nothing")
    func folderPreview() async throws {
        let workspace = TempWorkspace()
        let cacheRoot = workspace.makeDirectory("cache")
        let url = try workspace.writeArchive([
            .directory("folder/"),
            .file("folder/inside.txt", "inside"),
        ], format: .tar)

        let session = makeSession(cacheRoot: cacheRoot)
        let document = try await session.open(url: url)
        // The archive stored an explicit directory entry; it lives on the
        // directory node, not in the parent's entry list.
        let folder = try #require(document.directoryEntry(at: "folder"))

        let materialised = try await session.materializeForPreview(entry: folder)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: materialised.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let contents = try FileManager.default.contentsOfDirectory(atPath: materialised.path(percentEncoded: false))
        #expect(contents.isEmpty, "previewing a folder must not extract its contents")
    }

    @Test("drag payloads materialise the whole subtree")
    func dragPayload() async throws {
        let workspace = TempWorkspace()
        let cacheRoot = workspace.makeDirectory("cache")
        let url = try workspace.writeArchive([
            .file("folder/a.txt", "a"),
            .file("folder/sub/b.txt", "b"),
            .file("outside.txt", "outside"),
        ], format: .tar)

        let session = makeSession(cacheRoot: cacheRoot)
        let document = try await session.open(url: url)
        let subtree = document.entries.filter { $0.path.hasPrefix("folder/") }

        let root = try await session.materializeForDrag(entries: subtree)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder/a.txt").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder/sub/b.txt").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path(percentEncoded: false)))
    }

    @Test("the cache can be emptied")
    func cacheClearing() async throws {
        let workspace = TempWorkspace()
        let cacheRoot = workspace.makeDirectory("cache")
        let url = try workspace.writeArchive([.file("a.txt", "a")], format: .tar)

        let session = makeSession(cacheRoot: cacheRoot)
        let document = try await session.open(url: url)
        _ = try await session.materializeForPreview(entry: try #require(document.entries.first))

        #expect(await session.previewCacheSize() > 0)
        await session.purgePreviewCache()
        #expect(await session.previewCacheSize() == 0)
    }

    @Test("a cached file that no longer matches its entry is re-extracted")
    func staleCacheInvalidated() async throws {
        let workspace = TempWorkspace()
        let cacheRoot = workspace.makeDirectory("cache")
        let url = try workspace.writeArchive([.file("a.txt", "correct contents")], format: .tar)

        let session = makeSession(cacheRoot: cacheRoot)
        let document = try await session.open(url: url)
        let entry = try #require(document.entries.first)

        let materialised = try await session.materializeForPreview(entry: entry)

        // Simulate a truncated cache entry: the size check must reject it.
        try Data("short".utf8).write(to: materialised)
        let reExtracted = try await session.materializeForPreview(entry: entry)

        #expect(String(decoding: try Data(contentsOf: reExtracted), as: UTF8.self) == "correct contents")
    }
}
