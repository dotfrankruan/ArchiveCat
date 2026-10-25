//
//  ArchiveCapabilities.swift
//  ArchiveCore
//
//  What the engine can actually do with a format or an open archive.
//
//  Why one type instead of asking questions at each call site
//  -----------------------------------------------------------
//  The browser has to decide whether to offer "Open Archive Inside", whether
//  the compression level control makes sense, and whether a member can be
//  reached without decompressing everything before it. Answering those with
//  `formatCode == …` checks scattered across view controllers is how format
//  knowledge rots. Everything here is derived once, from libarchive's own
//  format and filter codes (for reading) or from the writer's own probe (for
//  creation).
//
//  Two rules are structural, not cosmetic:
//
//   * Reading capability never implies creation capability. The catalogue of
//     creatable formats is explicit and probed against the linked libarchive.
//   * There is no modification capability. ArchiveCat never edits an archive;
//     that is a permanent product decision, so no flag exists to suggest
//     otherwise.
//

import Foundation

// MARK: - Capabilities

/// What a session or a format can do.
///
/// Every value describes the *engine's* behaviour, not what the container format
/// theoretically allows. For example `supportsEncryptedInput` is `false` even
/// for ZIP, because ArchiveCat has no password UI and cannot decrypt members.
public struct ArchiveCapabilities: Sendable, Hashable {

    /// The engine can enumerate and open this archive.
    public let canRead: Bool
    /// The engine can stream members out to a destination.
    public let canExtract: Bool
    /// The engine can produce this format from scratch.
    public let canCreate: Bool
    /// Members can be read as a stream (always true; kept explicit so callers
    /// do not have to assume).
    public let supportsStreamingReads: Bool
    /// A member can be reached without decompressing every preceding member.
    public let supportsRandomAccess: Bool
    /// Encrypted members can be decrypted.
    public let supportsEncryptedInput: Bool
    /// POSIX metadata (mode, ownership, timestamps, links) survives a round trip.
    public let supportsMetadataPreservation: Bool
    /// A compression level can be chosen.
    public let supportsCompressionLevel: Bool
    /// Archives of this kind can be opened from inside another archive.
    public let supportsNestedArchives: Bool

    /// One sentence explaining the most important limitation, if there is one.
    public let limitation: String?

    public init(
        canRead: Bool,
        canExtract: Bool,
        canCreate: Bool,
        supportsStreamingReads: Bool,
        supportsRandomAccess: Bool,
        supportsEncryptedInput: Bool,
        supportsMetadataPreservation: Bool,
        supportsCompressionLevel: Bool,
        supportsNestedArchives: Bool,
        limitation: String? = nil
    ) {
        self.canRead = canRead
        self.canExtract = canExtract
        self.canCreate = canCreate
        self.supportsStreamingReads = supportsStreamingReads
        self.supportsRandomAccess = supportsRandomAccess
        self.supportsEncryptedInput = supportsEncryptedInput
        self.supportsMetadataPreservation = supportsMetadataPreservation
        self.supportsCompressionLevel = supportsCompressionLevel
        self.supportsNestedArchives = supportsNestedArchives
        self.limitation = limitation
    }

    // MARK: Reading

    /// Capabilities of an opened archive, from its detected format.
    ///
    /// `supportsRandomAccess` needs both a member index *and* the absence of a
    /// sequential outer filter: `project.tar.gz` is a tar container inside a
    /// gzip stream, so reaching its last member still means decompressing
    /// everything before it.
    public static func reading(format: ArchiveFormatInfo) -> ArchiveCapabilities {
        let container = ArchiveContainerKind(formatCode: format.formatCode)

        let isSequentialStream = !format.isUncompressed
        let randomAccess = container.hasMemberIndex && !isSequentialStream

        var limitation: String?
        if format.hasEncryptedEntries == true {
            limitation = "This archive contains encrypted entries. ArchiveCat can list them but cannot decrypt them."
        } else if isSequentialStream {
            limitation = "This archive is a compressed stream, so an individual member is reached by decompressing everything before it."
        }

        return ArchiveCapabilities(
            canRead: true,
            canExtract: true,
            canCreate: false,
            supportsStreamingReads: true,
            supportsRandomAccess: randomAccess,
            // No password UI exists, so encrypted input is never readable.
            supportsEncryptedInput: false,
            supportsMetadataPreservation: container.preservesPOSIXMetadata,
            supportsCompressionLevel: false,
            supportsNestedArchives: true,
            limitation: limitation
        )
    }

    /// A format the engine cannot read at all.
    public static let unreadable = ArchiveCapabilities(
        canRead: false,
        canExtract: false,
        canCreate: false,
        supportsStreamingReads: false,
        supportsRandomAccess: false,
        supportsEncryptedInput: false,
        supportsMetadataPreservation: false,
        supportsCompressionLevel: false,
        supportsNestedArchives: false,
        limitation: "The engine does not recognise this format."
    )
}
