//
//  CompressionService.swift
//  ArchiveCore
//
//  Creates a new archive from files and directories.
//
//  This is the ArchiveCreator half of the app and it is deliberately independent
//  of the ArchiveReader: it opens ordinary files, never an existing archive for
//  modification, and it has no notion of a "session".
//
//  Guarantees
//  ----------
//  1. Nothing is written to the destination path until the archive is complete.
//     Output goes to a unique sibling temporary file and is moved into place
//     atomically; a failure or cancellation removes the temporary file and
//     leaves the destination exactly as it was.
//  2. An existing destination is never replaced unless the caller explicitly
//     allowed it (which the UI only does after the user confirms in the save
//     panel). The no-clobber path uses an atomic `renameatx_np(RENAME_EXCL)`,
//     so even a race cannot overwrite a file by accident.
//  3. Every item is planned, validated and sized before writing starts, so a
//     missing or unreadable source fails in the first second, not the last.
//  4. Payloads are streamed in fixed blocks: memory does not scale with file
//     size, and cancellation is checked between blocks.
//  5. A file that shrinks mid-run aborts the operation rather than producing an
//     archive with a corrupt member.
//

import Darwin
import Foundation

// MARK: - Options

/// Safety bounds for one compression run.
public struct CompressionLimits: Sendable, Hashable {
    public var maximumItemCount: Int?
    public var maximumTotalBytes: Int64?
    public var maximumSingleFileBytes: Int64?

    public init(
        maximumItemCount: Int? = 2_000_000,
        maximumTotalBytes: Int64? = nil,
        maximumSingleFileBytes: Int64? = nil
    ) {
        self.maximumItemCount = maximumItemCount
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumSingleFileBytes = maximumSingleFileBytes
    }

    public static let `default` = CompressionLimits()
}

/// Everything the compression service needs.
public struct CompressionOptions: Sendable {
    /// `ArchiveFormatDescriptor.id`, e.g. `zip` or `tar.gz`.
    public var formatID: String
    /// Requested level; clamped to the format's supported range.
    public var compressionLevel: Int?
    /// Replace an existing destination file. The UI sets this only after the
    /// user confirmed replacement.
    public var overwriteExisting: Bool
    /// Fail early when the source bytes clearly do not fit on the destination
    /// volume. Off by default because compression may shrink the payload; the
    /// writer reports a real ENOSPC if it runs out of room.
    public var checkAvailableSpace: Bool
    public var limits: CompressionLimits

    public init(
        formatID: String = "zip",
        compressionLevel: Int? = nil,
        overwriteExisting: Bool = false,
        checkAvailableSpace: Bool = false,
        limits: CompressionLimits = .default
    ) {
        self.formatID = formatID
        self.compressionLevel = compressionLevel
        self.overwriteExisting = overwriteExisting
        self.checkAvailableSpace = checkAvailableSpace
        self.limits = limits
    }

    public static let `default` = CompressionOptions()
}

// MARK: - Progress and result

public struct CompressionProgress: Sendable, Hashable {
    public let completedItems: Int
    public let totalItems: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let currentPath: String?

    public init(
        completedItems: Int,
        totalItems: Int,
        completedBytes: Int64,
        totalBytes: Int64,
        currentPath: String?
    ) {
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentPath = currentPath
    }

    public var fractionCompleted: Double? {
        if totalBytes > 0 {
            return max(0, min(1, Double(completedBytes) / Double(totalBytes)))
        }
        guard totalItems > 0 else { return nil }
        return max(0, min(1, Double(completedItems) / Double(totalItems)))
    }
}

public struct CompressionResult: Sendable {
    public let destination: URL
    public let formatID: String
    public let formatDisplayName: String
    public let itemCount: Int
    public let fileCount: Int
    public let directoryCount: Int
    public let symlinkCount: Int
    /// Bytes read from the sources.
    public let sourceBytes: Int64
    /// Bytes of the finished archive.
    public let archiveBytes: Int64
    public let duration: TimeInterval
    public let warnings: [String]

