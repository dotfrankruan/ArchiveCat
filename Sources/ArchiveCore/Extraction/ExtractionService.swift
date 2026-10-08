//
//  ExtractionService.swift
//  ArchiveCore
//
//  Selective extraction, in a single streaming pass over the archive.
//
//  Guarantees
//  ----------
//  1. Only the requested entries are written; the archive is never unpacked
//     wholesale unless the caller asked for every entry.
//  2. Nothing is written outside the destination root — see `SecureDestination`.
//  3. Symlinks and hard links are created only after every regular file, and a
//     symlink is created only when its target resolves inside the root.
//  4. Cancellation is honoured between blocks and between entries.
//  5. A failure on one entry does not abandon the rest; it is recorded in the
//     report so the user can see exactly what did and did not land.
//  6. Nothing is ever overwritten silently: the conflict policy is an explicit
//     user choice, and even then directories and pre-existing symlinks are
//     never replaced.
//

import CArchive
import Darwin
import Foundation

public struct ExtractionService: Sendable {
    public init() {}

    /// Extracts `entries` from the archive at `archiveURL` into `destination`.
    ///
    /// - Parameter progress: called once per completed entry.
    /// - Parameter options: `conflictResolver` is asked about every collision
    ///   and its answer is executed as given; `conflictPolicy` is only the
    ///   pre-decided fallback when no resolver is installed.
    /// - Returns: a report describing what was written, skipped and failed.
    ///   A cancelled operation — including one stopped by the user choosing
    ///   "Cancel" in a conflict prompt — returns a report with
    ///   `wasCancelled == true` rather than throwing, so partial results are
    ///   not lost and the caller can describe them.
    ///
    /// Asynchronous because a conflict prompt suspends until the user answers.
    /// The actual I/O still runs on whatever task calls this, off the main
    /// thread; nothing here touches AppKit.
    public func extract(
        archiveURL: URL,
        entries: [ArchiveEntry],
        to destination: URL,
        options: ExtractionOptions = .default,
        progress: (@Sendable (ExtractionProgress) -> Void)? = nil
    ) async throws -> ExtractionReport {
        let started = Date()
        var report = ExtractionReport(destination: destination)

        // De-duplicate by ordinal: the same entry can be handed in twice when a
        // folder and one of its children are both selected.
        let selectedOrdinals = Set(entries.map(\.ordinal))
        guard !selectedOrdinals.isEmpty else {
            report.duration = Date().timeIntervalSince(started)
            return report
        }

        let destination = try prepareDestination(destination, options: options, entries: entries)

        let archiveAccess = SecurityScopedAccess(url: archiveURL, enabled: true)
        defer { archiveAccess.end() }
        let destinationAccess = SecurityScopedAccess(url: destination, enabled: true)
        defer { destinationAccess.end() }

        let secure = try SecureDestination(root: destination)

        let stream: LibArchiveReadStream
        do {
            stream = try LibArchiveReadStream()
            try stream.enableAutoDetection()
            try stream.open(path: archiveURL.path(percentEncoded: false))
        } catch let failure as LibArchiveFailure {
            throw LibArchiveScanner.openError(url: archiveURL, failure: failure)
        }
        defer { stream.free() }

        // Work that has to wait until the file pass is complete.
        var pendingDirectoryMetadata: [(relativePath: String, mode: mode_t?, date: Date?)] = []
        var pendingFileMetadata: [(relativePath: String, date: Date)] = []
        var pendingSymlinks: [(entry: ArchiveEntry, relativePath: String, target: String)] = []
        var pendingHardlinks: [(entry: ArchiveEntry, relativePath: String, target: String)] = []
        var extractedRelativePaths: Set<String> = []

        var ordinal = 0
        var completedEntries = 0
        var bytesWritten: Int64 = 0
        var cancelled = false

        extractionLoop: while true {
            if Task.isCancelled {
                cancelled = true
                break
            }

            let hasHeader: Bool
            do {
                hasHeader = try stream.nextHeader()
            } catch let failure as LibArchiveFailure {
                throw ArchiveError.corrupted(url: archiveURL, entryPath: nil, technicalDetails: failure.diagnostic)
            }
            if !hasHeader { break }

            defer { ordinal += 1 }

            guard selectedOrdinals.contains(ordinal), let snapshot = stream.snapshotCurrentEntry() else {
                // libarchive skips the current entry's data implicitly on the
                // next header call, but doing it explicitly keeps the closed
                // form of the loop honest for seekable containers.
                try stream.skipCurrentEntryData()
                continue
            }

            let entry = LibArchiveScanner.makeEntry(snapshot: snapshot, ordinal: ordinal, options: .default, format: nil)

            guard entry.safety.isSafe,
                  let relativePath = ExtractionPreflight.relativePath(for: entry, options: options)
            else {
                report.skipped.append(.init(entry: entry, destination: nil, reason: .unsafePath))
                try stream.skipCurrentEntryData()
                continue
            }

            do {
                try enforce(limits: options.limits, entry: entry, soFar: bytesWritten, completed: completedEntries)

                // Ask about a collision *before* writing anything, and do what
                // the answer says. A folder is not a conflict: creating one that
                // already exists is a no-op rather than a decision.
                var action = ConflictAction(policy: options.conflictPolicy)
                if entry.type != .directory {
                    switch await conflictOutcome(
                        entry: entry,
                        relativePath: relativePath,
                        destination: destination,
                        secure: secure,
                        options: options
                    ) {
                    case .cancelOperation:
                        cancelled = true
                        break extractionLoop

                    case .skipExisting:
                        report.skipped.append(.init(
                            entry: entry,
                            destination: destination.appendingPathComponent(relativePath),
                            reason: .alreadyExists
                        ))
                        try stream.skipCurrentEntryData()
                        completedEntries += 1
                        progress?(ExtractionProgress(
                            completedEntries: completedEntries,
                            totalEntries: selectedOrdinals.count,
                            bytesWritten: bytesWritten,
                            currentPath: entry.path
                        ))
                        continue

                    case let .proceed(resolved):
                        action = resolved
                    }
                }

                switch entry.type {
                case .directory:
                    let parentRelative = ArchivePath.parent(of: relativePath) ?? ""
                    if !parentRelative.isEmpty {
                        try secure.createDirectory(relativePath: parentRelative)
                    }
                    try secure.createDirectory(relativePath: relativePath)
                    pendingDirectoryMetadata.append((relativePath, entry.posixMode.map { mode_t($0) }, entry.modificationDate))
                    report.extracted.append(.init(
                        entry: entry,
                        destination: destination.appendingPathComponent(relativePath),
                        bytesWritten: 0
                    ))
                    try stream.skipCurrentEntryData()

                case .regularFile, .unknown:
                    if let result = try writeFile(
                        entry: entry,
                        relativePath: relativePath,
                        action: action,
                        stream: stream,
                        secure: secure,
                        options: options,
                        report: &report
                    ) {
                        bytesWritten += result.bytesWritten
                        extractedRelativePaths.insert(result.relativePath)
                        if let date = result.modificationDate {
                            pendingFileMetadata.append((result.relativePath, date))
                        }
                        report.extracted.append(.init(
                            entry: entry,
                            destination: destination.appendingPathComponent(result.relativePath),
                            bytesWritten: result.bytesWritten
                        ))
                    }

                case .symbolicLink:
                    try ensureParentDirectory(of: relativePath, secure: secure)
                    pendingSymlinks.append((entry, relativePath, entry.symlinkTarget ?? ""))
                    try stream.skipCurrentEntryData()

                case .hardLink:
                    try ensureParentDirectory(of: relativePath, secure: secure)
                    pendingHardlinks.append((entry, relativePath, entry.hardlinkTarget ?? ""))
                    try stream.skipCurrentEntryData()

                case .fifo:
                    try ensureParentDirectory(of: relativePath, secure: secure)
                    if options.extractSpecialFiles {
                        try secure.createFIFO(relativePath: relativePath, mode: entry.posixMode.map { mode_t($0) } ?? 0o644)
                        report.extracted.append(.init(
                            entry: entry,
                            destination: destination.appendingPathComponent(relativePath),
                            bytesWritten: 0
                        ))
                    } else {
                        report.skipped.append(.init(entry: entry, destination: nil, reason: .unsupportedType))
                    }
                    try stream.skipCurrentEntryData()

                case .socket, .characterDevice, .blockDevice:
                    report.skipped.append(.init(entry: entry, destination: nil, reason: .unsupportedType))
                    try stream.skipCurrentEntryData()
                }

                completedEntries += 1
                progress?(ExtractionProgress(
                    completedEntries: completedEntries,
                    totalEntries: selectedOrdinals.count,
                    bytesWritten: bytesWritten,
                    currentPath: entry.path
                ))
            } catch is CancellationError {
                cancelled = true
                break extractionLoop
            } catch let error as ArchiveError where !error.isCancellation {
                // A safety limit is a hard stop, not a per-entry failure.
                if case .limitExceeded = error { throw error }
                report.failures.append(.init(entry: entry, destination: nil, error: error))
                try? stream.skipCurrentEntryData()
            } catch let error as POSIXFailure {
                report.failures.append(.init(
                    entry: entry,
                    destination: destination.appendingPathComponent(relativePath),
                    error: .extractionFailed(
                        path: entry.path,
                        destination: destination,
                        reason: "ArchiveCat could not write this item.",
                        technicalDetails: error.diagnostic
                    )
                ))
            } catch let error as LibArchiveFailure {
                report.failures.append(.init(
                    entry: entry,
                    destination: destination.appendingPathComponent(relativePath),
                    error: .corrupted(url: archiveURL, entryPath: entry.path, technicalDetails: error.diagnostic)
                ))
            }
        }

        // MARK: Post-pass
        //
        // Links come last, after every regular file exists, so a symlink can
        // never be used as a traversal vector for a later write.
        if !cancelled {
            var linksCompleted = await createPendingSymlinks(
                pendingSymlinks,
                secure: secure,
                destination: destination,
                options: options,
                report: &report
            )
            if linksCompleted {
                linksCompleted = await createPendingHardlinks(
                    pendingHardlinks,
                    secure: secure,
                    destination: destination,
                    options: options,
                    extractedRelativePaths: extractedRelativePaths,
                    report: &report
                )
            }

            if linksCompleted {
                applyDeferredMetadata(
                    directories: pendingDirectoryMetadata,
                    files: pendingFileMetadata,
                    secure: secure,
                    options: options
                )
            } else {
                // The user cancelled from a link's conflict prompt. What is
                // already on disk stays; the report says so.
                cancelled = true
            }
        }

        report.totalBytesWritten = bytesWritten
        report.wasCancelled = cancelled
        report.duration = Date().timeIntervalSince(started)
        return report
    }

