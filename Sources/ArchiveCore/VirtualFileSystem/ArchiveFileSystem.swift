//
//  ArchiveFileSystem.swift
//  ArchiveCore
//
//  A read-only virtual filesystem over one scanned archive.
//
//  What this is
//  ------------
//  A *view*: it arranges the metadata the scanner already produced into
//  directory enumeration, path resolution and stable lookup. It mounts nothing,
//  starts no extension, opens no file handles, and holds no state of its own
//  beyond the immutable `ArchiveDocument`. Every operation is a dictionary
//  lookup plus array indexing, so browsing an entry list never touches the
//  archive file again.
//
//  What it deliberately is not
//  ---------------------------
//  There is no write, create, rename, delete or move operation, and there never
//  will be: ArchiveCat never edits an existing archive. The type has no
//  `canModify` flag because no code path could honour one.
//
//  Safety
//  ------
//  A virtual path is a lookup key, not an authorisation. `node(at:)` returning a
//  node means "this path exists in the scanned metadata", nothing more. Anything
//  that writes re-validates the path (`ExtractionPreflight.relativePath`) and
//  writes descriptor-relative through `SecureDestination`. Entries whose paths
//  failed validation are absent from the tree and therefore absent here; they
//  remain visible through `ArchiveDocument.unsafeEntries` for reporting.
//

import Foundation

public struct ArchiveFileSystem: Sendable {

    /// The scanned archive this view belongs to.
    public let document: ArchiveDocument
    /// What the engine can do with this archive.
    public let capabilities: ArchiveCapabilities

    public init(document: ArchiveDocument, capabilities: ArchiveCapabilities? = nil) {
        self.document = document
        self.capabilities = capabilities ?? .reading(format: document.format)
    }

    // MARK: - Root and availability

    /// The archive root.
    public var root: ArchiveNode {
        let rootDirectory = document.tree.root
        return ArchiveNode(
            path: "",
            name: document.fileName,
            kind: .directory,
            entry: rootDirectory.entryIndex.flatMap { entry(atIndex: $0) },
            directory: rootDirectory
        )
    }

    public var isEmpty: Bool { document.tree.isEmpty }

    /// Whether a path denotes a directory, a file, or nothing.
    ///
    /// This is a metadata question only; it authorizes no I/O.
    public func contains(_ path: String) -> Bool {
        if path.isEmpty { return true }
        if document.tree.containsDirectory(at: path) { return true }
        return document.entries.contains { $0.safety.isSafe && $0.path == path }
    }

    public func isDirectory(at path: String) -> Bool {
        if path.isEmpty { return true }
        return document.tree.containsDirectory(at: path)
    }

    // MARK: - Enumeration

    /// Children of a directory, in archive order.
    ///
    /// Order matches the archive's own order, with subdirectories first (the
    /// order they were first seen) and explicit directory entries represented
    /// once by their directory node rather than twice.
    ///
    /// - Returns: `[]` when `path` is not a directory in this archive.
    public func children(ofDirectoryAt path: String) -> [ArchiveNode] {
        guard let directory = document.tree.directory(at: path) else { return [] }

        var nodes: [ArchiveNode] = []
        nodes.reserveCapacity(directory.childDirectoryPaths.count + directory.childEntryIndices.count)

        for childPath in directory.childDirectoryPaths {
            guard let child = document.tree.directory(at: childPath) else { continue }
            nodes.append(makeNode(directory: child, entryIndex: child.entryIndex))
        }

        for index in directory.childEntryIndices {
            guard let entry = entry(atIndex: index) else { continue }
            // An explicit directory entry is already represented by its
            // directory node above.
            if entry.isDirectory, document.tree.containsDirectory(at: entry.path) { continue }
            nodes.append(ArchiveNode(
                path: entry.path,
                name: entry.name,
                kind: entry.isDirectory ? .directory : .file,
                entry: entry,
                directory: entry.isDirectory ? document.tree.directory(at: entry.path) : nil
            ))
        }

        return nodes
    }

