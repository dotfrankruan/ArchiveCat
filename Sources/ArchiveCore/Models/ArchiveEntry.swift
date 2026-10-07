//
//  ArchiveEntry.swift
//  ArchiveCore
//
//  A single member of an archive, reduced to the metadata macOS cares about.
//
//  Nothing in here knows about libarchive: `LibArchiveBridge` produces these.
//

import Foundation

// MARK: - Identity

/// Stable identity for an entry.
///
/// Archives are allowed to contain the exact same path twice (this really
/// happens with hand-rolled ZIPs and with `tar` concatenations), so identity is
/// derived from the entry's ordinal position in the archive, with the path kept
/// only to make debugging and logging readable.
public struct ArchiveEntryID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Zero-based position of the header in the archive stream.
    public let ordinal: Int
    /// Normalized archive path at the time the entry was read.
    public let path: String

    public init(ordinal: Int, path: String) {
        self.ordinal = ordinal
        self.path = path
    }

    public var description: String { "#\(ordinal) \(path)" }
}

// MARK: - Entry type

/// The kind of filesystem object an entry describes.
///
/// Archives are not collections of regular files: tarballs routinely carry
/// symlinks, hard links, FIFOs and device nodes, and ArchiveCat surfaces them
/// faithfully instead of pretending they are files.
public enum EntryType: String, Sendable, Codable, CaseIterable {
    case regularFile
    case directory
    case symbolicLink
    case hardLink
    case fifo
    case socket
    case characterDevice
    case blockDevice
    case unknown

