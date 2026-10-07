//
//  ArchiveError.swift
//  ArchiveCore
//
//  Every failure surfaces as `ArchiveError` so the UI can present a
//  macOS-style message ("ArchiveCat couldn't read this archive…") while still
//  making the raw libarchive diagnostic available behind a disclosure.
//

import Foundation

/// Why a path inside an archive was rejected.
public enum PathSafetyViolation: String, Sendable, Codable, CaseIterable {
    /// `../../etc/passwd`
    case parentTraversal
    /// A path with a leading `/`, or a Windows drive/UNC path.
    case absolutePath
    /// A component that is empty or `.`.
    case ambiguousComponent
    /// Embedded NUL or other byte sequence that cannot be a macOS path.
    case invalidCharacters
    /// The normalized path became empty (e.g. the entry was named `..`).
    case emptyResult
    /// A component (or the whole path) is longer than macOS allows.
    case componentTooLong

    public var localizedDescription: String {
        switch self {
        case .parentTraversal:
            return "the entry tries to escape the archive root using “..”"
        case .absolutePath:
            return "the entry uses an absolute path"
        case .ambiguousComponent:
            return "the entry contains an ambiguous path component"
        case .invalidCharacters:
            return "the entry name contains characters that are not valid in a file name"
        case .emptyResult:
            return "the entry has no usable path"
        case .componentTooLong:
            return "the entry name is longer than the file system allows"
        }
    }
}

/// Errors thrown by the archive engine.
///
/// The wording is user-facing; `technicalDetails` carries the libarchive
/// message verbatim for the expandable "Details" section of the error sheet.
public enum ArchiveError: Error, Sendable, LocalizedError {
    /// The archive file could not be opened at all (missing, unreadable, sandbox denial).
    case cannotOpen(url: URL, reason: String, technicalDetails: String?)
    /// libarchive opened the file but did not recognise the container.
    case unsupportedFormat(url: URL, technicalDetails: String?)
    /// The container was recognised but is damaged.
    case corrupted(url: URL, entryPath: String?, technicalDetails: String?)
    /// The archive (or one entry) is encrypted. No password UI in v1.
    case encrypted(url: URL, entryPath: String?)
    /// A path inside the archive is malicious or unusable.
    case unsafePath(path: String, violation: PathSafetyViolation)
    /// Extraction of a single item failed.
    case extractionFailed(path: String, destination: URL, reason: String, technicalDetails: String?)
    /// The extraction destination could not be prepared.
    case destinationUnusable(url: URL, reason: String)
    /// A configured safety limit was reached.
    case limitExceeded(kind: ExtractionLimitKind, limit: Int64, observed: Int64)
    /// The user (or the system) cancelled the operation.
    case cancelled
    /// Preview could not be produced.
    case previewUnavailable(entryPath: String, reason: String)
    /// Anything else, wrapped so nothing escapes as a raw POSIX error.
    case underlying(reason: String, technicalDetails: String?)

    /// A short, headline sentence. Deliberately reads like a system alert.
    public var headline: String {
        switch self {
        case .cannotOpen:
            return "ArchiveCat couldn’t open this archive."
        case .unsupportedFormat:
            return "ArchiveCat doesn’t recognise this file format."
        case .corrupted:
            return "ArchiveCat couldn’t read this archive."
        case .encrypted:
            return "This archive is encrypted."
        case .unsafePath:
            return "This archive contains an unsafe path."
        case .extractionFailed:
            return "ArchiveCat couldn’t extract this item."
        case .destinationUnusable:
            return "ArchiveCat couldn’t write to the destination."
        case .limitExceeded:
            return "ArchiveCat stopped to protect your Mac."
        case .cancelled:
            return "The operation was cancelled."
        case .previewUnavailable:
            return "ArchiveCat couldn’t prepare a preview."
        case .underlying:
            return "ArchiveCat couldn’t complete the operation."
        }
    }

