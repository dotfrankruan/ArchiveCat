//
//  ExtractionOptions.swift
//  ArchiveCore
//
//  Value types describing how to extract, what happened, and what to ask the
//  user about beforehand.
//

import Foundation

// MARK: - Options

/// How to behave when the destination already contains a file.
public enum ExtractionConflictPolicy: String, Sendable, CaseIterable, Codable {
    /// The caller must resolve conflicts before starting. The service treats it
    /// as `.replace` if it somehow reaches extraction, and logs the fact.
    case ask
    /// Overwrite the existing file. Only ever selected by an explicit user
    /// choice: nothing in ArchiveCat overwrites silently.
    case replace
    /// Leave the existing file alone and report the entry as skipped.
    case skip
    /// Write alongside the existing file as "name 2.ext".
    case keepBoth

    public var localizedName: String {
        switch self {
        case .ask: return "Ask"
        case .replace: return "Replace"
        case .skip: return "Skip"
        case .keepBoth: return "Keep Both"
        }
    }
}

/// Bounds that protect against decompression bombs.
///
/// `nil` means "no limit". ArchiveCat ships with no hard limits by default —
/// the user asked to extract, and the archive's declared sizes are shown before
/// they confirm — but every limit is enforced when configured, and a cancelled
/// operation always stops promptly.
public struct ExtractionLimits: Sendable, Hashable {
    public var maximumEntryCount: Int?
    public var maximumTotalBytes: Int64?
    public var maximumSingleEntryBytes: Int64?
    /// Reject when uncompressed bytes exceed this multiple of the archive size.
    public var maximumExpansionRatio: Double?

    public init(
        maximumEntryCount: Int? = nil,
        maximumTotalBytes: Int64? = nil,
        maximumSingleEntryBytes: Int64? = nil,
        maximumExpansionRatio: Double? = nil
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumSingleEntryBytes = maximumSingleEntryBytes
        self.maximumExpansionRatio = maximumExpansionRatio
    }

    public static let unlimited = ExtractionLimits()

    /// Caps that would refuse anything above 50 GB or a 10 000× expansion.
    /// Offered in the UI as "Safe extraction".
    public static let conservative = ExtractionLimits(
        maximumEntryCount: 2_000_000,
        maximumTotalBytes: 50 * 1024 * 1024 * 1024,
        maximumSingleEntryBytes: 20 * 1024 * 1024 * 1024,
        maximumExpansionRatio: 10_000
    )
}

/// Everything the extraction service needs.
public struct ExtractionOptions: Sendable {
    /// Conflict behaviour. Resolved by the UI before extraction starts.
    public var conflictPolicy: ExtractionConflictPolicy
    /// Apply the archive's permission bits to extracted files.
    public var preservePermissions: Bool
    /// Apply the archive's modification dates, directories last.
    public var preserveModificationDates: Bool
    /// Strip setuid/setgid bits. On by default: an archive is untrusted input
    /// and ArchiveCat has no business creating setuid files on the user's disk.
    public var stripSetuidAndSetgid: Bool
    /// Refuse to start when the declared payload does not fit on the volume.
    public var checkAvailableSpace: Bool
    /// Safety bounds.
    public var limits: ExtractionLimits
    /// Number of leading path components to drop ("strip components").
    public var stripLeadingPathComponents: Int
    /// Create device nodes, sockets and FIFOs. Off by default: they are almost
    /// never what a user wants and cannot be created without privileges anyway.
    public var extractSpecialFiles: Bool

    public init(
        conflictPolicy: ExtractionConflictPolicy = .replace,
        preservePermissions: Bool = true,
        preserveModificationDates: Bool = true,
        stripSetuidAndSetgid: Bool = true,
        checkAvailableSpace: Bool = true,
        limits: ExtractionLimits = .unlimited,
        stripLeadingPathComponents: Int = 0,
        extractSpecialFiles: Bool = false
    ) {
        self.conflictPolicy = conflictPolicy
        self.preservePermissions = preservePermissions
        self.preserveModificationDates = preserveModificationDates
        self.stripSetuidAndSetgid = stripSetuidAndSetgid
        self.checkAvailableSpace = checkAvailableSpace
        self.limits = limits
        self.stripLeadingPathComponents = stripLeadingPathComponents
        self.extractSpecialFiles = extractSpecialFiles
    }

    public static let `default` = ExtractionOptions()
}

// MARK: - Progress

public struct ExtractionProgress: Sendable, Hashable {
    public let completedEntries: Int
    public let totalEntries: Int
    public let bytesWritten: Int64
    public let currentPath: String?

