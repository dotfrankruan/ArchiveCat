//
//  ExtractionConflictTests.swift
//  ArchiveCoreTests
//
//  Conflict resolution, end to end through the engine.
//
//  The point of these tests is that the *engine* honours an explicit decision:
//  Replace replaces, Skip skips, Keep Both renames, Cancel stops. Nothing here
//  defaults a collision to "keep both", and nothing overwrites without being
//  told to.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("extraction conflict resolution")
struct ExtractionConflictTests {

    /// An archive with three independent files, so the tests can check that
    /// resolving one conflict does not disturb the others.
    private func makeArchive(in workspace: TempWorkspace) throws -> URL {
        try workspace.writeArchive([
            .file("one.txt", "from the archive: one"),
            .file("two.txt", "from the archive: two"),
            .file("three.txt", "from the archive: three"),
        ], format: .tar)
    }

    private func contents(_ workspace: TempWorkspace, _ relativePath: String) -> String? {
        workspace.contents(at: relativePath).map { String(decoding: $0, as: UTF8.self) }
    }

    private func makeOptions(
        resolving resolution: ExtractionConflictResolution
    ) -> ExtractionOptions {
        ExtractionOptions(
            conflictPolicy: .ask,
            conflictResolver: { _ in resolution }
        )
    }

    // MARK: - The four answers

    @Test("Replace replaces the existing file with the archived one")
    func replaceReplaces() async throws {
        let workspace = TempWorkspace()
        let url = try makeArchive(in: workspace)
        let destination = workspace.makeDirectory("out")
        try Data("pre-existing".utf8).write(to: destination.appendingPathComponent("two.txt"))

        let session = ArchiveSession()
        _ = try await session.open(url: url)
        let report = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: makeOptions(resolving: .replace)
        )