    /// Subdirectories only, in archive order. Used by the “implied folder”
    /// selection and by folder-list UI.
    public func subdirectories(ofDirectoryAt path: String) -> [ArchiveNode] {
        children(ofDirectoryAt: path).filter(\.isDirectory)
    }

    /// Entries directly inside a directory, archive order. Mirrors
    /// `ArchiveDocument.entries(in:)`.
    public func entries(inDirectoryAt path: String) -> [ArchiveEntry] {
        document.entries(in: path)
    }

    // MARK: - Resolution

    /// The node at `path`, or `nil` when the path does not exist.
    ///
    /// For a path that is present more than once (archives really do store the
    /// same file twice), this returns the first. Use `nodes(at:)` when every
    /// duplicate matters.
    public func node(at path: String) -> ArchiveNode? {
        if path.isEmpty { return root }
        if let directory = document.tree.directory(at: path) {
            return makeNode(directory: directory, entryIndex: directory.entryIndex)
        }
        guard let entry = document.entries.first(where: { $0.safety.isSafe && $0.path == path }) else {
            return nil
        }
        return ArchiveNode(
            path: entry.path,
            name: entry.name,
            kind: entry.isDirectory ? .directory : .file,
            entry: entry,
            directory: entry.isDirectory ? document.tree.directory(at: path) : nil
        )
    }

    /// Every node at `path`, in archive order. Duplicate paths yield several.
    public func nodes(at path: String) -> [ArchiveNode] {
        if path.isEmpty { return [root] }
        var nodes: [ArchiveNode] = []
        if let directory = document.tree.directory(at: path) {
            nodes.append(makeNode(directory: directory, entryIndex: directory.entryIndex))
        }
        for entry in document.entries where entry.safety.isSafe && entry.path == path {
            // A directory entry already contributed its directory node.
            if entry.isDirectory, document.tree.containsDirectory(at: path) { continue }
            nodes.append(ArchiveNode(
                path: entry.path,
                name: entry.name,
                kind: entry.isDirectory ? .directory : .file,
                entry: entry,
                directory: nil
            ))
        }
        return nodes
    }

    /// The archive's own entry for a path, when it stored one.
    public func metadata(at path: String) -> ArchiveEntry? {
        if let directory = document.tree.directory(at: path), let index = directory.entryIndex {
            return entry(atIndex: index)
        }
        return document.entries.first { $0.safety.isSafe && $0.path == path }
    }

    public func entry(withID id: ArchiveEntryID) -> ArchiveEntry? {
        document.entry(withID: id)
    }

    /// The entry stored for a directory, as opposed to the directory itself.
    public func directoryEntry(atDirectoryPath path: String) -> ArchiveEntry? {
        document.directoryEntry(at: path)
    }

    // MARK: - Navigation

    /// Directories from the root down to `path`, inclusive.
    public func breadcrumb(to path: String) -> [ArchiveNode] {
        document.tree.breadcrumb(to: path).map { directory in
            makeNode(directory: directory, entryIndex: directory.entryIndex)
        }
    }

    // MARK: - Nested archive candidates

    /// Whether a node's name suggests an archive the engine could open.
    ///
    /// This is only an affordance heuristic: the extension decides whether the
    /// browser *offers* "Open Archive Inside". Opening always validates the
    /// actual bytes and then really scans the member, so a misnamed file fails
    /// with a normal error instead of being trusted.
    public func isArchiveCandidate(_ node: ArchiveNode) -> Bool {
        guard node.isFile else { return false }
        return ArchiveFormatCatalog.isArchiveCandidate(fileName: node.name)
    }

    // MARK: - Helpers

    private func entry(atIndex index: Int) -> ArchiveEntry? {
        document.entries.indices.contains(index) ? document.entries[index] : nil
    }

    private func makeNode(directory: ArchiveDirectory, entryIndex: Int?) -> ArchiveNode {
        let entry = entryIndex.flatMap { entry(atIndex: $0) }
        return ArchiveNode(
            path: directory.path,
            name: directory.isRoot ? document.fileName : directory.name,
            kind: .directory,
            entry: entry,
            directory: directory
        )
    }
}