    public init(
        destination: URL,
        formatID: String,
        formatDisplayName: String,
        itemCount: Int,
        fileCount: Int,
        directoryCount: Int,
        symlinkCount: Int,
        sourceBytes: Int64,
        archiveBytes: Int64,
        duration: TimeInterval,
        warnings: [String]
    ) {
        self.destination = destination
        self.formatID = formatID
        self.formatDisplayName = formatDisplayName
        self.itemCount = itemCount
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.symlinkCount = symlinkCount
        self.sourceBytes = sourceBytes
        self.archiveBytes = archiveBytes
        self.duration = duration
        self.warnings = warnings
    }

    /// Fraction of source bytes the archive saved, in `0...1`, when meaningful.
    public var compressionRatio: Double? {
        guard sourceBytes > 0 else { return nil }
        return max(0, min(1, 1 - (Double(archiveBytes) / Double(sourceBytes))))
    }
}

// MARK: - Service

public struct CompressionService: Sendable {

    public init() {}

    /// Creates an archive at `destination` from `sources`.
    ///
    /// Runs entirely off the caller's executor; `progress` is invoked from that
    /// background context and must hop to the main actor itself.
    public func compress(
        sources: [URL],
        to destination: URL,
        options: CompressionOptions = .default,
        progress: (@Sendable (CompressionProgress) -> Void)? = nil
    ) async throws -> CompressionResult {
        let options = options
        // `Task.detached` does not inherit cancellation, so it is propagated
        // explicitly: cancelling the caller cancels the writer, which aborts and
        // removes its temporary file.
        let task = Task.detached(priority: .userInitiated) {
            try Self.run(sources: sources, destination: destination, options: options, progress: progress)
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw ArchiveError.cancelled
        }
    }

    // MARK: - Implementation

