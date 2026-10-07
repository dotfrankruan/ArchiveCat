//
//  LibArchiveScanner.swift
//  ArchiveCore
//
//  Turns an archive into an `ArchiveDocument` by reading headers only.
//
//  This is the only place besides `ExtractionService` that drives libarchive
//  directly. It runs on a background task; it never touches the main thread and
//  never reads entry payloads (it *skips* them, which for seekable containers
//  is a seek and for compressed ones is a stream-through).
//

import CArchive
import Foundation

enum LibArchiveScanner {

    /// Scans `url` and returns the finished document, emitting progress along
    /// the way. Blocking; call from a background task.
    static func scan(
        url: URL,
        options: ArchiveOpenOptions,
        emit: @Sendable (ArchiveScanEvent) -> Void
    ) throws -> ArchiveDocument {
        let started = Date()
        let access = SecurityScopedAccess(url: url, enabled: options.usesSecurityScopedAccess)
        defer { access.end() }

        let fileSize = archiveFileSize(at: url)

        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            throw ArchiveError.cannotOpen(
                url: url,
                reason: "The file could not be read. It may have been moved, or ArchiveCat may not have permission to open it.",
                technicalDetails: nil
            )
        }

        let stream: LibArchiveReadStream
        do {
            stream = try LibArchiveReadStream()
        } catch let failure as LibArchiveFailure {
            throw ArchiveError.cannotOpen(url: url, reason: "libarchive could not be initialised.", technicalDetails: failure.diagnostic)
        }
        defer { stream.free() }

        do {
            try stream.enableAutoDetection()
            try stream.apply(options: options.libarchiveOptions)
            try stream.open(path: url.path(percentEncoded: false), blockSize: options.blockSize)
        } catch let failure as LibArchiveFailure {
            throw Self.openError(url: url, failure: failure)
        }

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(4096)

        var format: ArchiveFormatInfo?
        var ordinal = 0
        var lossyFilenameCount = 0
        var declaredSizesMissing = false
        var largestDeclaredSize: Int64 = 0
        var lastProgressEmission = Date.distantPast

        while true {
            try Task.checkCancellation()

            let hasHeader: Bool
            do {
                hasHeader = try stream.nextHeader()
            } catch let failure as LibArchiveFailure {
                // A failure before any entry means "this is not an archive we
                // understand"; after that it means the stream is damaged.
                if ordinal == 0 {
                    throw Self.openError(url: url, failure: failure)
                }
                throw ArchiveError.corrupted(
                    url: url,
                    entryPath: entries.last?.path,
                    technicalDetails: failure.diagnostic
                )
            }

            if !hasHeader { break }

            if format == nil {
                let detected = makeFormatInfo(from: stream)
                format = detected
                emit(.detected(detected))
            }

            guard let snapshot = stream.snapshotCurrentEntry() else { break }

            if !snapshot.pathWasValidUTF8 { lossyFilenameCount += 1 }

            let entry = makeEntry(
                snapshot: snapshot,
                ordinal: ordinal,
                options: options,
                format: format
            )
            entries.append(entry)
            ordinal += 1

            if let size = entry.uncompressedSize {
                largestDeclaredSize = max(largestDeclaredSize, size)
            } else if !entry.isDirectory {
                declaredSizesMissing = true
            }

            // Skip the payload without reading it.
            do {
                try stream.skipCurrentEntryData()
            } catch let failure as LibArchiveFailure {
                throw ArchiveError.corrupted(
                    url: url,
                    entryPath: entry.path,
                    technicalDetails: failure.diagnostic
                )
            }

            let now = Date()
            let isInterval = ordinal % max(1, options.progressInterval) == 0
            if isInterval || now.timeIntervalSince(lastProgressEmission) > 0.2 {
                lastProgressEmission = now
                emit(.progress(ArchiveScanProgress(
                    entriesScanned: ordinal,
                    bytesRead: stream.consumedBytes,
                    estimatedTotalBytes: fileSize,
                    currentPath: entry.path
                )))
            }

            if let maxEntries = options.maxEntries, ordinal >= maxEntries { break }
        }

        guard let format else {
            // libarchive parsed zero headers: an empty file or an empty tar.
            throw ArchiveError.unsupportedFormat(
                url: url,
                technicalDetails: "libarchive found no archive headers in this file."
            )
        }

