//
//  ArchiveTree.swift
//  ArchiveCore
//
//  Archives store flat paths; the browser needs a directory hierarchy.
//
//  Design notes
//  ------------
//  * The tree owns *no* file contents — building it only rearranges metadata.
//  * Directories that the archive never mentions explicitly are synthesized
//    from the paths of their children, which is required for the very common
//    `tar cf x.tar usr/bin/bash` case.
//  * A directory is keyed by its normalized path, so lookups are O(1) even
//    with 100 000+ entries, and the storage is plain value types: no reference
//    cycles, `Sendable` for free, cheap to hand to a background actor.
//  * Entries whose path failed validation are **not** placed in the tree. They
//    are reported separately (`unsafeEntryIndices`) so the UI can tell the user
//    that the archive contains hostile paths instead of silently hiding them.
//

import Foundation

// MARK: - Directory

/// One directory in the virtual file system.
public struct ArchiveDirectory: Sendable, Hashable, Identifiable {
    /// Normalized path; `""` is the archive root.
    public let path: String
    /// `nil` only for the root.
    public let parentPath: String?
    /// Last path component; `""` for the root.
    public let name: String
    /// Index into `ArchiveDocument.entries` when the archive stored an explicit
    /// directory entry, otherwise `nil` for a synthesized directory.
    public let entryIndex: Int?
    /// Paths of immediate subdirectories, in first-seen archive order.
    public let childDirectoryPaths: [String]
    /// Indices of entries sitting directly in this directory, in archive order.
    /// Duplicate names appear more than once: archives really do that.
    public let childEntryIndices: [Int]

    public var id: String { path }
    public var isRoot: Bool { path.isEmpty }
    public var depth: Int { ArchivePath.depth(of: path) }
    /// True when this directory only exists because a child path implied it.
    public var isSynthesized: Bool { entryIndex == nil }
}

// MARK: - Tree

/// The whole in-memory directory hierarchy of one archive.
public struct ArchiveTree: Sendable {
    /// Directory by normalized path. Always contains the root.
    public let directories: [String: ArchiveDirectory]
    /// Directory paths sorted for stable presentation order.
    public let sortedDirectoryPaths: [String]
    /// Entry indices that were excluded because their path is unsafe.
    public let unsafeEntryIndices: [Int]
    /// Entry indices whose path is both a file and a directory in the archive.
    /// Pathological, but it happens; surfaced rather than hidden.
    public let conflictingEntryIndices: [Int]
    /// Count of synthesized (implicit) directories — useful in the summary.
    public let synthesizedDirectoryCount: Int

    public static let rootPath = ""

    /// The archive root, always present.
    public var root: ArchiveDirectory {
        // Safe: the builder always inserts the root.
        directories[Self.rootPath] ?? ArchiveDirectory(
            path: Self.rootPath,
            parentPath: nil,
            name: "",
            entryIndex: nil,
            childDirectoryPaths: [],
            childEntryIndices: []
        )
    }

    public func directory(at path: String) -> ArchiveDirectory? {
        directories[path]
    }

    public func containsDirectory(at path: String) -> Bool {
        directories[path] != nil
    }

    /// Every directory path from the root down to `path`, inclusive.
    public func breadcrumb(to path: String) -> [ArchiveDirectory] {
        var result: [ArchiveDirectory] = []
        var current: String? = path
        while let candidate = current {
            guard let directory = directories[candidate] else { break }
            result.append(directory)
            current = directory.parentPath
        }
        return result.reversed()
    }

    public var isEmpty: Bool {
        root.childDirectoryPaths.isEmpty && root.childEntryIndices.isEmpty
    }
}

// MARK: - Building

