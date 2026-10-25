//
//  CompressionPlan.swift
//  ArchiveCore
//
//  The planning pass for archive creation: turn a user selection of filesystem
//  paths into an ordered, validated list of archive items — before a single
//  byte is written.
//
//  Why a separate pass
//  -------------------
//  * Progress needs a total, and a total needs the sizes up front.
//  * Failing fast is much better than failing after 10 minutes of compression.
//  * Names have to be decided globally (duplicate basenames, overlapping
//    selections) and the writer should not be in the business of naming things.
//
//  Paths are plain `String`s, deliberately
//  ---------------------------------------
//  `URL.path` is not a stable string: Foundation appends a trailing slash when
//  the path happens to exist as a directory. That is not merely cosmetic — a
//  trailing slash makes `lstat` follow a symbolic link, which would defeat the
//  "never follow symlinks" rule. Every path used for I/O here is therefore a
//  canonical, slash-free `String`, and `URL` is only used at the API edges.
//
//  Semantics that are deliberate
//  -----------------------------
//  * A selected folder contributes itself as the top-level archive entry, the
//    way Finder's "Compress" does (`Project/…`, not the contents at root).
//  * Overlapping selections collapse: selecting a folder and one of its
//    children archives the child once.
//  * Duplicate top-level names are disambiguated Finder-style (`name`,
//    `name 2`) and reported, because two folders called `src` from different
//    parents is perfectly normal.
//  * Symlinks are stored as links and **never followed**. That is the whole
//    policy: it cannot read outside the selection and cannot loop, because no
//    symlink is ever traversed.
//  * Absolute paths, `..`, and the home directory never appear inside the new
//    archive; every path is built from a top-level name plus relative children.
//

import Darwin
import Foundation

// MARK: - Plan

struct CompressionPlan: Sendable {

    struct Item: Sendable {
        enum Content: Sendable {
            case file(sourcePath: String, size: Int64)
            case directory
            case symbolicLink(target: String)
        }

        /// Path inside the new archive. Directories carry a trailing slash.
        let archivePath: String
        let content: Content
        let modificationDate: Date?
        let posixMode: UInt16?
        let uid: UInt32?
        let gid: UInt32?
    }

    let items: [Item]
    let totalBytes: Int64
    let fileCount: Int
    let directoryCount: Int
    let symlinkCount: Int
    /// Human-readable notes (skipped special files, renamed duplicates).
    let warnings: [String]
    /// Top-level names, in selection order, for the summary.
    let sourceNames: [String]
}

/// A planning failure that is not yet tied to a destination.
enum CompressionPlanningError: Error, Sendable {
    case tooManyItems(limit: Int, observed: Int)
    case totalTooLarge(limit: Int64, observed: Int64)
    case singleFileTooLarge(path: String, limit: Int64, observed: Int64)
    case hierarchicalDepthExceeded(path: String, limit: Int)
    case noUsableSources

    var localizedName: String {
        switch self {
        case .tooManyItems: return "The selection contains more items than the limit allows."
        case .totalTooLarge: return "The selection is larger than the limit allows."
        case let .singleFileTooLarge(path, _, _): return "“\(path)” is larger than the limit allows."
        case let .hierarchicalDepthExceeded(path, limit): return "“\(path)” is nested more than \(limit) folders deep."
        case .noUsableSources: return "Nothing was selected to compress."
        }
    }
}

// MARK: - Planner

enum CompressionPlanner {

    /// Guards against pathological trees (and against a bug turning into an
    /// infinite recursion).
    static let maximumDepth = 512

    static func plan(sources: [URL], options: CompressionOptions) throws -> CompressionPlan {
        let roots = try normalise(sources)
        guard !roots.isEmpty else {
            throw CompressionPlanningError.noUsableSources
        }

        var builder = Builder(limits: options.limits)
        var usedTopLevelNames: Set<String> = []

        for root in roots {
            let rawName = (root as NSString).lastPathComponent
            guard !rawName.isEmpty, rawName != ".", rawName != ".." else {
                throw ArchiveError.invalidOutputName(
                    name: rawName,
                    reason: "The item has no usable name."
                )
            }
            let name = uniqueTopLevelName(rawName, used: &usedTopLevelNames, warnings: &builder.warnings)
            builder.sourceNames.append(name)
            try builder.append(path: root, archivePath: name, depth: 0)
        }

        return builder.finish()
    }

