//
//  ArchiveReading.swift
//  ArchiveCore
//
//  The interface the rest of ArchiveCat programs against.
//
//  Nothing above this file imports `CArchive`, and no C pointer, code or
//  lifetime rule leaks through it. `ArchiveSession` is the libarchive-backed
//  implementation; tests use it and, where useful, lightweight fakes.
//

import Foundation

// MARK: - Protocol

/// Read-only access to one open archive.
///
/// A conforming value is bound to a single archive: `open(url:)` scans it and
/// later calls extract from the same archive. The signatures deliberately match
/// the ones in the product brief so the UI has no excuse to touch libarchive.
public protocol ArchiveReading: Sendable {
    /// Scans the archive's metadata and returns the browsable document.
    func open(url: URL) async throws -> ArchiveDocument

    /// Extracts a single entry, preserving its path inside the archive.
    func extract(entry: ArchiveEntry, to destination: URL) async throws

    /// Extracts several entries (directories expand recursively).
    func extract(entries: [ArchiveEntry], to destination: URL) async throws

    /// Extracts only the given entry into the preview cache and returns the
    /// resulting file URL. Never extracts the whole archive.
    func materializeForPreview(entry: ArchiveEntry) async throws -> URL
}

// MARK: - Options

/// Knobs for scanning an archive.
public struct ArchiveOpenOptions: Sendable {
    /// How backslashes in stored paths are interpreted.
    public var separatorPolicy: ArchivePath.SeparatorPolicy
    /// Emit a progress event every N entries.
    public var progressInterval: Int
    /// Stop after N entries (used by tests and by "peek at the first entries").
    public var maxEntries: Int?
    /// libarchive read block size.
    public var blockSize: Int
    /// Extra libarchive options, e.g. `["zip:hdrcharset=UTF-8"]`.
    public var libarchiveOptions: [String]
    /// Wrap filesystem access in `startAccessingSecurityScopedResource`.
    public var usesSecurityScopedAccess: Bool
    /// Flag entries whose declared sizes look like a decompression bomb.
    public var detectSuspiciousSizes: Bool

    public init(
        separatorPolicy: ArchivePath.SeparatorPolicy = .automatic,
        progressInterval: Int = 512,
        maxEntries: Int? = nil,
        blockSize: Int = 128 * 1024,
        libarchiveOptions: [String] = [],
        usesSecurityScopedAccess: Bool = true,
        detectSuspiciousSizes: Bool = true
    ) {
        self.separatorPolicy = separatorPolicy
        self.progressInterval = progressInterval
        self.maxEntries = maxEntries
        self.blockSize = blockSize
        self.libarchiveOptions = libarchiveOptions
        self.usesSecurityScopedAccess = usesSecurityScopedAccess
        self.detectSuspiciousSizes = detectSuspiciousSizes
    }

    public static let `default` = ArchiveOpenOptions()
}

// MARK: - Progress and events

/// Progress of a metadata scan.
///
/// `estimatedTotalBytes` is the archive file's size, which is what makes a
/// percentage possible without reading the whole payload.
public struct ArchiveScanProgress: Sendable, Hashable {
    public let entriesScanned: Int
    public let bytesRead: Int64
    public let estimatedTotalBytes: Int64?
    public let currentPath: String?

    public init(entriesScanned: Int, bytesRead: Int64, estimatedTotalBytes: Int64?, currentPath: String?) {
        self.entriesScanned = entriesScanned
        self.bytesRead = bytesRead
        self.estimatedTotalBytes = estimatedTotalBytes
        self.currentPath = currentPath
    }

    /// `0...1` when a total is known.
    public var fractionCompleted: Double? {
        guard let estimatedTotalBytes, estimatedTotalBytes > 0 else { return nil }
        return max(0, min(1, Double(bytesRead) / Double(estimatedTotalBytes)))
    }
}

/// Events emitted while scanning.
///
/// The UI consumes this stream so a 100 000 entry tarball shows a live
/// progress indicator instead of a beachball.
public enum ArchiveScanEvent: Sendable {
    /// Emitted once the container has been identified.
    case detected(ArchiveFormatInfo)
    /// Emitted periodically while headers are read.
    case progress(ArchiveScanProgress)
    /// The finished document; always the last event on a successful scan.
    case finished(ArchiveDocument)
}

// MARK: - Security scoped access

/// RAII wrapper around `startAccessingSecurityScopedResource`.
///
/// The sandbox grants access to a URL obtained from the user (Open panel,
/// Finder open event, security-scoped bookmark). Every filesystem touch in the
/// engine is bracketed by this type so the access is always balanced, even when
/// an operation throws.
public final class SecurityScopedAccess: @unchecked Sendable {
    private let url: URL
    private var isActive: Bool

    public init(url: URL, enabled: Bool = true) {
        self.url = url
        if enabled, url.startAccessingSecurityScopedResource() {
            self.isActive = true
        } else {
            self.isActive = false
        }
    }

    public func end() {
        guard isActive else { return }
        isActive = false
        url.stopAccessingSecurityScopedResource()
    }

    deinit {
        if isActive {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
