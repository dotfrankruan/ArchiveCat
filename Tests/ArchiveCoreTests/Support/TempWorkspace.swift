//
//  TempWorkspace.swift
//  ArchiveCoreTests
//
//  A scratch directory that cleans itself up.
//
//  Tests run in parallel, so every fixture gets its own directory under the
//  process' temporary folder. Nothing is written outside it, and nothing is
//  left behind when a test finishes or throws.
//

import Foundation

/// A self-cleaning scratch directory.
final class TempWorkspace: @unchecked Sendable {
    let url: URL

    init(name: String = "ArchiveCatTests") {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A path inside the workspace that does not exist yet.
    func path(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Creates and returns a subdirectory.
    @discardableResult
    func makeDirectory(_ name: String) -> URL {
        let directory = path(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes a fixture archive into the workspace.
    @discardableResult
    func writeArchive(
        _ entries: [FixtureEntry],
        format: FixtureFormat,
        named name: String = "fixture"
    ) throws -> URL {
        let url = path("\(name)-\(UUID().uuidString.prefix(8)).\(format.fileExtension)")
        try ArchiveFixtureWriter.write(entries, format: format, to: url)
        return url
    }

    func write(_ contents: String, to name: String) throws -> URL {
        let url = path(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Contents at a path relative to the workspace.
    func contents(at relativePath: String) -> Data? {
        try? Data(contentsOf: path(relativePath))
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: path(relativePath).path(percentEncoded: false))
    }
}

extension URL {
    /// A path in the temporary directory that is guaranteed not to exist.
    static func uniqueTemporaryFile(_ name: String = "archive") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
    }
}
