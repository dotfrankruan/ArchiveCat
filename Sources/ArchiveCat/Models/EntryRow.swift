//
//  EntryRow.swift
//  ArchiveCat
//
//  One row of the file list.
//
//  Rows are not entries: a directory that only exists because a child path
//  implied it has no `ArchiveEntry` of its own, and search results mix entries
//  from different directories. `EntryRow` is the presentation-level unifier,
//  and it carries pre-computed sort keys so `Table` can sort without touching
//  the archive order.
//

import ArchiveCore
import Foundation

struct EntryRow: Identifiable, Hashable {

    /// Where the row came from, and therefore what identity means for it.
    enum Source: Hashable {
        /// A real entry in the archive.
        case entry(ArchiveEntryID)
        /// A directory that exists only because a child path implied it.
        case impliedDirectory(String)
    }

    let source: Source
    /// `nil` for implied directories.
    let entry: ArchiveEntry?

    /// Stable identity for selection and diffing.
    var id: String {
        switch source {
        case let .entry(identifier): return "e\(identifier.ordinal)"
        case let .impliedDirectory(path): return "d\(path)"
        }
    }

    /// Normalized path inside the archive.
    let path: String
    let name: String
    let isDirectory: Bool
    /// `nil` when the row sits directly in the directory being listed.
    let containingPath: String?
    /// Directory path for directory rows, so double-click can navigate there.
    let directoryPath: String?

    // MARK: Display values

    let uncompressedSize: Int64?
    let compressedSize: Int64?
    let compressedSizeIsEstimated: Bool
    let compressionRatio: Double?
    let modificationDate: Date?
    let posixMode: UInt16?
    let uid: UInt32?
    let gid: UInt32?
    let symlinkTarget: String?
    let hardlinkTarget: String?
    let type: EntryType
    let kindName: String
    let permissionString: String?
    let octalPermissions: String?
    let crc32: UInt32?

    // MARK: Sort keys
    //
    // `Table` sorts with `KeyPathComparator`, which compares with `<`. The keys
    // below fold in the behaviours users expect from Finder: folders before
    // files for name sorting, and case/diacritic-insensitive comparison.

    /// "0name" for folders, "1name" for files, so a name sort keeps folders on top.
    let sortName: String
    let sortSize: Int64
    let sortCompressed: Int64
    let sortRatio: Double
    let sortModified: Date
    let sortKind: String
    let sortPermissions: UInt16
    let sortUID: Int64
    let sortGID: Int64
    let sortSymlink: String

    init(entry: ArchiveEntry, containingPath: String?) {
        self.source = .entry(entry.id)
        self.entry = entry
        self.path = entry.path
        self.name = entry.name
        self.isDirectory = entry.isDirectory
        self.containingPath = containingPath
        self.directoryPath = entry.isDirectory ? entry.path : nil

        self.uncompressedSize = entry.uncompressedSize
        self.compressedSize = entry.compressedSize
        self.compressedSizeIsEstimated = entry.compressedSizeIsEstimated
        self.compressionRatio = entry.compressionRatio
        self.modificationDate = entry.modificationDate
        self.posixMode = entry.posixMode
        self.uid = entry.uid
        self.gid = entry.gid
        self.symlinkTarget = entry.symlinkTarget
        self.hardlinkTarget = entry.hardlinkTarget
        self.type = entry.type
        self.kindName = FileKindDescription.describe(entry)
        self.permissionString = entry.permissionString
        self.octalPermissions = entry.octalPermissionString
        self.crc32 = entry.crc32

        self.sortName = Self.fold(entry.name, isDirectory: entry.isDirectory)
        self.sortSize = entry.uncompressedSize ?? -1
        self.sortCompressed = entry.compressedSize ?? -1
        self.sortRatio = entry.compressionRatio ?? -1
        self.sortModified = entry.modificationDate ?? .distantPast
        self.sortKind = self.kindName.foldedForSorting
        self.sortPermissions = entry.posixMode ?? 0
        self.sortUID = entry.uid.map(Int64.init) ?? -1
        self.sortGID = entry.gid.map(Int64.init) ?? -1
        self.sortSymlink = entry.symlinkTarget ?? ""
    }

