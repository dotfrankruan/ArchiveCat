//
//  ExtractionConflict.swift
//  ArchiveCore
//
//  Destination collisions, and the decision the user makes about them.
//
//  The engine never decides for itself what to do when the destination already
//  holds an item: it describes the collision and asks. The UI answers with one
//  `ExtractionConflictResolution`, and the writer executes that answer with the
//  same `openat`-based, no-follow traversal it uses for everything else.
//
//  This keeps AppKit out of the engine and keeps "never overwrite silently" a
//  property of the architecture rather than of the presenter.
//

import Foundation

// MARK: - Resolution

/// What to do about one collision between an entry and the destination.
///
/// This is the API the UI answers with; the engine maps it onto a concrete
/// writer action. `cancel` never reaches the writer — it stops the operation.
public enum ExtractionConflictResolution: String, Sendable, CaseIterable, Codable {
    /// Replace the existing item with the extracted one.
    case replace
    /// Leave the existing item untouched and do not extract this entry.
    case skip
    /// Write alongside the existing item using Finder's "name 2.ext" naming.
    case keepBoth
    /// Stop the whole extraction. Items already written are kept.
    case cancel

    public var localizedName: String {
        switch self {
        case .replace: return "Replace"
        case .skip: return "Skip"
        case .keepBoth: return "Keep Both"
        case .cancel: return "Cancel"
        }
    }

    /// One-line explanation, used by the conflict sheet.
    public var explanation: String {
        switch self {
        case .replace: return "Replace the existing item with the one from the archive."
        case .skip: return "Keep the existing item and skip this entry."
        case .keepBoth: return "Keep both, giving the extracted item a new name."
        case .cancel: return "Stop extracting. Items already extracted are kept."
        }
    }

    /// True when the choice destroys something already on disk. The UI uses
    /// this to warn, and to avoid making it the default button.
    public var isDestructive: Bool {
        self == .replace
    }
}

// MARK: - Conflict

/// A collision between an entry being extracted and the destination.
public struct ExtractionConflict: Sendable, Identifiable {
    /// The entry the archive wants to write.
    public let entry: ArchiveEntry
    /// Path relative to the extraction root, as it will be written.
    public let relativePath: String
    /// The destination root the user chose.
    public let destination: URL
    /// True when the destination holds a *folder* at this path.
    ///
    /// Folder collisions are not put to the user as a Replace/Keep Both
    /// question: ArchiveCat never deletes a folder to make way for a file, so
    /// the only meaningful answers are handled by the writer.
    public let existingIsDirectory: Bool

    public var id: ArchiveEntryID { entry.id }

    /// Full URL of the item already on disk.
    public var existingURL: URL {
        destination.appendingPathComponent(relativePath)
    }

    public init(entry: ArchiveEntry, relativePath: String, destination: URL, existingIsDirectory: Bool) {
        self.entry = entry
        self.relativePath = relativePath
        self.destination = destination
        self.existingIsDirectory = existingIsDirectory
    }
}

/// Asked once per collision.
///
/// Asynchronous on purpose: the UI's implementation presents a sheet and
/// suspends until the user answers, which a synchronous callback could not do
/// without blocking the main thread.
public typealias ExtractionConflictResolver = @Sendable (ExtractionConflict) async -> ExtractionConflictResolution

// MARK: - Internal action

/// The concrete thing the writer does about a collision.
///
/// `ExtractionConflictPolicy` and `ExtractionConflictResolution` both collapse
/// onto this, so `SecureDestination` has exactly one branch per outcome and no
/// knowledge of who decided.
enum ConflictAction: Sendable {
    /// Create or truncate the file at the requested path.
    case replace
    /// Do nothing at all for this entry.
    case skip
    /// Find an unused "name 2.ext" alongside it.
    case keepBoth

    /// The action implied by a policy that was decided before extraction began.
    init(policy: ExtractionConflictPolicy) {
        switch policy {
        case .replace:
            self = .replace
        case .skip:
            self = .skip
        case .keepBoth:
            self = .keepBoth
        case .ask:
            // `.ask` means "a resolver will answer". If one was not installed,
            // fall back to the only non-destructive option rather than
            // inventing a delete.
            self = .keepBoth
        }
    }

    /// The action implied by a live decision. `.cancel` is handled by the
    /// service before it ever reaches the writer.
    init(resolution: ExtractionConflictResolution) {
        switch resolution {
        case .replace: self = .replace
        case .skip: self = .skip
        case .keepBoth: self = .keepBoth
        case .cancel: self = .skip
        }
    }
}
