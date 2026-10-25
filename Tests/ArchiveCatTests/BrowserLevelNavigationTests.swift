//
//  BrowserLevelNavigationTests.swift
//  ArchiveCatTests
//
//  Navigation across archive levels, tested through the browser model itself.
//
//  This is the closest automated approximation of "double-click the archive
//  inside the archive": the model really loads a real archive, really opens the
//  nested member through the engine, and really pushes/pops levels. Only the
//  mouse click is missing.
//

import Foundation
import Testing

@testable import ArchiveCat
@testable import ArchiveCore

@Suite("browser archive levels", .serialized)
@MainActor
struct BrowserLevelNavigationTests {

    // MARK: - Fixtures

    private func makeWorkspace() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveCatUITests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// outer.zip
    ///   readme.md
    ///   artifacts/inner.tar.gz
    ///              └── inside.txt
    private func makeNestedFixture(in workspace: URL) async throws -> URL {
        let innerSource = workspace.appendingPathComponent("inside.txt")
        try Data("nested content".utf8).write(to: innerSource)

        let innerArchive = workspace.appendingPathComponent("inner.tar.gz")
        _ = try await CompressionService().compress(
            sources: [innerSource],
            to: innerArchive,
            options: CompressionOptions(formatID: "tar.gz")
        )

        let readme = workspace.appendingPathComponent("readme.md")
        try Data("# outer".utf8).write(to: readme)

        let artifacts = workspace.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let innerCopy = artifacts.appendingPathComponent("inner.tar.gz")
        try FileManager.default.copyItem(at: innerArchive, to: innerCopy)

        let outer = workspace.appendingPathComponent("outer.zip")
        _ = try await CompressionService().compress(
            sources: [readme, artifacts],
            to: outer,
            options: CompressionOptions(formatID: "zip")
        )
        return outer
    }

    private func makeModel(archive: URL, workspace: URL) throws -> BrowserViewModel {
        let cache = workspace.appendingPathComponent("nested-cache", isDirectory: true)
        let store = try NestedArchiveStore(options: NestedArchiveOptions(cacheDirectory: cache))
        return BrowserViewModel(
            session: ArchiveSession(),
            archiveURL: archive,
            nestedStore: store
        )
    }