    // MARK: - Files

    private struct FileWriteResult {
        let bytesWritten: Int64
        let relativePath: String
        let modificationDate: Date?
    }

    private func writeFile(
        entry: ArchiveEntry,
        relativePath: String,
        action: ConflictAction,
        stream: LibArchiveReadStream,
        secure: SecureDestination,
        options: ExtractionOptions,
        report: inout ExtractionReport
    ) throws -> FileWriteResult? {
        var mode: mode_t = entry.posixMode.map { mode_t($0) } ?? 0o644
        if options.stripSetuidAndSetgid {
            mode &= ~mode_t(0o6000)
        }
        if mode & 0o777 == 0 {
            // A declared mode of 000 would produce a file the user cannot open;
            // they asked for this file, so keep it readable by its owner.
            mode |= 0o600
        }

        // Create the parent chain first: extracting one file out of a deep
        // path (`usr/bin/tool`) must not depend on the directories above it
        // also having been selected.
        let parent = ArchivePath.parent(of: relativePath) ?? ""
        if !parent.isEmpty {
            try secure.createDirectory(relativePath: parent)
        }

        guard let created = try secure.createFile(relativePath: relativePath, mode: mode, action: action) else {
            report.skipped.append(.init(entry: entry, destination: nil, reason: .alreadyExists))
            try stream.skipCurrentEntryData()
            return nil
        }

        defer { close(created.descriptor) }

        var written: Int64 = 0
        var blockCounter = 0

        try stream.readCurrentEntryData { block in
            blockCounter += 1
            // Checking every block would dominate the cost of writing; 32
            // blocks is still well under a millisecond of work.
            if blockCounter % 32 == 0, Task.isCancelled {
                throw CancellationError()
            }
            try Self.writeAll(block, to: created.descriptor)
            written += Int64(block.count)
        }

        if options.preservePermissions {
            secure.applyPermissions(descriptor: created.descriptor, mode: mode)
        }

        return FileWriteResult(
            bytesWritten: written,
            relativePath: created.relativePath,
            modificationDate: options.preserveModificationDates ? entry.modificationDate : nil
        )
    }