    // MARK: Source normalisation

    /// De-duplicates the selection and drops items already covered by a
    /// selected folder, then sorts for a deterministic archive order.
    ///
    /// - Returns: canonical, slash-free POSIX paths.
    private static func normalise(_ sources: [URL]) throws -> [String] {
        var unique: [String] = []
        var seenPaths: Set<String> = []

        for source in sources {
            let path = canonicalPath(source)
            guard !path.isEmpty, path != "/" else { continue }
            guard seenPaths.insert(path).inserted else { continue }
            // Fail now (not after compressing) when a source is gone.
            _ = try inspect(path: path, operation: "inspect")
            unique.append(path)
        }

        unique.sort()

        var roots: [String] = []
        for path in unique {
            let coveredBySelectedFolder = roots.contains { root in
                path.hasPrefix(root + "/")
            }
            if !coveredBySelectedFolder {
                roots.append(path)
            }
        }
        return roots
    }

    /// A slash-free POSIX path for a URL.
    ///
    /// `URL.path` appends a trailing slash when the target exists as a
    /// directory, and `lstat("a/link/")` follows the link even though
    /// `lstat("a/link")` does not. Stripping is therefore a correctness
    /// requirement, not tidiness.
    static func canonicalPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func uniqueTopLevelName(
        _ raw: String,
        used: inout Set<String>,
        warnings: inout [String]
    ) -> String {
        var candidate = raw
        var counter = 2
        while used.contains(candidate) {
            candidate = "\(raw) \(counter)"
            counter += 1
        }
        if candidate != raw {
            warnings.append("“\(raw)” appears twice in the selection; the second copy is named “\(candidate)” in the archive.")
        }
        used.insert(candidate)
        return candidate
    }

    // MARK: Builder

    private struct Builder {
        let limits: CompressionLimits
        var items: [CompressionPlan.Item] = []
        var totalBytes: Int64 = 0
        var fileCount = 0
        var directoryCount = 0
        var symlinkCount = 0
        var warnings: [String] = []
        var sourceNames: [String] = []

        init(limits: CompressionLimits) {
            self.limits = limits
        }

        mutating func append(path: String, archivePath: String, depth: Int) throws {
            guard depth <= CompressionPlanner.maximumDepth else {
                throw CompressionPlanningError.hierarchicalDepthExceeded(
                    path: archivePath,
                    limit: CompressionPlanner.maximumDepth
                )
            }

            let info = try CompressionPlanner.inspect(path: path, operation: "inspect")
            let type = POSIXFileType.of(stat: info)

            switch type {
            case POSIXFileType.directory:
                let directoryPath = try CompressionPlanner.validate(archivePath: archivePath, isDirectory: true)
                try add(CompressionPlan.Item(
                    archivePath: directoryPath,
                    content: .directory,
                    modificationDate: CompressionPlanner.date(from: info),
                    posixMode: CompressionPlanner.modeBits(from: info),
                    uid: info.st_uid,
                    gid: info.st_gid
                ))

                let children: [String]
                do {
                    children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
                } catch {
                    throw ArchiveError.sourceUnavailable(
                        path: path,
                        reason: "The folder could not be listed. \(error.localizedDescription)"
                    )
                }
                for child in children {
                    try append(
                        path: path + "/" + child,
                        archivePath: archivePath + "/" + child,
                        depth: depth + 1
                    )
                }

            case POSIXFileType.regular:
                let filePath = try CompressionPlanner.validate(archivePath: archivePath, isDirectory: false)
                let size = Int64(info.st_size)
                if let limit = limits.maximumSingleFileBytes, size > limit {
                    throw CompressionPlanningError.singleFileTooLarge(path: filePath, limit: limit, observed: size)
                }
                try add(CompressionPlan.Item(
                    archivePath: filePath,
                    content: .file(sourcePath: path, size: size),
                    modificationDate: CompressionPlanner.date(from: info),
                    posixMode: CompressionPlanner.modeBits(from: info),
                    uid: info.st_uid,
                    gid: info.st_gid
                ))

            case POSIXFileType.symbolicLink:
                let linkPath = try CompressionPlanner.validate(archivePath: archivePath, isDirectory: false)
                let target = try CompressionPlanner.readLink(path: path)
                try add(CompressionPlan.Item(
                    archivePath: linkPath,
                    content: .symbolicLink(target: target),
                    modificationDate: CompressionPlanner.date(from: info),
                    posixMode: CompressionPlanner.modeBits(from: info),
                    uid: info.st_uid,
                    gid: info.st_gid
                ))

            default:
                // FIFOs, sockets and device nodes are skipped rather than
                // opened: reading a FIFO would block forever, and a device node
                // is not something a user means to archive.
                warnings.append("“\(archivePath)” was skipped because only files, folders and symbolic links can be archived.")
            }
        }

