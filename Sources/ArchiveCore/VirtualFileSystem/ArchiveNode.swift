//
//  ArchiveNode.swift
//  ArchiveCore
//
//  One item in the virtual archive filesystem.
//
//  An archive's flat path list has three kinds of item the browser has to show
//  identically: a file the archive stored, a directory the archive stored, and a
//  directory that exists only because a child path implied it (`tar cf x.tar
//  usr/bin/tool` records no `usr/` entry). `ArchiveNode` is the level view that
//  unifies them without inventing metadata: `entry` is the archive's own record
//  when there is one, and `nil` for an implied directory.
//

import Foundation

/// A browsable item: a file, an explicit directory, or an implied directory.
public struct ArchiveNode: Identifiable, Hashable, Sendable {

    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case file
        case directory

        public var localizedName: String {
            switch self {
            case .file: return "File"
            case .directory: return "Folder"
            }
        }
    }

    /// Normalized archive path. `""` is the archive root.
    public let path: String
    /// Last path component; `""` for the root.
    public let name: String
    public let kind: Kind

    /// The archive's own entry for this item, when it stored one.
    ///
    /// This *is* the metadata type; ArchiveCore deliberately does not have a
    /// second, parallel metadata struct. `nil` means the item is an implied
    /// directory.
    public let entry: ArchiveEntry?

    /// The directory record, for directories only.
    public let directory: ArchiveDirectory?

    public init(
        path: String,
        name: String,
        kind: Kind,
        entry: ArchiveEntry?,
        directory: ArchiveDirectory?
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.entry = entry
        self.directory = directory
    }

    /// Stable within one archive session.
    ///
    /// Mirrors `EntryRow`'s identity scheme: ordinal for real entries, path for
    /// implied directories. Two entries with the same path therefore stay
    /// distinct, which is the whole reason `ArchiveEntryID` exists.
    public var id: String {
        if let entry { return "e\(entry.ordinal)" }
        return "d\(path)"
    }

    /// True for a directory the archive never recorded explicitly.
    public var isImplicitDirectory: Bool { kind == .directory && entry == nil }

    public var isDirectory: Bool { kind == .directory }
    public var isFile: Bool { kind == .file }
    public var isRoot: Bool { path.isEmpty }

    /// Metadata alias, for call sites that phrase it that way.
    public var metadata: ArchiveEntry? { entry }

    public var type: EntryType { entry?.type ?? .directory }
    public var uncompressedSize: Int64? { entry?.uncompressedSize }
    public var modificationDate: Date? { entry?.modificationDate }
    public var posixMode: UInt16? { entry?.posixMode }
    public var symlinkTarget: String? { entry?.symlinkTarget }
    public var parentPath: String? {
        path.isEmpty ? nil : ArchivePath.parent(of: path)
    }

    public var fileExtension: String? { entry?.fileExtension }
}