        #expect(report.failures.isEmpty)
        #expect(contents(workspace, "out/two.txt") == "from the archive: two")
        #expect(contents(workspace, "out/one.txt") == "from the archive: one")
        #expect(contents(workspace, "out/three.txt") == "from the archive: three")
        #expect(!workspace.exists("out/two 2.txt"), "Replace must not also keep a copy")
    }

    @Test("Skip leaves the existing file alone and extracts the rest")
    func skipLeavesItAlone() async throws {
        let workspace = TempWorkspace()
        let url = try makeArchive(in: workspace)
        let destination = workspace.makeDirectory("out")
        try Data("pre-existing".utf8).write(to: destination.appendingPathComponent("two.txt"))

        let session = ArchiveSession()
        _ = try await session.open(url: url)
        let report = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: makeOptions(resolving: .skip)
        )

        #expect(contents(workspace, "out/two.txt") == "pre-existing")
        #expect(contents(workspace, "out/one.txt") == "from the archive: one")
        #expect(contents(workspace, "out/three.txt") == "from the archive: three")
        #expect(report.skipped.contains { $0.reason == .alreadyExists && $0.entry.name == "two.txt" })
        #expect(report.extractedCount == 2)
    }

    @Test("Keep Both writes alongside using Finder naming")
    func keepBothRenames() async throws {
        let workspace = TempWorkspace()
        let url = try makeArchive(in: workspace)
        let destination = workspace.makeDirectory("out")
        try Data("pre-existing".utf8).write(to: destination.appendingPathComponent("two.txt"))

        let session = ArchiveSession()
        _ = try await session.open(url: url)
        let report = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: makeOptions(resolving: .keepBoth)
        )

        #expect(contents(workspace, "out/two.txt") == "pre-existing")
        #expect(contents(workspace, "out/two 2.txt") == "from the archive: two")
        #expect(report.failures.isEmpty)
        #expect(report.extractedCount == 3)
    }

    @Test("Cancel stops extraction, keeps what was written, and leaves the engine usable")
    func cancelStops() async throws {
        let workspace = TempWorkspace()
        let url = try makeArchive(in: workspace)
        let destination = workspace.makeDirectory("out")
        try Data("pre-existing".utf8).write(to: destination.appendingPathComponent("two.txt"))

        let session = ArchiveSession()
        _ = try await session.open(url: url)
        let report = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: makeOptions(resolving: .cancel)
        )

        #expect(report.wasCancelled)
        // The entry before the conflict was written; the ones after it were not.
        #expect(contents(workspace, "out/one.txt") == "from the archive: one")
        #expect(contents(workspace, "out/two.txt") == "pre-existing")
        #expect(!workspace.exists("out/three.txt"))
        #expect(!workspace.exists("out/two 2.txt"))
        #expect(report.failures.isEmpty, "cancelling is not a failure")

        // The engine must still work afterwards: same destination, no resolver.
        let second = try workspace.makeDirectory("out2")
        let rerun = try await session.extract(
            entries: try await allEntries(session),
            to: second,
            options: ExtractionOptions(conflictPolicy: .replace)
        )
        #expect(rerun.failures.isEmpty)
        #expect(rerun.extractedCount == 3)
        #expect(contents(workspace, "out2/two.txt") == "from the archive: two")
    }

    // MARK: - When the resolver is consulted

    @Test("the resolver is asked once per collision, with the collision described")
    func resolverSeesEachConflict() async throws {
        let workspace = TempWorkspace()
        let url = try makeArchive(in: workspace)
        let destination = workspace.makeDirectory("out")
        try Data("x".utf8).write(to: destination.appendingPathComponent("one.txt"))
        try Data("x".utf8).write(to: destination.appendingPathComponent("three.txt"))

        let seen = ConflictRecorder()
        let session = ArchiveSession()
        _ = try await session.open(url: url)
        let report = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: ExtractionOptions(
                conflictPolicy: .ask,
                conflictResolver: { conflict in
                    seen.record(conflict)
                    return .skip
                }
            )
        )

        let observed = seen.conflicts
        #expect(observed.count == 2)
        #expect(Set(observed.map(\.relativePath)) == ["one.txt", "three.txt"])
        #expect(observed.allSatisfy { $0.destination.standardizedFileURL == destination.standardizedFileURL })
        #expect(observed.allSatisfy { !$0.existingIsDirectory })
        #expect(report.extractedCount == 1, "only the file without a conflict was written")
    }

    @Test("a file with no conflict never reaches the resolver")
    func noResolverCallWithoutConflict() async throws {
        let workspace = TempWorkspace()
        let url = try makeArchive(in: workspace)
        let destination = workspace.makeDirectory("out")

        let seen = ConflictRecorder()
        let session = ArchiveSession()
        _ = try await session.open(url: url)
        let report = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: ExtractionOptions(conflictPolicy: .ask, conflictResolver: { conflict in
                seen.record(conflict)
                return .cancel
            })
        )

        #expect(seen.conflicts.isEmpty)
        #expect(!report.wasCancelled)
        #expect(report.extractedCount == 3)
    }

    @Test("an existing folder is not offered as replaceable")
    func folderIsNotAReplaceQuestion() async throws {
        let workspace = TempWorkspace()
        let url = try makeArchive(in: workspace)
        let destination = workspace.makeDirectory("out")
        // A folder where the archive wants to write a file.
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("two.txt"),
            withIntermediateDirectories: true
        )

        let seen = ConflictRecorder()
        let session = ArchiveSession()
        _ = try await session.open(url: url)
        let report = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: ExtractionOptions(conflictPolicy: .replace, conflictResolver: { conflict in
                seen.record(conflict)
                return .replace
            })
        )

        #expect(seen.conflicts.isEmpty, "the user is not asked to replace a folder")
        // ArchiveCat never deletes a folder, so this is reported as a failure
        // rather than silently doing something surprising.
        #expect(report.failures.contains { $0.entry.name == "two.txt" })
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("two.txt").path(percentEncoded: false),
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue, "the folder must still be there")
    }

    @Test("creating a folder that already exists is not a conflict")
    func existingFolderEntryIsNotAConflict() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .directory("nested/"),
            .file("nested/file.txt", "contents"),
        ], format: .tar)
        let destination = workspace.makeDirectory("out")
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )

        let seen = ConflictRecorder()
        let session = ArchiveSession()
        _ = try await session.open(url: url)
        let report = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: ExtractionOptions(conflictPolicy: .ask, conflictResolver: { conflict in
                seen.record(conflict)
                return .cancel
            })
        )

        #expect(seen.conflicts.isEmpty)
        #expect(!report.wasCancelled)
        #expect(contents(workspace, "out/nested/file.txt") == "contents")
    }

    // MARK: - Defaults

    @Test("the engine never overwrites when nobody was asked")
    func defaultNeverOverwrites() async throws {
        let workspace = TempWorkspace()
        let url = try makeArchive(in: workspace)
        let destination = workspace.makeDirectory("out")
        try Data("pre-existing".utf8).write(to: destination.appendingPathComponent("two.txt"))

        let session = ArchiveSession()
        _ = try await session.open(url: url)
        // `.default` has no resolver, so `.ask` has nothing to ask.
        let report = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: .default
        )

        #expect(contents(workspace, "out/two.txt") == "pre-existing", "the existing file must survive")
        #expect(contents(workspace, "out/two 2.txt") == "from the archive: two")
        #expect(report.failures.isEmpty)
    }

    @Test("the resolver is honoured for symlink collisions too")
    func resolverAppliesToLinks() async throws {
        let workspace = TempWorkspace()
        let url = try workspace.writeArchive([
            .file("target.txt", "target contents"),
            .symlink("link.txt", to: "target.txt"),
        ], format: .tar)
        let destination = workspace.makeDirectory("out")

        // A destination where the symlink's name is already taken by a file.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("pre-existing".utf8).write(to: destination.appendingPathComponent("target.txt"))
        try Data("occupier".utf8).write(to: destination.appendingPathComponent("link.txt"))

        let session = ArchiveSession()
        _ = try await session.open(url: url)

        // Skip: the occupier stays a regular file.
        _ = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: makeOptions(resolving: .skip)
        )
        #expect(contents(workspace, "out/link.txt") == "occupier")

        // Keep Both: the link is created alongside it.
        _ = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: makeOptions(resolving: .keepBoth)
        )
        let linkPath = destination.appendingPathComponent("link 2.txt").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: linkPath))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == "target.txt")

        // Replace: the occupier is replaced by the link.
        _ = try await session.extract(
            entries: try await allEntries(session),
            to: destination,
            options: makeOptions(resolving: .replace)
        )
        // Replace applied to both entries: the target file was rewritten and
        // the occupier became a symlink, so reading through the link now yields
        // the archive's contents.
        #expect(contents(workspace, "out/target.txt") == "target contents")
        #expect(contents(workspace, "out/link.txt") == "target contents")
        #expect((try? FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent("link.txt").path(percentEncoded: false)
        )) == "target.txt")
    }

    // MARK: - Helpers

    private func allEntries(_ session: ArchiveSession) async throws -> [ArchiveEntry] {
        guard let document = await session.document else { return [] }
        return document.entries.filter { $0.safety.isSafe }
    }
}

/// Collects the conflicts a resolver was asked about, across isolation domains.
private final class ConflictRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExtractionConflict] = []

    func record(_ conflict: ExtractionConflict) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(conflict)
    }

    var conflicts: [ExtractionConflict] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