    /// Sentence explaining the likely cause with no jargon.
    public var explanation: String {
        switch self {
        case let .cannotOpen(url, reason, _):
            return "“\(url.lastPathComponent)” could not be opened. \(reason)"
        case .unsupportedFormat:
            return "The file may be damaged, or it may use a format or compression method that libarchive \(LibArchive.versionString) does not support."
        case let .corrupted(_, entryPath, _):
            if let entryPath {
                return "The data for “\(entryPath)” ended unexpectedly. The archive may be incomplete or damaged."
            }
            return "The archive ended unexpectedly. The file may be truncated or damaged."
        case let .encrypted(_, entryPath):
            if let entryPath {
                return "“\(entryPath)” is password protected. ArchiveCat \(ArchiveCatBuildInfo.version) can browse archive metadata but cannot decrypt entries."
            }
            return "The archive is password protected. ArchiveCat can browse archive metadata but cannot decrypt entries."
        case let .unsafePath(path, violation):
            return "The entry “\(path)” was rejected because \(violation.localizedDescription)."
        case let .extractionFailed(path, _, reason, _):
            return "“\(path)” was not extracted. \(reason)"
        case let .destinationUnusable(url, reason):
            return "The destination “\(url.lastPathComponent)” is not writable. \(reason)"
        case let .limitExceeded(kind, limit, observed):
            return "\(kind.localizedDescription) reached the configured limit of \(ArchiveCatFormat.byteCount(limit)) (observed \(ArchiveCatFormat.byteCount(observed)))."
        case .cancelled:
            return "The operation stopped before it finished."
        case let .previewUnavailable(entryPath, reason):
            return "“\(entryPath)” could not be prepared for Quick Look. \(reason)"
        case let .underlying(reason, _):
            return reason
        }
    }

    /// Expandable diagnostic string, or `nil` when there is nothing extra to say.
    public var technicalDetails: String? {
        switch self {
        case let .cannotOpen(_, _, details),
             let .unsupportedFormat(_, details),
             let .corrupted(_, _, details),
             let .extractionFailed(_, _, _, details),
             let .underlying(_, details):
            guard let details, !details.isEmpty else { return nil }
            return details
        case let .limitExceeded(kind, limit, observed):
            return "limit kind: \(kind.rawValue), limit: \(limit), observed: \(observed)"
        case .encrypted, .unsafePath, .destinationUnusable, .cancelled, .previewUnavailable:
            return nil
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .cannotOpen, .destinationUnusable:
            return "Check that the file still exists and that you have permission to read it."
        case .unsupportedFormat:
            return "Try opening it with a tool that supports this format, or verify that the download completed."
        case .corrupted:
            return "If the archive was downloaded, try downloading it again."
        case .encrypted:
            return "Export the entry with a tool that can prompt for the password."
        case .unsafePath:
            return "ArchiveCat refuses to write entries that would end up outside the extraction folder."
        case .extractionFailed:
            return "Check available disk space and free space in the destination folder."
        case .limitExceeded:
            return "You can raise the limits in ArchiveCat’s settings if you trust this archive."
        case .cancelled:
            return nil
        case .previewUnavailable:
            return "You can still extract the file and open it with another application."
        case .underlying:
            return nil
        }
    }

    /// True when the error merely reflects a cancellation the user asked for.
    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    // MARK: LocalizedError

    public var errorDescription: String? { headline }
    public var failureReason: String? { explanation }
}

/// Kinds of safety limit that can be enforced while extracting.
public enum ExtractionLimitKind: String, Sendable, Codable {
    case entries
    case totalUncompressedBytes
    case singleEntryBytes
    case compressionRatio

    public var localizedDescription: String {
        switch self {
        case .entries: return "The number of entries"
        case .totalUncompressedBytes: return "The total uncompressed size"
        case .singleEntryBytes: return "A single entry’s size"
        case .compressionRatio: return "The compression ratio"
        }
    }
}

/// Build-time identity of the library, used in diagnostics and the About panel.
public enum ArchiveCatBuildInfo {
    public static let version = "1.0"
    public static let bundleIdentifier = "com.frankruan.ArchiveCat"
}