/// Builds an `ArchiveTree` from a flat list of entries.
public enum ArchiveTreeBuilder {
    /// - Parameter entries: archive-order entries, as produced by the reader.
    public static func build(entries: [ArchiveEntry]) -> ArchiveTree {
        var directories: [String: MutableDirectory] = [:]
        directories[ArchiveTree.rootPath] = MutableDirectory(path: ArchiveTree.rootPath)

        var unsafeEntryIndices: [Int] = []
        var conflictingEntryIndices: [Int] = []

        // A file path that is also a directory path is a conflict; collected in
        // a first pass so the outcome does not depend on entry order.
        var filePaths: Set<String> = []
        for entry in entries where entry.safety.isSafe && !entry.isDirectory {
            filePaths.insert(entry.path)
        }

        for (index, entry) in entries.enumerated() {
            guard entry.safety.isSafe else {
                unsafeEntryIndices.append(index)
                continue
            }

            if entry.isDirectory {
                guard !entry.path.isEmpty else {
                    // An explicit entry for the root itself.
                    directories[ArchiveTree.rootPath]?.entryIndex = index
                    continue
                }
                ensureDirectory(entry.path, in: &directories)
                directories[entry.path]?.entryIndex = index
                continue
            }

            if filePaths.contains(entry.path), directories[entry.path] != nil {
                // The same path is used by a file *and* by a directory. Keep the
                // file visible and record the conflict for the summary.
                conflictingEntryIndices.append(index)
            }

            let parentPath = entry.parentPath ?? ArchiveTree.rootPath
            ensureDirectory(parentPath, in: &directories)
            directories[parentPath]?.addEntry(index)
        }

        // A file whose path is also a directory path is reported once, even if
        // the directory only exists because another entry implied it.
        if conflictingEntryIndices.isEmpty {
            for (index, entry) in entries.enumerated()
            where entry.safety.isSafe && !entry.isDirectory && directories[entry.path] != nil {
                conflictingEntryIndices.append(index)
            }
            conflictingEntryIndices.sort()
        }

        var built: [String: ArchiveDirectory] = [:]
        built.reserveCapacity(directories.count)
        var synthesized = 0
        for (path, mutable) in directories {
            if mutable.entryIndex == nil && !path.isEmpty { synthesized += 1 }
            built[path] = mutable.freeze()
        }

        return ArchiveTree(
            directories: built,
            sortedDirectoryPaths: built.keys.sorted(),
            unsafeEntryIndices: unsafeEntryIndices,
            conflictingEntryIndices: conflictingEntryIndices,
            synthesizedDirectoryCount: synthesized
        )
    }

    /// Creates `path` and every missing ancestor, linking them together.
    private static func ensureDirectory(_ path: String, in directories: inout [String: MutableDirectory]) {
        guard !path.isEmpty else {
            if directories[ArchiveTree.rootPath] == nil {
                directories[ArchiveTree.rootPath] = MutableDirectory(path: ArchiveTree.rootPath)
            }
            return
        }

        if directories[path] == nil {
            directories[path] = MutableDirectory(path: path)
        }

        // Walk the ancestors so that implicit intermediate directories exist
        // and are linked to their own parents.
        var current = ""
        var parent: String? = nil
        for component in path.split(separator: "/") {
            current = current.isEmpty ? String(component) : current + "/" + component
            if directories[current] == nil {
                directories[current] = MutableDirectory(path: current)
            }
            if let parent {
                directories[parent]?.addChildDirectory(current)
            } else {
                directories[ArchiveTree.rootPath]?.addChildDirectory(current)
            }
            parent = current
        }
    }

    /// Mutable scratch value used only while building.
    private struct MutableDirectory {
        let path: String
        var entryIndex: Int?
        var childDirectoryPaths: [String] = []
        var childDirectorySet: Set<String> = []
        var childEntryIndices: [Int] = []

        init(path: String) {
            self.path = path
        }

        mutating func addChildDirectory(_ childPath: String) {
            guard childPath != path else { return }
            guard childDirectorySet.insert(childPath).inserted else { return }
            childDirectoryPaths.append(childPath)
        }

        mutating func addEntry(_ index: Int) {
            childEntryIndices.append(index)
        }

        func freeze() -> ArchiveDirectory {
            ArchiveDirectory(
                path: path,
                parentPath: path.isEmpty ? nil : ArchivePath.parent(of: path),
                name: path.isEmpty ? "" : ArchivePath.name(of: path),
                entryIndex: entryIndex,
                childDirectoryPaths: childDirectoryPaths,
                childEntryIndices: childEntryIndices
            )
        }
    }
}
