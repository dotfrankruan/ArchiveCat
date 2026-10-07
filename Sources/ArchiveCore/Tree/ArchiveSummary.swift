//
//  ArchiveSummary.swift
//  ArchiveCore
//
//  Archive-level facts shown in the summary strip and the inspector:
//  format, compression, counts, sizes and ratio.
//
//  Anything the container does not tell us stays `nil` and is rendered as "—".
//  Nothing here is inferred from the file extension.
//

import Foundation

/// What libarchive says about the container and its outermost filter.
public struct ArchiveFormatInfo: Sendable, Hashable {
    public let formatCode: Int32
    public let formatName: String?
    public let filterCode: Int32
    public let compressionName: String?
    /// `nil` when libarchive cannot tell whether entries are encrypted.
    public let hasEncryptedEntries: Bool?
    /// True when the container has no compression filter (`ARCHIVE_FILTER_NONE`).
    /// Computed in the reader, which is the only layer allowed to see C codes.
    public let isUncompressed: Bool
    public let libarchiveVersion: String

    public init(
        formatCode: Int32,
        formatName: String?,
        filterCode: Int32,
        compressionName: String?,
        hasEncryptedEntries: Bool?,
        isUncompressed: Bool,
        libarchiveVersion: String = LibArchive.versionString
    ) {
        self.formatCode = formatCode
        self.formatName = formatName
        self.filterCode = filterCode
        self.compressionName = compressionName
        self.hasEncryptedEntries = hasEncryptedEntries
        self.isUncompressed = isUncompressed
        self.libarchiveVersion = libarchiveVersion
    }
}

/// A non-fatal observation worth surfacing to the user.
public struct ArchiveWarning: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// Entries were dropped from the tree because their path is hostile.
        case unsafeEntries
        /// A path is used by both a file and a directory.
        case pathConflicts
        /// A filename could not be decoded as UTF-8 and was repaired lossily.
        case lossyFilename
        /// One or more entries are encrypted.
        case encryptedEntries
        /// Declared sizes look like a decompression bomb.
        case suspiciousSize
        /// Metadata was missing or unreadable for some entries.
        case incompleteMetadata

        public var isSecurityRelevant: Bool {
            switch self {
            case .unsafeEntries, .suspiciousSize, .encryptedEntries: return true
            case .pathConflicts, .lossyFilename, .incompleteMetadata: return false
            }
        }
    }

    public let kind: Kind
    public let message: String
    /// How many entries the warning refers to.
    public let count: Int

    public var id: String { kind.rawValue }
}

/// Everything the summary strip needs.
public struct ArchiveSummary: Sendable, Hashable {
    public let fileName: String
    public let formatName: String?
    public let formatCode: Int32
    public let compressionName: String?
    public let filterCode: Int32

    public let entryCount: Int
    public let fileCount: Int
    public let directoryCount: Int
    public let symlinkCount: Int
    public let otherTypeCount: Int

    /// Sum of the declared uncompressed sizes. Entries without a declared size
    /// contribute nothing, so this is a lower bound in exotic archives.
    public let totalUncompressedSize: Int64
    /// True when at least one entry had no declared size.
    public let totalUncompressedSizeIsPartial: Bool
    /// Size of the archive file on disk, when it could be read.
    public let archiveFileSize: Int64?
    /// Compressed bytes libarchive actually consumed.
    public let consumedCompressedBytes: Int64?

    public let unsafeEntryCount: Int
    public let conflictingPathCount: Int
    public let synthesizedDirectoryCount: Int
    public let hasEncryptedEntries: Bool?
    public let isUncompressedContainer: Bool
    public let libarchiveVersion: String

    public init(
        fileName: String,
        format: ArchiveFormatInfo,
        entries: [ArchiveEntry],
        tree: ArchiveTree,
        archiveFileSize: Int64?,
        consumedCompressedBytes: Int64?
    ) {
        self.fileName = fileName
        self.formatName = format.formatName
        self.formatCode = format.formatCode
        self.compressionName = format.compressionName
        self.filterCode = format.filterCode
        self.hasEncryptedEntries = format.hasEncryptedEntries
        self.isUncompressedContainer = format.isUncompressed
        self.libarchiveVersion = format.libarchiveVersion

        var files = 0
        var directories = 0
        var symlinks = 0
        var others = 0
        var total: Int64 = 0
        var partial = false

        for entry in entries where entry.safety.isSafe {
            switch entry.type {
            case .directory: directories += 1
            case .regularFile, .hardLink: files += 1
            case .symbolicLink: symlinks += 1
            default: others += 1
            }
            if let size = entry.uncompressedSize {
                total += size
            } else if !entry.isDirectory {
                partial = true
            }
        }

        self.entryCount = entries.count
        self.fileCount = files
        self.directoryCount = directories
        self.symlinkCount = symlinks
        self.otherTypeCount = others
        self.totalUncompressedSize = total
        self.totalUncompressedSizeIsPartial = partial
        self.archiveFileSize = archiveFileSize
        self.consumedCompressedBytes = consumedCompressedBytes
        self.unsafeEntryCount = tree.unsafeEntryIndices.count
        self.conflictingPathCount = tree.conflictingEntryIndices.count
        self.synthesizedDirectoryCount = tree.synthesizedDirectoryCount
    }

    // MARK: Derived values

    /// Size to compare against the uncompressed total.
    ///
    /// The archive file size is the honest measure for "how big is this on
    /// disk"; the bytes libarchive consumed is used only when the file size is
    /// unavailable (for example reading from a stream).
    public var comparableCompressedSize: Int64? {
        if let archiveFileSize, archiveFileSize > 0 { return archiveFileSize }
        if let consumedCompressedBytes, consumedCompressedBytes > 0 { return consumedCompressedBytes }
        return nil
    }

    /// Fraction of the original size that was saved by compression, `0...1`.
    ///
    /// Matches the "Ratio: 73.5%" figure from the product brief: for a 2.31 GB
    /// payload stored in a 612 MB archive this reports 0.735.
    public var compressionRatio: Double? {
        guard let compressed = comparableCompressedSize, compressed > 0,
              totalUncompressedSize > 0
        else { return nil }
        return max(0, min(1, 1 - (Double(compressed) / Double(totalUncompressedSize))))
    }

    /// "POSIX tar • Zstandard", or just the format when there is no filter.
    public var formatDescription: String {
        let format = formatName ?? "Unknown format"
        guard let compressionName else { return format }
        return "\(format) • \(compressionName)"
    }
}
