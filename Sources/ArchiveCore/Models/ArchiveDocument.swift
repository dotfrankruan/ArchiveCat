//
//  ArchiveDocument.swift
//  ArchiveCore
//
//  The browsable result of scanning an archive: the flat entry list, the
//  virtual directory tree and the archive-level summary.
//
//  A document is an immutable value type built once per scan. The UI may hold
//  it for as long as a window is open; it owns no file handles.
//

import Foundation

// MARK: - Archive identity

/// Stable-enough identity of an archive *file* for cache keys.
///
/// A preview cache keyed only on the archive's path would collide when a user
/// re-downloads a different file to the same name, so the file's size and
/// modification date are part of the identity. The inode is included when
/// available to distinguish two different files that happen to share both.
public struct ArchiveIdentity: Sendable, Hashable {
    public let path: String
    public let fileSize: Int64?
    public let modificationDate: Date?
    public let fileResourceIdentifier: String?

    public init(path: String, fileSize: Int64?, modificationDate: Date?, fileResourceIdentifier: String?) {
        self.path = path
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.fileResourceIdentifier = fileResourceIdentifier
    }

    /// Reads identity from disk, degrading gracefully when metadata is denied.
    public static func capture(_ url: URL) -> ArchiveIdentity {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return ArchiveIdentity(
            path: url.path(percentEncoded: false),
            fileSize: values?.fileSize.map(Int64.init),
            modificationDate: values?.contentModificationDate,
            fileResourceIdentifier: values?.fileResourceIdentifier.map { String(describing: $0) }
        )
    }

    /// Stable string used as a cache-key ingredient.
    public var cacheKeyComponent: String {
        var parts = [path]
        if let fileSize { parts.append("size=\(fileSize)") }
        if let modificationDate { parts.append("mtime=\(Int(modificationDate.timeIntervalSince1970))") }
        if let fileResourceIdentifier { parts.append("id=\(fileResourceIdentifier)") }
        return parts.joined(separator: "|")
    }
}

// MARK: - Document

/// One scanned archive.
public struct ArchiveDocument: Sendable, Identifiable {
    public let id: UUID
    /// Where the archive lives.
    public let url: URL
    /// Identity of the archive file for cache keys.
    public let identity: ArchiveIdentity
    /// Every entry, in archive order, including entries whose paths were
    /// rejected (they carry `safety == .unsafe`).
    public let entries: [ArchiveEntry]
    /// The virtual directory hierarchy, excluding unsafe entries.
    public let tree: ArchiveTree
    /// Archive-level facts for the summary strip.
    public let summary: ArchiveSummary
    /// Container identification.
    public let format: ArchiveFormatInfo
    /// Non-fatal observations to surface.
    public let warnings: [ArchiveWarning]
    /// How long the metadata scan took.
    public let scanDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        url: URL,
        identity: ArchiveIdentity,
        entries: [ArchiveEntry],
        tree: ArchiveTree,
        summary: ArchiveSummary,
        format: ArchiveFormatInfo,
        warnings: [ArchiveWarning],
        scanDuration: TimeInterval
    ) {
        self.id = id
        self.url = url
        self.identity = identity
        self.entries = entries
        self.tree = tree
        self.summary = summary
        self.format = format
        self.warnings = warnings
        self.scanDuration = scanDuration
    }

    // MARK: Convenience

    public var fileName: String { url.lastPathComponent }

    public var rootDirectory: ArchiveDirectory { tree.root }

    /// Entries directly inside `directoryPath`, in archive order.
    public func entries(in directoryPath: String) -> [ArchiveEntry] {
        guard let directory = tree.directory(at: directoryPath) else { return [] }
        return directory.childEntryIndices.map { entries[$0] }
    }

    /// The entry an archive stored for a directory, when it stored one.
    ///
    /// Explicit directory entries live on their directory node rather than in
    /// the parent's child list, so this is the supported way to reach them.
    public func directoryEntry(at path: String) -> ArchiveEntry? {
        guard let index = tree.directory(at: path)?.entryIndex else { return nil }
        return entries.indices.contains(index) ? entries[index] : nil
    }

    /// Directories directly inside `directoryPath`.
    public func subdirectories(of directoryPath: String) -> [ArchiveDirectory] {
        guard let directory = tree.directory(at: directoryPath) else { return [] }
        return directory.childDirectoryPaths.compactMap { tree.directory(at: $0) }
    }

    /// Entries whose path is unsafe and therefore absent from the tree.
    public var unsafeEntries: [ArchiveEntry] {
        tree.unsafeEntryIndices.map { entries[$0] }
    }

    public func entry(withID id: ArchiveEntryID) -> ArchiveEntry? {
        entries.first { $0.id == id }
    }

    /// Index of an entry in `entries`, used to reach tree metadata.
    public func index(of entry: ArchiveEntry) -> Int? {
        entries.firstIndex { $0.id == entry.id }
    }

    /// An entry plus every descendant of it (a single file yields itself).
    ///
    /// Explicitly selected entries are kept even when their path is unsafe:
    /// the extraction service refuses them, and the user deserves to see *why*
    /// an entry they selected did not appear rather than have it vanish.
    public func expandingRecursively(_ selection: [ArchiveEntry]) -> [ArchiveEntry] {
        var seen = Set<ArchiveEntryID>()
        var result: [ArchiveEntry] = []

        for entry in selection {
            if seen.insert(entry.id).inserted {
                result.append(entry)
            }
            // Only safe directories can contribute descendants; an unsafe path
            // has no place in the tree by definition.
            guard entry.isDirectory, entry.safety.isSafe else { continue }
            let prefix = entry.path + "/"
            for candidate in entries
            where candidate.safety.isSafe && candidate.path.hasPrefix(prefix) {
                if seen.insert(candidate.id).inserted {
                    result.append(candidate)
                }
            }
        }

        // Archive order keeps a single streaming extraction pass possible.
        return result.sorted { $0.ordinal < $1.ordinal }
    }
}