    init(directory: ArchiveDirectory, containingPath: String?) {
        self.source = .impliedDirectory(directory.path)
        self.entry = nil
        self.path = directory.path
        self.name = directory.name
        self.isDirectory = true
        self.containingPath = containingPath
        self.directoryPath = directory.path

        self.uncompressedSize = nil
        self.compressedSize = nil
        self.compressedSizeIsEstimated = false
        self.compressionRatio = nil
        self.modificationDate = nil
        self.posixMode = nil
        self.uid = nil
        self.gid = nil
        self.symlinkTarget = nil
        self.hardlinkTarget = nil
        self.type = .directory
        self.kindName = "Folder"
        self.permissionString = nil
        self.octalPermissions = nil
        self.crc32 = nil

        self.sortName = Self.fold(directory.name, isDirectory: true)
        self.sortSize = -1
        self.sortCompressed = -1
        self.sortRatio = -1
        self.sortModified = .distantPast
        self.sortKind = "Folder"
        self.sortPermissions = 0
        self.sortUID = -1
        self.sortGID = -1
        self.sortSymlink = ""
    }

    var entryID: ArchiveEntryID? {
        if case let .entry(identifier) = source { return identifier }
        return nil
    }

    /// True when the row is a synthesized directory with no entry behind it.
    var isImpliedDirectory: Bool { entry == nil }

    var isSymlink: Bool { type == .symbolicLink }
    var isSearchResult: Bool { containingPath != nil && containingPath != "" }

    // MARK: Helpers

    /// Case- and diacritic-insensitive sort key, prefixed so folders sort first
    /// exactly like Finder's list view.
    private static func fold(_ name: String, isDirectory: Bool) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                 locale: Locale.current)
        return (isDirectory ? "0" : "1") + folded
    }
}

extension String {
    var foldedForSorting: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale.current)
    }
}

/// Human-readable "Kind" values, built from what the archive records rather
/// than from the file extension alone.
enum FileKindDescription {
    static func describe(_ entry: ArchiveEntry) -> String {
        switch entry.type {
        case .directory:
            return entry.name.lowercased().hasSuffix(".app") ? "Application" : "Folder"
        case .symbolicLink:
            return "Alias"
        case .hardLink:
            return "Hard link"
        case .fifo:
            return "FIFO"
        case .socket:
            return "Socket"
        case .characterDevice:
            return "Character device"
        case .blockDevice:
            return "Block device"
        case .unknown:
            return "Unknown"
        case .regularFile:
            return describeFile(entry)
        }
    }

    private static func describeFile(_ entry: ArchiveEntry) -> String {
        guard let fileExtension = entry.fileExtension else {
            return entry.name.hasPrefix("#!") ? "Script" : "Document"
        }

        // A short, deliberately conservative table of the kinds technical users
        // look for. libarchive gives us no content type, so anything not
        // recognised falls back to the extension itself, title-cased.
        switch fileExtension {
        case "dylib", "so", "dll": return "Dynamic library"
        case "a", "lib": return "Static library"
        case "o", "obj": return "Object file"
        case "sh", "bash", "zsh", "fish", "py", "rb", "pl", "js", "ts": return "Script"
        case "json": return "JSON"
        case "plist": return "Property list"
        case "xml": return "XML"
        case "html", "htm": return "HTML"
        case "md", "markdown": return "Markdown"
        case "txt", "text", "log": return "Text"
        case "png", "jpg", "jpeg", "gif", "tiff", "heic", "webp", "bmp": return "Image"
        case "mp3", "m4a", "aac", "wav", "flac", "ogg": return "Audio"
        case "mp4", "mov", "m4v", "avi", "mkv": return "Movie"
        case "pdf": return "PDF"
        case "zip", "jar", "war", "ipa", "apk": return "ZIP archive"
        case "gz", "tgz": return "Gzip archive"
        case "bz2": return "Bzip2 archive"
        case "xz", "txz": return "XZ archive"
        case "zst", "tzst": return "Zstandard archive"
        case "tar": return "Tar archive"
        case "7z": return "7-Zip archive"
        case "rar": return "RAR archive"
        case "dmg": return "Disk image"
        case "iso": return "Disk image"
        case "app": return "Application"
        case "swift", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "go", "java": return "Source code"
        default: return fileExtension.uppercased() + " file"
        }
    }
}