    private static func run(
        sources: [URL],
        destination: URL,
        options: CompressionOptions,
        progress: (@Sendable (CompressionProgress) -> Void)?
    ) throws -> CompressionResult {
        let started = Date()

        guard let format = ArchiveFormatCatalog.creatableFormat(withID: options.formatID) else {
            let available = ArchiveFormatCatalog.creatableFormats.map(\.displayName).joined(separator: ", ")
            throw ArchiveError.compressionFailed(
                destination: destination,
                reason: "The “\(options.formatID)” format cannot be created by this build.",
                technicalDetails: "Formats available: \(available.isEmpty ? "none" : available)."
            )
        }

        let plan: CompressionPlan
        do {
            plan = try CompressionPlanner.plan(sources: sources, options: options)
        } catch let error as CompressionPlanningError {
            throw mapPlanningError(error, destination: destination)
        }

        try validateDestination(destination, overwriteExisting: options.overwriteExisting)

        let parent = destination.deletingLastPathComponent()
        let parentPath = parent.path(percentEncoded: false)
        let destinationPath = destination.path(percentEncoded: false)

        // Access grants for whatever the panels handed us.
        var scopes: [SecurityScopedAccess] = sources.map { SecurityScopedAccess(url: $0, enabled: true) }
        scopes.append(SecurityScopedAccess(url: parent, enabled: true))
        defer { scopes.forEach { $0.end() } }

        if options.checkAvailableSpace,
           let available = ExtractionPreflight.availableSpace(at: parent),
           available < plan.totalBytes {
            throw ArchiveError.notEnoughSpace(
                destination: destination,
                required: plan.totalBytes,
                available: available
            )
        }

        // Unique sibling temporary file: same directory, so the final move is an
        // atomic rename rather than a cross-volume copy.
        let templName = ".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).partial"
        let tempPath = parent.appendingPathComponent(templName).path(percentEncoded: false)
        var committed = false
        defer {
            if !committed {
                tempPath.withCString { _ = unlink($0) }
            }
        }

        if tempPath.withCString({ access($0, F_OK) }) == 0 {
            throw ArchiveError.compressionFailed(
                destination: destination,
                reason: "A temporary file with the same name already exists.",
                technicalDetails: tempPath
            )
        }

        let level = resolvedCompressionLevel(options: options, format: format)
        let writer = try LibArchiveWriter(format: format, compressionLevel: level)
        defer { writer.abort() }

        do {
            try writer.openOutput(path: tempPath)
        } catch let failure as LibArchiveWriterFailure {
            throw ArchiveError.compressionFailed(
                destination: destination,
                reason: "The archive could not be started. \(failure.message)",
                technicalDetails: failure.description
            )
        }

        var completedItems = 0
        var completedBytes: Int64 = 0
        var lastReportedBytes: Int64 = -1

        func reportProgress(currentPath: String?, force: Bool) {
            guard let progress else { return }
            let shouldReport = force || completedBytes - lastReportedBytes >= 1_000_000
            guard shouldReport else { return }
            lastReportedBytes = completedBytes
            progress(CompressionProgress(
                completedItems: completedItems,
                totalItems: plan.items.count,
                completedBytes: completedBytes,
                totalBytes: plan.totalBytes,
                currentPath: currentPath
            ))
        }

        reportProgress(currentPath: nil, force: true)

        for item in plan.items {
            if Task.isCancelled { throw ArchiveError.cancelled }
            reportProgress(currentPath: item.archivePath, force: false)

            let entry = ArchiveWriteEntry(
                path: item.archivePath,
                content: writeContent(for: item.content),
                modificationDate: item.modificationDate,
                posixMode: item.posixMode,
                uid: item.uid,
                gid: item.gid
            )

            do {
                try writer.write(entry) { byteCount in
                    completedBytes += Int64(byteCount)
                    reportProgress(currentPath: item.archivePath, force: false)
                }
            } catch let failure as LibArchiveWriterFailure {
                throw ArchiveError.compressionFailed(
                    destination: destination,
                    reason: "“\(item.archivePath)” could not be added. \(failure.message)",
                    technicalDetails: failure.description
                )
            }

            completedItems += 1
            reportProgress(currentPath: item.archivePath, force: true)
        }

        // Finalise: the format trailer is written here, and a failure to flush
        // is a failure of the whole archive.
        do {
            try writer.finish()
        } catch let failure as LibArchiveWriterFailure {
            throw ArchiveError.compressionFailed(
                destination: destination,
                reason: "The archive could not be completed. \(failure.message)",
                technicalDetails: failure.description
            )
        }

        // Make the contents durable before publishing the name.
        let descriptor = tempPath.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        if descriptor >= 0 {
            fsync(descriptor)
            close(descriptor)
        }

        var archiveBytes: Int64 = 0
        var info = stat()
        if tempPath.withCString({ lstat($0, &info) }) == 0 {
            archiveBytes = Int64(info.st_size)
        }
        guard archiveBytes > 0 else {
            throw ArchiveError.compressionFailed(
                destination: destination,
                reason: "The archive came out empty and was discarded.",
                technicalDetails: "The temporary file at \(tempPath) had zero length."
            )
        }

        try commit(
            tempPath: tempPath,
            destination: destination,
            destinationPath: destinationPath,
            overwriteExisting: options.overwriteExisting,
            parentPath: parentPath
        )
        committed = true

        let result = CompressionResult(
            destination: destination,
            formatID: format.id,
            formatDisplayName: format.displayName,
            itemCount: plan.items.count,
            fileCount: plan.fileCount,
            directoryCount: plan.directoryCount,
            symlinkCount: plan.symlinkCount,
            sourceBytes: plan.totalBytes,
            archiveBytes: archiveBytes,
            duration: Date().timeIntervalSince(started),
            warnings: plan.warnings
        )

        ArchiveCatLog.extraction.debug(
            "created \(format.id, privacy: .public) with \(plan.items.count, privacy: .public) items in \(result.duration, privacy: .public)s"
        )
        return result
    }

