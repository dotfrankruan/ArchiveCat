//
//  ArchiveFormatCatalog.swift
//  ArchiveCore
//
//  The catalogue of formats ArchiveCat can *create*, and the heuristics used to
//  recognise an archive-looking name.
//
//  This is deliberately separate from the reader's format detection: libarchive
//  can read many more formats than it can write, and a format being readable
//  says nothing about whether ArchiveCat can produce it. The creatable list is
//  therefore explicit, and every entry is probed against the libarchive actually
//  linked into the app before it is offered.
//

import Foundation

// MARK: - Descriptor

/// One output format ArchiveCat can write.
public struct ArchiveFormatDescriptor: Sendable, Hashable, Identifiable {

    /// The container family.
    public enum Container: String, Sendable, Hashable, CaseIterable {
        case zip
        case tar
    }

    /// The compression filter wrapped around the container.
    public enum Filter: String, Sendable, Hashable, CaseIterable {
        case none
        case gzip
        case bzip2
        case xz
        case zstd

        /// Name libarchive uses for filter options.
        var optionName: String? {
            switch self {
            case .none: return nil
            case .gzip: return "gzip"
            case .bzip2: return "bzip2"
            case .xz: return "xz"
            case .zstd: return "zstd"
            }
        }
    }

    /// Stable identifier, also used as the persisted preference value.
    public let id: String
    /// Name shown in menus and sheets.
    public let displayName: String
    /// Extension without a leading dot; may contain one dot (`tar.gz`).
    public let fileExtension: String
    public let container: Container
    public let filter: Filter
    /// Levels the format genuinely accepts, or `nil` when it has no setting.
    public let compressionLevelRange: ClosedRange<Int>?
    public let defaultCompressionLevel: Int?

    public init(
        id: String,
        displayName: String,
        fileExtension: String,
        container: Container,
        filter: Filter,
        compressionLevelRange: ClosedRange<Int>?,
        defaultCompressionLevel: Int?
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtension = fileExtension
        self.container = container
        self.filter = filter
        self.compressionLevelRange = compressionLevelRange
        self.defaultCompressionLevel = defaultCompressionLevel
    }

    /// What the engine can do with this output format.
    public var capabilities: ArchiveCapabilities {
        let isSequentialStream = filter != .none
        return ArchiveCapabilities(
            canRead: true,
            canExtract: true,
            canCreate: true,
            supportsStreamingReads: true,
            // ZIP keeps a central directory; an unfiltered TAR is seekable. A
            // filtered TAR is a stream.
            supportsRandomAccess: container == .zip || !isSequentialStream,
            supportsEncryptedInput: false,
            // TAR records POSIX mode/ownership faithfully; ZIP only carries
            // Unix modes as an extension and truncates timestamps.
            supportsMetadataPreservation: container == .tar,
            supportsCompressionLevel: compressionLevelRange != nil,
            supportsNestedArchives: true,
            limitation: container == .zip
                ? "ZIP stores POSIX permissions best-effort and rounds timestamps to two seconds."
                : nil
        )
    }

    /// A complete file name for a base name, e.g. `Archive` → `Archive.tar.gz`.
    public func fileName(baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Archive" : trimmed
        return "\(base).\(fileExtension)"
    }

    /// Compression description for the UI ("gzip", "none").
    public var compressionDescription: String {
        switch filter {
        case .none: return "none"
        case .gzip: return "gzip"
        case .bzip2: return "bzip2"
        case .xz: return "xz"
        case .zstd: return "zstd"
        }
    }
}

// MARK: - Catalogue

public enum ArchiveFormatCatalog {