    /// Writes a whole block, retrying on short writes and `EINTR`.
    private static func writeAll(_ block: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        guard let base = block.baseAddress, block.count > 0 else { return }
        var offset = 0
        while offset < block.count {
            let result = write(descriptor, base.advanced(by: offset), block.count - offset)
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXFailure(operation: "write", errorNumber: errno, relativePath: "")
            }
            if result == 0 {
                throw POSIXFailure(operation: "write", errorNumber: EIO, relativePath: "")
            }
            offset += result
        }
    }

    // MARK: - Conflict decisions

    /// What should happen to one entry, given what already exists.
    private enum EntryConflictOutcome {
        /// Write it, using this action.
        case proceed(ConflictAction)
        /// Leave the existing item alone; do not write this entry.
        case skipExisting
        /// Stop the whole extraction.
        case cancelOperation
    }

    /// Describes a collision to `options.conflictResolver` and turns the answer
    /// into a concrete action.
    ///
    /// Everything the user is not asked about is deliberate:
    /// * no existing item — nothing to decide;
    /// * a *folder* at the target path — "Replace" would mean deleting a folder,
    ///   which ArchiveCat does not do, so the writer is left to refuse it and
    ///   say so rather than offering a choice that cannot be honoured;
    /// * no resolver installed — fall back to the configured policy.
    private func conflictOutcome(
        entry: ArchiveEntry,
        relativePath: String,
        destination: URL,
        secure: SecureDestination,
        options: ExtractionOptions
    ) async -> EntryConflictOutcome {
        guard secure.exists(relativePath: relativePath) else {
            // Nothing there: write it, whatever a policy would have said.
            return .proceed(.replace)
        }

        let existingIsDirectory = (try? secure.isDirectory(relativePath: relativePath)) ?? false
        guard !existingIsDirectory, let resolver = options.conflictResolver else {
            return .proceed(ConflictAction(policy: options.conflictPolicy))
        }

        let conflict = ExtractionConflict(
            entry: entry,
            relativePath: relativePath,
            destination: destination,
            existingIsDirectory: false
        )

        switch await resolver(conflict) {
        case .replace: return .proceed(.replace)
        case .skip: return .skipExisting
        case .keepBoth: return .proceed(.keepBoth)
        case .cancel:
            ArchiveCatLog.extraction.notice("extraction cancelled at a conflict prompt")
            return .cancelOperation
        }
    }

    /// The same decision, for a link that is created in the post-pass.
    ///
    /// - Returns: the path to create the link at, and whether the user asked to
    ///   cancel the whole operation.
    private func linkDestination(
        entry: ArchiveEntry,
        relativePath: String,
        destination: URL,
        secure: SecureDestination,
        options: ExtractionOptions
    ) async throws -> (path: String?, cancelled: Bool) {
        guard secure.exists(relativePath: relativePath) else {
            return (relativePath, false)
        }

        let existingIsDirectory = (try? secure.isDirectory(relativePath: relativePath)) ?? false
        var action = ConflictAction(policy: options.conflictPolicy)

        if !existingIsDirectory, let resolver = options.conflictResolver {
            let conflict = ExtractionConflict(
                entry: entry,
                relativePath: relativePath,
                destination: destination,
                existingIsDirectory: false
            )
            switch await resolver(conflict) {
            case .replace: action = .replace
            case .skip: return (nil, false)
            case .keepBoth: action = .keepBoth
            case .cancel: return (nil, true)
            }
        }

        switch action {
        case .skip:
            return (nil, false)
        case .keepBoth:
            return (try secure.uniqueRelativePath(for: relativePath), false)
        case .replace:
            // Never delete a folder, and never write through a symlink: replace
            // means "remove the file that is in the way, then create ours".
            if existingIsDirectory {
                throw POSIXFailure(operation: "replace directory with link", errorNumber: EISDIR, relativePath: relativePath)
            }
            try secure.removeFile(relativePath: relativePath)
            return (relativePath, false)
        }
    }

    // MARK: - Links

    private func ensureParentDirectory(of relativePath: String, secure: SecureDestination) throws {
        let parent = ArchivePath.parent(of: relativePath) ?? ""
        guard !parent.isEmpty else { return }
        try secure.createDirectory(relativePath: parent)
    }

    /// - Returns: `false` when the user cancelled from a conflict prompt.
    private func createPendingSymlinks(
        _ pending: [(entry: ArchiveEntry, relativePath: String, target: String)],
        secure: SecureDestination,
        destination: URL,
        options: ExtractionOptions,
        report: inout ExtractionReport
    ) async -> Bool {
        for item in pending.sorted(by: { ArchivePath.depth(of: $0.relativePath) < ArchivePath.depth(of: $1.relativePath) }) {
            switch ArchivePath.resolveSymlinkTarget(item.target, linkPath: item.entry.path) {
            case let .escapesRoot(violation):
                ArchiveCatLog.security.notice(
                    "refused symlink \(item.entry.path, privacy: .public): target resolves outside the destination"
                )
                report.failures.append(.init(
                    entry: item.entry,
                    destination: destination.appendingPathComponent(item.relativePath),
                    error: .unsafePath(path: item.entry.path, violation: violation)
                ))

            case .insideRoot:
                do {
                    let decision = try await linkDestination(
                        entry: item.entry,
                        relativePath: item.relativePath,
                        destination: destination,
                        secure: secure,
                        options: options
                    )
                    if decision.cancelled { return false }
                    guard let finalPath = decision.path else {
                        report.skipped.append(.init(entry: item.entry, destination: nil, reason: .alreadyExists))
                        continue
                    }
                    try secure.createSymbolicLink(relativePath: finalPath, target: item.target)
                    report.extracted.append(.init(
                        entry: item.entry,
                        destination: destination.appendingPathComponent(finalPath),
                        bytesWritten: 0
                    ))
                } catch let error as POSIXFailure {
                    report.failures.append(.init(
                        entry: item.entry,
                        destination: destination.appendingPathComponent(item.relativePath),
                        error: .extractionFailed(
                            path: item.entry.path,
                            destination: destination,
                            reason: "The symbolic link could not be created.",
                            technicalDetails: error.diagnostic
                        )
                    ))
                } catch {
                    report.failures.append(.init(
                        entry: item.entry,
                        destination: destination.appendingPathComponent(item.relativePath),
                        error: .underlying(
                            reason: "The symbolic link could not be created.",
                            technicalDetails: String(describing: error)
                        )
                    ))
                }
            }
        }
        return true
    }

    /// - Returns: `false` when the user cancelled from a conflict prompt.
    private func createPendingHardlinks(
        _ pending: [(entry: ArchiveEntry, relativePath: String, target: String)],
        secure: SecureDestination,
        destination: URL,
        options: ExtractionOptions,
        extractedRelativePaths: Set<String>,
        report: inout ExtractionReport
    ) async -> Bool {
        for item in pending {
            let normalizedTarget = ArchivePath.normalize(rawPath: item.target)

            guard normalizedTarget.isSafe,
                  let targetRelativePath = ExtractionPreflight.relativePath(
                    for: ArchiveEntry(
                        id: ArchiveEntryID(ordinal: -1, path: normalizedTarget.normalized),
                        ordinal: -1,
                        rawPath: item.target,
                        path: normalizedTarget.normalized,
                        name: normalizedTarget.name,
                        parentPath: normalizedTarget.parentPath,
                        type: .regularFile
                    ),
                    options: options
                  )
            else {
                report.failures.append(.init(
                    entry: item.entry,
                    destination: destination.appendingPathComponent(item.relativePath),
                    error: .unsafePath(path: item.entry.path, violation: normalizedTarget.violation ?? .parentTraversal)
                ))
                continue
            }

            // The target must have been extracted in this run, or already exist
            // in the destination from an earlier extraction.
            let targetAvailable = extractedRelativePaths.contains(targetRelativePath)
                || secure.exists(relativePath: targetRelativePath)

            guard targetAvailable else {
                report.skipped.append(.init(entry: item.entry, destination: nil, reason: .missingHardlinkTarget))
                continue
            }

            do {
                let decision = try await linkDestination(
                    entry: item.entry,
                    relativePath: item.relativePath,
                    destination: destination,
                    secure: secure,
                    options: options
                )
                if decision.cancelled { return false }
                guard let finalPath = decision.path else {
                    report.skipped.append(.init(entry: item.entry, destination: nil, reason: .alreadyExists))
                    continue
                }
                try secure.createHardLink(relativePath: finalPath, toRelativePath: targetRelativePath)
                report.extracted.append(.init(
                    entry: item.entry,
                    destination: destination.appendingPathComponent(finalPath),
                    bytesWritten: 0
                ))
            } catch let error as POSIXFailure {
                report.failures.append(.init(
                    entry: item.entry,
                    destination: destination.appendingPathComponent(item.relativePath),
                    error: .extractionFailed(
                        path: item.entry.path,
                        destination: destination,
                        reason: "The hard link could not be created.",
                        technicalDetails: error.diagnostic
                    )
                ))
            } catch {
                report.failures.append(.init(
                    entry: item.entry,
                    destination: destination.appendingPathComponent(item.relativePath),
                    error: .underlying(
                        reason: "The hard link could not be created.",
                        technicalDetails: String(describing: error)
                    )
                ))
            }
        }
        return true
    }

    // MARK: - Deferred metadata

    private func applyDeferredMetadata(
        directories: [(relativePath: String, mode: mode_t?, date: Date?)],
        files: [(relativePath: String, date: Date)],
        secure: SecureDestination,
        options: ExtractionOptions
    ) {
        for file in files {
            try? secure.setModificationDate(relativePath: file.relativePath, date: file.date)
        }

        // Deepest first: touching a parent afterwards would disturb it.
        for directory in directories.sorted(by: { ArchivePath.depth(of: $0.relativePath) > ArchivePath.depth(of: $1.relativePath) }) {
            if options.preservePermissions, let mode = directory.mode {
                var sanitized = mode
                if options.stripSetuidAndSetgid { sanitized &= ~mode_t(0o6000) }
                try? secure.applyDirectoryPermissions(relativePath: directory.relativePath, mode: sanitized)
            }
            if options.preserveModificationDates, let date = directory.date {
                try? secure.setModificationDate(relativePath: directory.relativePath, date: date)
            }
        }
    }

    // MARK: - Limits

    private func enforce(
        limits: ExtractionLimits,
        entry: ArchiveEntry,
        soFar: Int64,
        completed: Int
    ) throws {
        if let maximum = limits.maximumEntryCount, completed >= maximum {
            throw ArchiveError.limitExceeded(kind: .entries, limit: Int64(maximum), observed: Int64(completed))
        }
        if let maximum = limits.maximumSingleEntryBytes,
           let size = entry.uncompressedSize, size > maximum {
            throw ArchiveError.limitExceeded(kind: .singleEntryBytes, limit: maximum, observed: size)
        }
        if let maximum = limits.maximumTotalBytes,
           let size = entry.uncompressedSize, soFar + size > maximum {
            throw ArchiveError.limitExceeded(kind: .totalUncompressedBytes, limit: maximum, observed: soFar + size)
        }
    }

    // MARK: - Destination

    private func prepareDestination(
        _ destination: URL,
        options: ExtractionOptions,
        entries: [ArchiveEntry]
    ) throws -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: destination.path(percentEncoded: false), isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ArchiveError.destinationUnusable(url: destination, reason: "That is a file, not a folder.")
            }
        } else {
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                throw ArchiveError.destinationUnusable(url: destination, reason: error.localizedDescription)
            }
        }

        guard fileManager.isWritableFile(atPath: destination.path(percentEncoded: false)) else {
            throw ArchiveError.destinationUnusable(url: destination, reason: "ArchiveCat cannot write to this folder.")
        }

        if options.checkAvailableSpace, let available = ExtractionPreflight.availableSpace(at: destination) {
            let required = entries.reduce(Int64(0)) { $0 + ($1.uncompressedSize ?? 0) }
            if required > 0, required > available {
                throw ArchiveError.destinationUnusable(
                    url: destination,
                    reason: "There is not enough free space: \(ArchiveCatFormat.byteCount(required)) needed, \(ArchiveCatFormat.byteCount(available)) available."
                )
            }
        }

        return destination
    }
}