    public var localizedName: String {
        switch self {
        case .regularFile: return "File"
        case .directory: return "Folder"
        case .symbolicLink: return "Symbolic link"
        case .hardLink: return "Hard link"
        case .fifo: return "FIFO"
        case .socket: return "Socket"
        case .characterDevice: return "Character device"
        case .blockDevice: return "Block device"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol used when no type-specific icon is available.
    public var symbolName: String {
        switch self {
        case .regularFile: return "doc"
        case .directory: return "folder"
        case .symbolicLink: return "arrowshape.turn.up.right"
        case .hardLink: return "link"
        case .fifo: return "arrow.left.arrow.right"
        case .socket: return "circle.grid.cross"
        case .characterDevice: return "cpu"
        case .blockDevice: return "externaldrive"
        case .unknown: return "questionmark.square.dashed"
        }
    }
}

// MARK: - Safety

/// Result of validating an entry's raw path.
public enum PathSafety: Sendable, Hashable {
    case safe
    case unsafe(PathSafetyViolation)

    public var isSafe: Bool { self == .safe }

    public var violation: PathSafetyViolation? {
        if case let .unsafe(violation) = self { return violation }
        return nil
    }
}

// MARK: - Entry

/// One member of an archive.
///
/// Sizes and identifiers are optional on purpose: many formats omit them, and
/// the UI shows “—” rather than inventing values.
public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    public let id: ArchiveEntryID

    /// Position in the archive stream. Used for targeted extraction and for
    /// preserving archive order independently of any UI sorting.
    public let ordinal: Int

    /// Path exactly as stored in the archive, before normalization.
    public let rawPath: String

    /// Normalized, traversal-free archive path (`usr/bin/bash`). Empty for the
    /// synthetic archive root.
    public let path: String

    /// Last path component (`bash`).
    public let name: String

    /// Normalized parent path, `nil` at the archive root.
    public let parentPath: String?

    public let type: EntryType

    /// Size after decompression, when the format records it.
    public let uncompressedSize: Int64?

    /// Size inside the archive, when that is knowable. `nil` for most
    /// compressed formats because libarchive does not expose per-entry
    /// compressed sizes.
    public let compressedSize: Int64?

    /// True when `compressedSize` was derived (uncompressed container) rather
    /// than read from the archive, so the UI can show “≈”.
    public let compressedSizeIsEstimated: Bool

    public let modificationDate: Date?

    /// POSIX permission bits, including setuid/setgid/sticky.
    public let posixMode: UInt16?

    public let uid: UInt32?
    public let gid: UInt32?
    public let linkCount: UInt32?

    public let symlinkTarget: String?
    public let hardlinkTarget: String?

    /// Only ever populated when the container records one; nil otherwise.
    public let crc32: UInt32?

    public let deviceMajor: UInt32?
    public let deviceMinor: UInt32?

    /// Whether the raw path was safe to place in the virtual tree.
    public let safety: PathSafety

    /// Format-specific detail worth showing in the inspector (e.g. ZIP method).
    public let formatDetail: String?

    public init(
        id: ArchiveEntryID,
        ordinal: Int,
        rawPath: String,
        path: String,
        name: String,
        parentPath: String?,
        type: EntryType,
        uncompressedSize: Int64? = nil,
        compressedSize: Int64? = nil,
        compressedSizeIsEstimated: Bool = false,
        modificationDate: Date? = nil,
        posixMode: UInt16? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        linkCount: UInt32? = nil,
        symlinkTarget: String? = nil,
        hardlinkTarget: String? = nil,
        crc32: UInt32? = nil,
        deviceMajor: UInt32? = nil,
        deviceMinor: UInt32? = nil,
        safety: PathSafety = .safe,
        formatDetail: String? = nil
    ) {
        self.id = id
        self.ordinal = ordinal
        self.rawPath = rawPath
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.type = type
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.compressedSizeIsEstimated = compressedSizeIsEstimated
        self.modificationDate = modificationDate
        self.posixMode = posixMode
        self.uid = uid
        self.gid = gid
        self.linkCount = linkCount
        self.symlinkTarget = symlinkTarget
        self.hardlinkTarget = hardlinkTarget
        self.crc32 = crc32
        self.deviceMajor = deviceMajor
        self.deviceMinor = deviceMinor
        self.safety = safety
        self.formatDetail = formatDetail
    }

    // MARK: Convenience

    public var isDirectory: Bool { type == .directory }
    public var isSymlink: Bool { type == .symbolicLink }
    public var isRegularFile: Bool { type == .regularFile }

    /// True for anything the user can meaningfully "open" as a file.
    public var isFileLike: Bool {
        switch type {
        case .regularFile, .symbolicLink, .hardLink: return true
        default: return false
        }
    }

    /// Lowercase extension without the dot, or `nil` when there is none.
    public var fileExtension: String? {
        guard !isDirectory else { return nil }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// Fraction of the original size that compression removed, in `0...1`.
    /// Matches the “Ratio” figure shown in the archive summary.
    public var compressionRatio: Double? {
        guard let uncompressed = uncompressedSize, uncompressed > 0,
              let compressed = compressedSize, compressed >= 0
        else { return nil }
        return max(0, min(1, 1 - (Double(compressed) / Double(uncompressed))))
    }

    /// `drwxr-xr-x`-style string, or `nil` when the archive records no mode.
    public var permissionString: String? {
        guard let mode = posixMode else { return nil }
        return POSIXModeFormatter.string(mode: mode, type: type)
    }

    /// Octal representation such as `0755`.
    public var octalPermissionString: String? {
        guard let mode = posixMode else { return nil }
        return String(format: "%04o", mode & 0o7777)
    }

    /// Depth in the virtual tree; 0 for entries at the archive root.
    public var depth: Int {
        path.isEmpty ? 0 : path.reduce(1) { $1 == "/" ? $0 + 1 : $0 }
    }
}

// MARK: - Permission formatting

/// Turns POSIX mode bits into the string macOS users expect to see in
/// `ls -l` and in Finder's Get Info panel.
public enum POSIXModeFormatter {
    public static func string(mode: UInt16, type: EntryType) -> String {
        var result = String(typeCharacter(for: type))

        let permissions: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]

        for (index, element) in permissions.enumerated() {
            let bit = element.0
            var character = element.1
            if mode & bit == 0 {
                character = "-"
            } else if element.1 == "x" {
                // Fold setuid / setgid / sticky into the execute slot, exactly
                // like `strmode(3)` does.
                switch index {
                case 2: character = (mode & 0o4000) != 0 ? "s" : "x"
                case 5: character = (mode & 0o2000) != 0 ? "s" : "x"
                case 8: character = (mode & 0o1000) != 0 ? "t" : "x"
                default: break
                }
            }
            result.append(character)
        }

        // setuid without execute is uppercase S, setgid likewise, sticky T.
        var characters = Array(result)
        if mode & 0o4000 != 0, mode & 0o100 == 0 { characters[3] = "S" }
        if mode & 0o2000 != 0, mode & 0o010 == 0 { characters[6] = "S" }
        if mode & 0o1000 != 0, mode & 0o001 == 0 { characters[9] = "T" }
        return String(characters)
    }

    private static func typeCharacter(for type: EntryType) -> Character {
        switch type {
        case .directory: return "d"
        case .symbolicLink: return "l"
        case .fifo: return "p"
        case .socket: return "s"
        case .characterDevice: return "c"
        case .blockDevice: return "b"
        case .regularFile, .hardLink, .unknown: return "-"
        }
    }
}