        private mutating func add(_ item: CompressionPlan.Item) throws {
            if let limit = limits.maximumItemCount, items.count >= limit {
                throw CompressionPlanningError.tooManyItems(limit: limit, observed: items.count + 1)
            }

            var additionalBytes: Int64 = 0
            switch item.content {
            case let .file(_, size): additionalBytes = size; fileCount += 1
            case .directory: directoryCount += 1
            case .symbolicLink: symlinkCount += 1
            }

            if let limit = limits.maximumTotalBytes, totalBytes + additionalBytes > limit {
                throw CompressionPlanningError.totalTooLarge(limit: limit, observed: totalBytes + additionalBytes)
            }

            totalBytes += additionalBytes
            items.append(item)
        }

        func finish() -> CompressionPlan {
            CompressionPlan(
                items: items,
                totalBytes: totalBytes,
                fileCount: fileCount,
                directoryCount: directoryCount,
                symlinkCount: symlinkCount,
                warnings: warnings,
                sourceNames: sourceNames
            )
        }
    }

    // MARK: POSIX helpers

    static func inspect(path: String, operation: String) throws -> stat {
        var info = stat()
        let result = path.withCString { pointer in
            lstat(pointer, &info)
        }
        guard result == 0 else {
            let errorNumber = errno
            throw ArchiveError.sourceUnavailable(
                path: path,
                reason: "\(operation) failed: \(String(cString: strerror(errorNumber)))"
            )
        }
        return info
    }

    static func readLink(path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = path.withCString { pointer in
            readlink(pointer, &buffer, buffer.count - 1)
        }
        guard length >= 0 else {
            let errorNumber = errno
            throw ArchiveError.sourceUnavailable(
                path: path,
                reason: "The symbolic link target could not be read: \(String(cString: strerror(errorNumber)))"
            )
        }
        let bytes = buffer[0..<length].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func modeBits(from info: stat) -> UInt16 {
        UInt16(info.st_mode & 0o7777)
    }

    static func date(from info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    /// Validates a generated archive path and returns the form to store.
    ///
    /// This is the same validator extraction uses, so a name that cannot be
    /// written safely back out can never be created in the first place.
    static func validate(archivePath: String, isDirectory: Bool) throws -> String {
        let candidate = isDirectory ? archivePath + "/" : archivePath
        let normalized = ArchivePath.normalize(rawPath: candidate, separatorPolicy: .posixOnly)

        guard normalized.safety.isSafe else {
            throw ArchiveError.invalidOutputName(
                name: archivePath,
                reason: normalized.safety.violation?.localizedDescription ?? "The name is not safe inside an archive."
            )
        }
        return isDirectory ? normalized.normalized + "/" : normalized.normalized
    }
}