    public init(completedEntries: Int, totalEntries: Int, bytesWritten: Int64, currentPath: String?) {
        self.completedEntries = completedEntries
        self.totalEntries = totalEntries
        self.bytesWritten = bytesWritten
        self.currentPath = currentPath
    }

    public var fractionCompleted: Double? {
        guard totalEntries > 0 else { return nil }
        return min(1, Double(completedEntries) / Double(totalEntries))
    }
}

// MARK: - Report

/// Why an entry was not extracted.
public enum ExtractionSkipReason: String, Sendable, Codable {
    /// The destination already contained a file and the policy was `.skip`.
    case alreadyExists
    /// The entry's path failed validation.
    case unsafePath
    /// Symlinks, device nodes, sockets and FIFOs are not materialised.
    case unsupportedType
    /// The entry was a hard link whose target was not extracted.
    case missingHardlinkTarget

    public var localizedDescription: String {
        switch self {
        case .alreadyExists: return "a file with that name already exists"
        case .unsafePath: return "its path is not safe to write"
        case .unsupportedType: return "ArchiveCat does not extract this kind of entry"
        case .missingHardlinkTarget: return "its hard link target was not extracted"
        }
    }
}

/// The outcome of one extraction operation.
public struct ExtractionReport: Sendable {
    public struct Item: Sendable {
        public let entry: ArchiveEntry
        public let destination: URL
        public let bytesWritten: Int64
    }

    public struct Skipped: Sendable {
        public let entry: ArchiveEntry
        public let destination: URL?
        public let reason: ExtractionSkipReason
    }

    public struct Failure: Sendable {
        public let entry: ArchiveEntry
        public let destination: URL?
        public let error: ArchiveError
    }

    public let destination: URL
    public var extracted: [Item]
    public var skipped: [Skipped]
    public var failures: [Failure]
    public var totalBytesWritten: Int64
    public var duration: TimeInterval
    public var wasCancelled: Bool

    public init(
        destination: URL,
        extracted: [Item] = [],
        skipped: [Skipped] = [],
        failures: [Failure] = [],
        totalBytesWritten: Int64 = 0,
        duration: TimeInterval = 0,
        wasCancelled: Bool = false
    ) {
        self.destination = destination
        self.extracted = extracted
        self.skipped = skipped
        self.failures = failures
        self.totalBytesWritten = totalBytesWritten
        self.duration = duration
        self.wasCancelled = wasCancelled
    }

    public var extractedCount: Int { extracted.count }
    public var isEmpty: Bool { extracted.isEmpty && skipped.isEmpty && failures.isEmpty }

    /// First failure, for building a user-facing error.
    public var firstFailure: Failure? { failures.first }
}

// MARK: - Preflight

/// An entry whose destination already exists.
public struct ExtractionConflict: Sendable, Identifiable {
    public let entry: ArchiveEntry
    public let existingURL: URL

    public var id: ArchiveEntryID { entry.id }
}

/// Read-only checks that run *before* anything is written, so the UI can put a
/// real question to the user instead of discovering conflicts midway.
public enum ExtractionPreflight {
    /// Existing files that the extraction would collide with.
    public static func conflicts(
        entries: [ArchiveEntry],
        in destination: URL,
        options: ExtractionOptions = .default
    ) -> [ExtractionConflict] {
        let fileManager = FileManager.default
        var conflicts: [ExtractionConflict] = []

        for entry in entries where entry.safety.isSafe {
            guard let relative = relativePath(for: entry, options: options) else { continue }
            let url = destination.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                conflicts.append(ExtractionConflict(entry: entry, existingURL: url))
            }
        }
        return conflicts
    }

    /// The path an entry will be written to, relative to the destination root.
    ///
    /// * never absolute;
    /// * never containing `.` or `..`;
    /// * with `stripLeadingPathComponents` applied.
    public static func relativePath(for entry: ArchiveEntry, options: ExtractionOptions) -> String? {
        guard entry.safety.isSafe else { return nil }

        var components = entry.path.split(separator: "/").map(String.init)
        if options.stripLeadingPathComponents > 0 {
            guard components.count > options.stripLeadingPathComponents else { return nil }
            components.removeFirst(options.stripLeadingPathComponents)
        }
        guard !components.isEmpty else { return nil }

        // Defence in depth: the components already passed `ArchivePath`, but a
        // caller could hand us an entry built by hand.
        for component in components where component.isEmpty || component == "." || component == ".." {
            return nil
        }
        return components.joined(separator: "/")
    }

    /// Free space check. Returns `nil` when the volume cannot report capacity.
    public static func availableSpace(at destination: URL) -> Int64? {
        let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        let fallback = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return fallback?.volumeAvailableCapacity.map(Int64.init)
    }
}