    // MARK: - Helpers

    private static func writeContent(for content: CompressionPlan.Item.Content) -> ArchiveWriteEntry.Content {
        switch content {
        case let .file(sourcePath, _): return .file(sourcePath: sourcePath)
        case .directory: return .directory
        case let .symbolicLink(target): return .symbolicLink(target: target)
        }
    }

    private static func resolvedCompressionLevel(
        options: CompressionOptions,
        format: ArchiveFormatDescriptor
    ) -> Int? {
        guard let range = format.compressionLevelRange else { return nil }
        let requested = options.compressionLevel ?? format.defaultCompressionLevel ?? range.lowerBound
        return min(max(requested, range.lowerBound), range.upperBound)
    }

    private static func validateDestination(_ destination: URL, overwriteExisting: Bool) throws {
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw ArchiveError.destinationUnusable(url: destination, reason: "The file name is not usable.")
        }

        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        let parentPath = parent.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: parentPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArchiveError.destinationUnusable(url: parent, reason: "The destination folder does not exist.")
        }

        var info = stat()
        let destinationPath = destination.path(percentEncoded: false)
        let exists = destinationPath.withCString { lstat($0, &info) } == 0
        guard exists else { return }

        guard overwriteExisting else {
            throw ArchiveError.destinationExists(url: destination)
        }
        // Replacing a directory would destroy data we can never put back, and
        // replacing a symlink would surprise the user by writing somewhere else.
        guard POSIXFileType.isRegular(info.st_mode) else {
            throw ArchiveError.destinationUnusable(
                url: destination,
                reason: "Only a regular file can be replaced."
            )
        }
    }

    private static func commit(
        tempPath: String,
        destination: URL,
        destinationPath: String,
        overwriteExisting: Bool,
        parentPath: String
    ) throws {
        if overwriteExisting {
            let result = tempPath.withCString { from in
                destinationPath.withCString { to in
                    rename(from, to)
                }
            }
            guard result == 0 else {
                let errorNumber = errno
                throw ArchiveError.compressionFailed(
                    destination: destination,
                    reason: "The finished archive could not be moved into place.",
                    technicalDetails: "rename(2) failed: \(String(cString: strerror(errorNumber)))"
                )
            }
            return
        }

        // Atomic no-clobber: fails with EEXIST instead of replacing a file that
        // appeared after validation.
        let result = tempPath.withCString { from in
            destinationPath.withCString { to in
                renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let errorNumber = errno
            if errorNumber == EEXIST {
                throw ArchiveError.destinationExists(url: destination)
            }
            throw ArchiveError.compressionFailed(
                destination: destination,
                reason: "The finished archive could not be moved into place.",
                technicalDetails: "renameatx_np(RENAME_EXCL) in \(parentPath) failed: \(String(cString: strerror(errorNumber)))"
            )
        }
    }

    private static func mapPlanningError(
        _ error: CompressionPlanningError,
        destination: URL
    ) -> ArchiveError {
        switch error {
        case let .tooManyItems(limit, observed):
            return .limitExceeded(kind: .entries, limit: Int64(limit), observed: Int64(observed))
        case let .totalTooLarge(limit, observed):
            return .limitExceeded(kind: .totalUncompressedBytes, limit: limit, observed: observed)
        case let .singleFileTooLarge(_, limit, observed):
            return .limitExceeded(kind: .singleEntryBytes, limit: limit, observed: observed)
        case let .hierarchicalDepthExceeded(path, limit):
            return .compressionFailed(
                destination: destination,
                reason: "“\(path)” is nested more than \(limit) folders deep.",
                technicalDetails: nil
            )
        case .noUsableSources:
            return .compressionFailed(
                destination: destination,
                reason: error.localizedName,
                technicalDetails: nil
            )
        }
    }
}