        let tree = ArchiveTreeBuilder.build(entries: entries)
        let summary = ArchiveSummary(
            fileName: url.lastPathComponent,
            format: format,
            entries: entries,
            tree: tree,
            archiveFileSize: fileSize,
            consumedCompressedBytes: stream.consumedBytes
        )
        let warnings = makeWarnings(
            summary: summary,
            lossyFilenameCount: lossyFilenameCount,
            declaredSizesMissing: declaredSizesMissing,
            largestDeclaredSize: largestDeclaredSize,
            format: format,
            options: options
        )

        return ArchiveDocument(
            url: url,
            identity: ArchiveIdentity.capture(url),
            entries: entries,
            tree: tree,
            summary: summary,
            format: format,
            warnings: warnings,
            scanDuration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Entry construction

    static func makeEntry(
        snapshot: LibArchiveEntrySnapshot,
        ordinal: Int,
        options: ArchiveOpenOptions,
        format: ArchiveFormatInfo?
    ) -> ArchiveEntry {
        let normalized = ArchivePath.normalize(
            rawPath: snapshot.rawPath,
            separatorPolicy: options.separatorPolicy
        )

        var type = entryType(for: snapshot.fileType, hardlinkTarget: snapshot.hardlinkTarget)
        // Some tar writers mark directories as zero-length regular files with a
        // trailing slash instead of setting the directory type flag.
        if type == .regularFile, normalized.hadTrailingSeparator, snapshot.size == 0 {
            type = .directory
        }

        let isDirectory = type == .directory
        let uncompressedSize: Int64? = isDirectory ? nil : (snapshot.sizeIsSet ? max(0, snapshot.size) : nil)

        // libarchive does not expose a per-entry compressed size, so it is only
        // reported for containers that store members uncompressed (tar, cpio).
        var compressedSize: Int64?
        var compressedSizeIsEstimated = false
        if let uncompressedSize,
           let format,
           format.isUncompressed,
           !formatCompressesMembers(format.formatCode) {
            compressedSize = uncompressedSize
            compressedSizeIsEstimated = true
        }

        let posixMode: UInt16? = snapshot.mode == 0 ? nil : UInt16(snapshot.mode & 0o7777)

        return ArchiveEntry(
            id: ArchiveEntryID(ordinal: ordinal, path: normalized.normalized),
            ordinal: ordinal,
            rawPath: snapshot.rawPath,
            path: normalized.normalized,
            name: normalized.name,
            parentPath: normalized.parentPath,
            type: type,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            compressedSizeIsEstimated: compressedSizeIsEstimated,
            modificationDate: snapshot.modificationDate,
            posixMode: posixMode,
            uid: snapshot.uidIsSet ? UInt32(clamping: snapshot.uid) : nil,
            gid: snapshot.gidIsSet ? UInt32(clamping: snapshot.gid) : nil,
            linkCount: snapshot.linkCount == 0 ? nil : snapshot.linkCount,
            symlinkTarget: snapshot.symlinkTarget,
            hardlinkTarget: snapshot.hardlinkTarget,
            crc32: nil,
            deviceMajor: snapshot.deviceMajor,
            deviceMinor: snapshot.deviceMinor,
            safety: normalized.safety,
            formatDetail: nil
        )
    }

    /// Maps libarchive's file-type bits onto `EntryType`.
    static func entryType(for fileType: mode_t, hardlinkTarget: String?) -> EntryType {
        // A hard link carries a regular-file type plus a hardlink target.
        if hardlinkTarget != nil { return .hardLink }

        switch POSIXFileType.of(mode: fileType) {
        case POSIXFileType.regular: return .regularFile
        case POSIXFileType.directory: return .directory
        case POSIXFileType.symbolicLink: return .symbolicLink
        case POSIXFileType.fifo: return .fifo
        case POSIXFileType.socket: return .socket
        case POSIXFileType.characterDevice: return .characterDevice
        case POSIXFileType.blockDevice: return .blockDevice
        default: return .unknown
        }
    }

    // MARK: - Format info

    static func makeFormatInfo(from stream: LibArchiveReadStream) -> ArchiveFormatInfo {
        let filterCode = stream.filterCode
        return ArchiveFormatInfo(
            formatCode: stream.formatCode,
            formatName: stream.formatName,
            filterCode: filterCode,
            compressionName: stream.filterName,
            hasEncryptedEntries: stream.hasEncryptedEntries,
            isUncompressed: filterCode == ARCHIVE_FILTER_NONE
        )
    }

    /// Formats whose members are individually compressed. For these, a member's
    /// stored size is not its uncompressed size, so no compressed size can be
    /// reported without lying.
    static func formatCompressesMembers(_ formatCode: Int32) -> Bool {
        switch formatCode & ARCHIVE_FORMAT_BASE_MASK {
        case ARCHIVE_FORMAT_ZIP, ARCHIVE_FORMAT_7ZIP, ARCHIVE_FORMAT_RAR, ARCHIVE_FORMAT_XAR:
            return true
        default:
            return false
        }
    }

    // MARK: - Warnings

    static func makeWarnings(
        summary: ArchiveSummary,
        lossyFilenameCount: Int,
        declaredSizesMissing: Bool,
        largestDeclaredSize: Int64,
        format: ArchiveFormatInfo,
        options: ArchiveOpenOptions
    ) -> [ArchiveWarning] {
        var warnings: [ArchiveWarning] = []

        if summary.unsafeEntryCount > 0 {
            warnings.append(ArchiveWarning(
                kind: .unsafeEntries,
                message: summary.unsafeEntryCount == 1
                    ? "1 entry was excluded because its path points outside the archive. It cannot be browsed or extracted."
                    : "\(summary.unsafeEntryCount) entries were excluded because their paths point outside the archive. They cannot be browsed or extracted.",
                count: summary.unsafeEntryCount
            ))
        }

        if summary.conflictingPathCount > 0 {
            warnings.append(ArchiveWarning(
                kind: .pathConflicts,
                message: "\(summary.conflictingPathCount) entries share a path with a folder in this archive.",
                count: summary.conflictingPathCount
            ))
        }

        if lossyFilenameCount > 0 {
            warnings.append(ArchiveWarning(
                kind: .lossyFilename,
                message: lossyFilenameCount == 1
                    ? "1 file name is not valid UTF-8 and has been repaired for display."
                    : "\(lossyFilenameCount) file names are not valid UTF-8 and have been repaired for display.",
                count: lossyFilenameCount
            ))
        }

        if format.hasEncryptedEntries == true {
            warnings.append(ArchiveWarning(
                kind: .encryptedEntries,
                message: "Some entries are encrypted. ArchiveCat can list them but cannot decrypt them.",
                count: summary.entryCount
            ))
        }

        if options.detectSuspiciousSizes {
            if let ratio = summary.compressionRatio, ratio > 0.999,
               summary.totalUncompressedSize > 8 * 1024 * 1024 * 1024 {
                warnings.append(ArchiveWarning(
                    kind: .suspiciousSize,
                    message: "This archive expands to more than \(ArchiveCatFormat.byteCount(summary.totalUncompressedSize)) from \(ArchiveCatFormat.byteCount(summary.comparableCompressedSize ?? 0)). Check that you trust it before extracting everything.",
                    count: summary.entryCount
                ))
            } else if largestDeclaredSize > 64 * 1024 * 1024 * 1024 {
                warnings.append(ArchiveWarning(
                    kind: .suspiciousSize,
                    message: "One entry declares a size of \(ArchiveCatFormat.byteCount(largestDeclaredSize)).",
                    count: 1
                ))
            }
        }

        if declaredSizesMissing {
            warnings.append(ArchiveWarning(
                kind: .incompleteMetadata,
                message: "Some entries do not record their size, so the total below is a lower bound.",
                count: summary.entryCount
            ))
        }

        return warnings
    }

    // MARK: - Errors

    /// Maps a libarchive open/read failure onto a user-facing `ArchiveError`.
    static func openError(url: URL, failure: LibArchiveFailure) -> ArchiveError {
        let message = failure.message.lowercased()

        if failure.errorNumber == EACCES || message.contains("permission") {
            return ArchiveError.cannotOpen(
                url: url,
                reason: "ArchiveCat does not have permission to read this file.",
                technicalDetails: failure.diagnostic
            )
        }
        if failure.errorNumber == ENOENT {
            return ArchiveError.cannotOpen(
                url: url,
                reason: "The file no longer exists at that location.",
                technicalDetails: failure.diagnostic
            )
        }
        if message.contains("password") || message.contains("encrypted") {
            return ArchiveError.encrypted(url: url, entryPath: nil)
        }
        if message.contains("unrecognized") || message.contains("format") || message.contains("truncated") {
            return ArchiveError.unsupportedFormat(url: url, technicalDetails: failure.diagnostic)
        }
        return ArchiveError.cannotOpen(
            url: url,
            reason: "The file could not be opened as an archive.",
            technicalDetails: failure.diagnostic
        )
    }

    private static func archiveFileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}