    private struct TimedOut: Error {}

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TimedOut()
    }

    private func loadRoot(_ model: BrowserViewModel) async throws {
        model.load()
        try await waitUntil {
            if case .ready = model.phase { return true }
            if case .failed = model.phase { return true }
            return false
        }
        guard case .ready = model.phase else {
            throw TimedOut()
        }
    }

    // MARK: - Tests

    @Test("the root level opens and lists entries")
    func rootLevel() async throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = try await makeNestedFixture(in: workspace)
        let model = try makeModel(archive: archive, workspace: workspace)

        try await loadRoot(model)
        #expect(model.levels.count == 1)
        #expect(model.currentLevelIndex == 0)
        #expect(!model.isInsideNestedArchive)
        #expect(model.rows.contains { $0.name == "readme.md" })
        #expect(model.rows.contains { $0.name == "artifacts" })
        #expect(model.canGoBack == false)
        #expect(model.canGoUp == false)
    }

    @Test("opening a nested archive pushes a level without changing the document")
    func openNestedLevel() async throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = try await makeNestedFixture(in: workspace)
        let model = try makeModel(archive: archive, workspace: workspace)

        try await loadRoot(model)

        // Navigate into the folder that holds the nested archive.
        let artifacts = try #require(model.rows.first { $0.name == "artifacts" })
        #expect(model.open(row: artifacts))
        #expect(model.currentPath == "artifacts")

        let nestedRow = try #require(model.rows.first { $0.name == "inner.tar.gz" })
        #expect(model.canOpenAsNestedArchive(nestedRow))
        #expect(model.open(row: nestedRow))

        try await waitUntil { model.currentLevelIndex == 1 }

        #expect(model.levels.count == 2)
        #expect(model.isInsideNestedArchive)
        #expect(model.currentPath == "")
        #expect(model.currentArchiveName == "inner.tar.gz")
        #expect(model.rows.contains { $0.name == "inside.txt" })
        // The window still belongs to the document's archive.
        #expect(model.title == "outer.zip")
        // The parent level remembered where it was.
        #expect(model.levels[0].currentPath == "artifacts")
        // The breadcrumb names both archives; the subtitle names the nested one
        // because the window title already says "outer.zip".
        #expect(model.archiveChain.map(\.displayName) == ["outer.zip", "inner.tar.gz"])
        #expect(model.locationDescription == "inner.tar.gz")
    }

    @Test("Enclosing Folder steps out of a nested archive, restoring the parent")
    func goUpLeavesNestedArchive() async throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = try await makeNestedFixture(in: workspace)
        let model = try makeModel(archive: archive, workspace: workspace)

        try await loadRoot(model)
        let artifacts = try #require(model.rows.first { $0.name == "artifacts" })
        _ = model.open(row: artifacts)
        let nestedRow = try #require(model.rows.first { $0.name == "inner.tar.gz" })
        _ = model.open(row: nestedRow)
        try await waitUntil { model.currentLevelIndex == 1 }

        model.goUp()

        #expect(model.currentLevelIndex == 0)
        #expect(model.currentPath == "artifacts")
        #expect(model.rows.contains { $0.name == "inner.tar.gz" })
    }

    @Test("Back inside a nested archive returns to the parent archive")
    func backLeavesNestedArchive() async throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = try await makeNestedFixture(in: workspace)
        let model = try makeModel(archive: archive, workspace: workspace)

        try await loadRoot(model)
        let artifacts = try #require(model.rows.first { $0.name == "artifacts" })
        _ = model.open(row: artifacts)
        let nestedRow = try #require(model.rows.first { $0.name == "inner.tar.gz" })
        _ = model.open(row: nestedRow)
        try await waitUntil { model.currentLevelIndex == 1 }

        #expect(model.canGoBack)
        model.goBack()

        #expect(model.currentLevelIndex == 0)
        #expect(model.currentPath == "artifacts")
    }

    @Test("breadcrumb navigation pops back to the parent archive")
    func popToLevelViaChain() async throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = try await makeNestedFixture(in: workspace)
        let model = try makeModel(archive: archive, workspace: workspace)

        try await loadRoot(model)
        let artifacts = try #require(model.rows.first { $0.name == "artifacts" })
        _ = model.open(row: artifacts)
        let nestedRow = try #require(model.rows.first { $0.name == "inner.tar.gz" })
        _ = model.open(row: nestedRow)
        try await waitUntil { model.currentLevelIndex == 1 }

        model.popToLevel(0)
        #expect(model.currentLevelIndex == 0)
        #expect(model.archiveChain.count == 1)
        #expect(model.currentPath == "artifacts")
    }

    @Test("a directory named like an archive is not offered as a nested archive")
    func directoryIsNotOffered() async throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = try await makeNestedFixture(in: workspace)
        let model = try makeModel(archive: archive, workspace: workspace)

        try await loadRoot(model)
        let artifacts = try #require(model.rows.first { $0.name == "artifacts" })
        #expect(model.canOpenAsNestedArchive(artifacts) == false)
    }

    @Test("a corrupt nested archive reports an error and leaves the parent level intact")
    func corruptNestedArchive() async throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = try await makeNestedFixture(in: workspace)

        // Add a fake archive to the outer archive.
        let fake = workspace.appendingPathComponent("broken.zip")
        try Data("not an archive".utf8).write(to: fake)
        let outer = workspace.appendingPathComponent("outer2.zip")
        _ = try await CompressionService().compress(
            sources: [fake],
            to: outer,
            options: CompressionOptions(formatID: "zip")
        )

        let model = try makeModel(archive: outer, workspace: workspace)
        try await loadRoot(model)

        let row = try #require(model.rows.first { $0.name == "broken.zip" })
        #expect(model.open(row: row))
        try await waitUntil { model.isOpeningNestedArchive == false && model.nestedArchiveFailure != nil }

        #expect(model.levels.count == 1)
        #expect(model.currentLevelIndex == 0)
        #expect(model.nestedArchiveFailure != nil)
    }
}