    /// Every format the engine knows how to write, before probing.
    ///
    /// Only ZIP and TAR+GZIP are required by the product brief; the rest cost a
    /// filter name each and are offered only when libarchive actually has the
    /// filter compiled in (see `creatableFormats`).
    public static let allCreatable: [ArchiveFormatDescriptor] = [
        ArchiveFormatDescriptor(
            id: "zip",
            displayName: "ZIP",
            fileExtension: "zip",
            container: .zip,
            filter: .none,
            compressionLevelRange: 0...9,
            defaultCompressionLevel: 6
        ),
        ArchiveFormatDescriptor(
            id: "tar",
            displayName: "TAR (uncompressed)",
            fileExtension: "tar",
            container: .tar,
            filter: .none,
            compressionLevelRange: nil,
            defaultCompressionLevel: nil
        ),
        ArchiveFormatDescriptor(
            id: "tar.gz",
            displayName: "TAR + gzip",
            fileExtension: "tar.gz",
            container: .tar,
            filter: .gzip,
            compressionLevelRange: 0...9,
            defaultCompressionLevel: 6
        ),
        ArchiveFormatDescriptor(
            id: "tar.bz2",
            displayName: "TAR + bzip2",
            fileExtension: "tar.bz2",
            container: .tar,
            filter: .bzip2,
            compressionLevelRange: 1...9,
            defaultCompressionLevel: 9
        ),
        ArchiveFormatDescriptor(
            id: "tar.xz",
            displayName: "TAR + xz",
            fileExtension: "tar.xz",
            container: .tar,
            filter: .xz,
            compressionLevelRange: 0...9,
            defaultCompressionLevel: 6
        ),
        ArchiveFormatDescriptor(
            id: "tar.zst",
            displayName: "TAR + zstd",
            fileExtension: "tar.zst",
            container: .tar,
            filter: .zstd,
            compressionLevelRange: 1...19,
            defaultCompressionLevel: 3
        ),
    ]

    /// Formats this build can actually write.
    ///
    /// Probed once, lazily, against the linked libarchive: a filter that was
    /// compiled out makes its format disappear from the UI instead of failing at
    /// the end of a long compression.
    public static let creatableFormats: [ArchiveFormatDescriptor] = {
        let supported = allCreatable.filter { LibArchiveWriter.probe($0) }
        if supported.count != allCreatable.count {
            let missing = allCreatable.map(\.id).filter { id in !supported.contains { $0.id == id } }
            ArchiveCatLog.archive.debug("writer filters unavailable: \(missing.joined(separator: ", "), privacy: .public)")
        }
        return supported
    }()

    public static var defaultFormat: ArchiveFormatDescriptor {
        creatableFormats.first { $0.id == "zip" } ?? allCreatable[0]
    }

    public static func format(withID id: String) -> ArchiveFormatDescriptor? {
        allCreatable.first { $0.id == id }
    }

    public static func creatableFormat(withID id: String) -> ArchiveFormatDescriptor? {
        creatableFormats.first { $0.id == id }
    }

    /// Best match for a file extension such as `tar.gz` or `zip`.
    public static func format(forFileExtension fileExtension: String) -> ArchiveFormatDescriptor? {
        let lowered = fileExtension.lowercased()
        return allCreatable.first { $0.fileExtension == lowered }
    }

    // MARK: Reading heuristics

    /// Extensions that suggest an archive, used only to decide whether to
    /// *offer* "Open Archive Inside". Opening always validates real bytes.
    public static let archiveFileExtensions: [String] = [
        "zip", "jar", "war", "ipa", "apk", "aar",
        "tar", "tar.gz", "tgz", "tar.bz2", "tbz", "tbz2", "tar.xz", "txz", "tar.zst", "tzst", "tar.lz4",
        "gz", "bz2", "xz", "zst", "lz4", "lzma",
        "7z", "rar", "cpio", "xar", "pkg", "iso", "dmg", "cab", "lha", "lzh", "ar",
        "deb", "rpm", "crx", "whl", "egg",
    ]

    /// Whether a file name looks like an archive. Never authorises anything on
    /// its own; it only controls an affordance.
    public static func isArchiveCandidate(fileName: String) -> Bool {
        let lowered = fileName.lowercased()
        for fileExtension in archiveFileExtensions where lowered.hasSuffix("." + fileExtension) {
            return true
        }
        return false
    }
}
