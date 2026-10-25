//
//  NestedArchiveStore.swift
//  ArchiveCore
//
//  Opens an archive that lives *inside* another archive.
//
//  Design
//  ------
//  libarchive cannot read a member and then treat that member as a second
//  archive without a real file, so the member has to be materialised. That is
//  acceptable — it is still only the member, not the parent archive — but it
//  has to be bounded, reusable and never a way to fill the disk:
//
//  * the member is streamed to disk by `ExtractionService` (the same
//    descriptor-relative, no-follow writer used for user extraction);
//  * declared and actual sizes are capped by `maximumMemberBytes`;
//  * everything lives under one cache directory with a hard total budget;
//  * levels *pin* their file with a reference count, so navigating away (and
//    back) cannot pull the file out from under an open session or a live
//    Quick Look preview;
//  * a scan result is cached too, so Back/Forward does not rescan a 20 000
//    entry nested tarball;
//  * eviction is LRU over *unreferenced* entries, and it never deletes the
//    entry being opened.
//
//  The parent archive is never modified, and the materialised file is a private
//  cache copy — the user's archive is untouched.
//

import CryptoKit
import Foundation

// MARK: - Options

public struct NestedArchiveOptions: Sendable {
    /// Where materialised members live. Inside the app's cache, never next to
    /// the user's archive.
    public var cacheDirectory: URL
    /// How many archives may be stacked. 0 would mean "cannot open nested".
    public var maximumDepth: Int
    /// Cap for a single materialised member.
    public var maximumMemberBytes: Int64
    /// Cap for the whole nested cache.
    public var totalBudgetBytes: Int64
    /// Unreferenced entries older than this are purged by `purgeExpired`.
    public var maximumAge: TimeInterval
    /// Safety limits handed to the extraction that produces the member.
    public var extractionLimits: ExtractionLimits

    public init(
        cacheDirectory: URL? = nil,
        maximumDepth: Int = 4,
        maximumMemberBytes: Int64 = 2 * 1024 * 1024 * 1024,
        totalBudgetBytes: Int64 = 4 * 1024 * 1024 * 1024,
        maximumAge: TimeInterval = 24 * 60 * 60
    ) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.maximumDepth = maximumDepth
        self.maximumMemberBytes = maximumMemberBytes
        self.totalBudgetBytes = totalBudgetBytes
        self.maximumAge = maximumAge
        self.extractionLimits = ExtractionLimits(
            maximumEntryCount: 1,
            maximumTotalBytes: maximumMemberBytes,
            maximumSingleEntryBytes: maximumMemberBytes,
            maximumExpansionRatio: nil
        )
    }

    public static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(ArchiveCatBuildInfo.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Nested", isDirectory: true)
    }

    public static let `default` = NestedArchiveOptions()
}

// MARK: - Opened archive

/// A nested archive that has been materialised and scanned.
public struct OpenedNestedArchive: Sendable {
    /// Cache copy of the member. Owned by the store; do not delete.
    public let url: URL
    public let document: ArchiveDocument
    /// A session bound to the materialised file.
    public let session: ArchiveSession
    /// Cache key, needed to release the pin.
    public let cacheKey: String
    /// 1 for a member of the root archive, 2 for a member of a member, …
    public let depth: Int
}

// MARK: - Store

public actor NestedArchiveStore {

    public let options: NestedArchiveOptions

    private var referenceCounts: [String: Int] = [:]
    private var lastUsed: [String: Date] = [:]
    private var sizes: [String: Int64] = [:]
    private var scannedDocuments: [String: ArchiveDocument] = [:]

    public init(options: NestedArchiveOptions = .default) throws {
        self.options = options
        do {
            try FileManager.default.createDirectory(
                at: options.cacheDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ArchiveError.nestedArchiveUnavailable(
                path: options.cacheDirectory.path(percentEncoded: false),
                reason: "The nested archive cache could not be created. \(error.localizedDescription)"
            )
        }

        // Adopt whatever a previous run left behind so the budget is accurate.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: options.cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents {
            let key = url.lastPathComponent
            sizes[key] = Self.directorySize(url)
            lastUsed[key] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
    }

    public var cacheDirectory: URL { options.cacheDirectory }

    // MARK: Opening

    /// Materialises (or reuses) `entry` and opens it as an archive.
    ///
    /// - Parameters:
    ///   - depth: nesting depth of the archive *containing* the entry. 0 for the
    ///     document the user opened.
    /// - Throws: `ArchiveError.nestedArchiveUnavailable` for policy limits, and
    ///   the normal typed errors (encrypted/corrupt/unsupported) when the member
    ///   is not a readable archive.
    public func open(
        entry: ArchiveEntry,
        document: ArchiveDocument,
        session: ArchiveSession,
        depth: Int
    ) async throws -> OpenedNestedArchive {
        guard depth < options.maximumDepth else {
            throw ArchiveError.nestedArchiveUnavailable(
                path: entry.path,
                reason: "Archives nested more than \(options.maximumDepth) levels deep are not opened."
            )
        }
        guard entry.safety.isSafe else {
            throw ArchiveError.unsafePath(
                path: entry.rawPath,
                violation: entry.safety.violation ?? .parentTraversal
            )
        }
        // Only real files can be archives. A symlink here would be materialised
        // as a link, not as bytes, so there would be nothing to scan.
        guard entry.isRegularFile else {
            throw ArchiveError.nestedArchiveUnavailable(
                path: entry.path,
                reason: "It is not a regular file."
            )
        }

        let key = Self.cacheKey(entry: entry, document: document)

        if let fileURL = validCachedFile(for: key, entry: entry) {
            do {
                let opened = try await openMaterialized(fileURL: fileURL, key: key, depth: depth)
                retain(key)
                return opened
            } catch {
                removeEntry(key)
                throw Self.describeFailure(error, entry: entry)
            }
        }

        // Refuse before spending time and disk on a member we already know is
        // over the per-member cap.
        if let declared = entry.uncompressedSize, declared > options.maximumMemberBytes {
            throw ArchiveError.nestedArchiveUnavailable(
                path: entry.path,
                reason: "The archive is \(ArchiveCatFormat.byteCount(declared)), larger than the \(ArchiveCatFormat.byteCount(options.maximumMemberBytes)) limit for archives inside archives."
            )
        }

        // Make room first: the budget check needs to know what is pinned.
        evictUnreferencedIfNeeded(additionalBytes: entry.uncompressedSize ?? 0, protecting: nil)

        // Still no room even after eviction? Fail before extracting anything.
        if let declared = entry.uncompressedSize,
           Self.totalSize(sizes) + declared > options.totalBudgetBytes {
            throw ArchiveError.nestedArchiveUnavailable(
                path: entry.path,
                reason: "The temporary storage budget for archives inside archives (\(ArchiveCatFormat.byteCount(options.totalBudgetBytes))) is full."
            )
        }

        let payloadDirectory = options.cacheDirectory.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: payloadDirectory)
        do {
            try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.nestedArchiveUnavailable(
                path: entry.path,
                reason: "The temporary folder could not be created. \(error.localizedDescription)"
            )
        }

        // Clean up an incomplete materialisation on any failure.
        var materialized = false
        defer {
            if !materialized {
                try? FileManager.default.removeItem(at: payloadDirectory)
            }
        }

        let extractionOptions = memberExtractionOptions
        guard let relativePath = ExtractionPreflight.relativePath(for: entry, options: extractionOptions) else {
            throw ArchiveError.nestedArchiveUnavailable(
                path: entry.path,
                reason: "Its path is not safe to materialise."
            )
        }

        let report: ExtractionReport
        do {
            report = try await session.extract(
                entries: [entry],
                to: payloadDirectory,
                options: extractionOptions
            )
        } catch is CancellationError {
            throw ArchiveError.cancelled
        } catch let error as ArchiveError {
            throw Self.describeFailure(error, entry: entry)
        }

        if let failure = report.firstFailure {
            throw Self.describeFailure(failure.error, entry: entry)
        }
        if report.wasCancelled { throw ArchiveError.cancelled }

        let fileURL = payloadDirectory.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            throw ArchiveError.nestedArchiveUnavailable(
                path: entry.path,
                reason: "It produced no file when materialised."
            )
        }

        sizes[key] = Self.directorySize(payloadDirectory)
        lastUsed[key] = Date()
        materialized = true

        // The declared size can understate the real one; enforce the budget on
        // what actually landed, without ever evicting the entry just opened.
        if Self.totalSize(sizes) > options.totalBudgetBytes {
            evictUnreferenced(until: options.totalBudgetBytes, protecting: key)
            if Self.totalSize(sizes) > options.totalBudgetBytes {
                removeEntry(key)
                throw ArchiveError.nestedArchiveUnavailable(
                    path: entry.path,
                    reason: "The temporary storage budget for archives inside archives (\(ArchiveCatFormat.byteCount(options.totalBudgetBytes))) is full."
                )
            }
        }

        do {
            let opened = try await openMaterialized(fileURL: fileURL, key: key, depth: depth)
            retain(key)
            return opened
        } catch {
            removeEntry(key)
            throw Self.describeFailure(error, entry: entry)
        }
    }

    /// Opens an already-materialised member, scanning it once and caching the
    /// scan for the next visit. Does not take the pin; the caller does.
    private func openMaterialized(fileURL: URL, key: String, depth: Int) async throws -> OpenedNestedArchive {
        let nestedSession = ArchiveSession()
        let identity = ArchiveIdentity.capture(fileURL)

        if let cached = scannedDocuments[key], cached.identity.cacheKeyComponent == identity.cacheKeyComponent {
            await nestedSession.adopt(url: fileURL, document: cached)
            return OpenedNestedArchive(
                url: fileURL,
                document: cached,
                session: nestedSession,
                cacheKey: key,
                depth: depth + 1
            )
        }

        do {
            let scanned = try await nestedSession.open(url: fileURL)
            scannedDocuments[key] = scanned
            return OpenedNestedArchive(
                url: fileURL,
                document: scanned,
                session: nestedSession,
                cacheKey: key,
                depth: depth + 1
            )
        } catch {
            // A materialised file that will not scan is useless; drop the whole
            // cache entry so a retry re-extracts instead of failing forever.
            removeEntry(key)
            throw Self.describeFailure(error, entry: nil)
        }
    }

    /// Reports an already-open nested archive as no longer used by a level.
    ///
    /// The file stays cached (so Back/Forward is instant) until the budget or
    /// age needs it; only the pin is released.
    public func release(cacheKey: String) {
        guard let count = referenceCounts[cacheKey] else { return }
        if count <= 1 {
            referenceCounts.removeValue(forKey: cacheKey)
        } else {
            referenceCounts[cacheKey] = count - 1
        }
        lastUsed[cacheKey] = Date()
    }

    // MARK: Maintenance

    /// Total bytes currently held by the nested cache.
    public func currentSize() -> Int64 {
        Self.totalSize(sizes)
    }

    /// Keys currently pinned by an open level (used by tests and diagnostics).
    public func pinnedKeys() -> Set<String> {
        Set(referenceCounts.keys)
    }

    /// Removes unreferenced entries older than `options.maximumAge`.
    @discardableResult
    public func purgeExpired(now: Date = Date()) -> Int {
        let deadline = now.addingTimeInterval(-options.maximumAge)
        var removed = 0
        for (key, date) in lastUsed where date < deadline {
            guard (referenceCounts[key] ?? 0) == 0 else { continue }
            removeEntry(key)
            removed += 1
        }
        return removed
    }

    /// Empties the cache. Pinned entries are left alone: a live session must
    /// not have its file deleted underneath it.
    public func purgeAll() {
        for key in sizes.keys where (referenceCounts[key] ?? 0) == 0 {
            removeEntry(key)
        }
    }

    // MARK: - Private

    private func retain(_ key: String) {
        referenceCounts[key] = (referenceCounts[key] ?? 0) + 1
        lastUsed[key] = Date()
    }

    /// Options for extracting one member into the cache.
    private var memberExtractionOptions: ExtractionOptions {
        ExtractionOptions(
            conflictPolicy: .replace,
            preservePermissions: false,
            preserveModificationDates: false,
            stripSetuidAndSetgid: true,
            checkAvailableSpace: false,
            limits: options.extractionLimits,
            stripLeadingPathComponents: 0,
            extractSpecialFiles: false
        )
    }

    /// The cached file for a member, if it is still usable.
    ///
    /// The URL is built the same way the extraction built it, rather than by
    /// enumerating the cache: a directory enumerator returns paths resolved
    /// through `/private`, which would make two equal cache hits compare unequal.
    private func validCachedFile(for key: String, entry: ArchiveEntry) -> URL? {
        guard let relativePath = ExtractionPreflight.relativePath(for: entry, options: memberExtractionOptions) else {
            return nil
        }

        let fileURL = options.cacheDirectory
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(relativePath)

        var info = stat()
        let path = fileURL.path(percentEncoded: false)
        guard path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        guard POSIXFileType.isRegular(info.st_mode), info.st_size > 0 else { return nil }
        if let declared = entry.uncompressedSize, declared > 0, Int64(info.st_size) != declared {
            return nil
        }
        return fileURL
    }

    private func evictUnreferencedIfNeeded(additionalBytes: Int64, protecting: String?) {
        guard Self.totalSize(sizes) + additionalBytes > options.totalBudgetBytes else { return }
        // Make room by freeing everything older than the budget allows.
        var total = Self.totalSize(sizes)
        let candidates = sizes.keys
            .filter { $0 != protecting && (referenceCounts[$0] ?? 0) == 0 }
            .sorted { (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast) }
        for key in candidates {
            guard total + additionalBytes > options.totalBudgetBytes else { break }
            total -= sizes[key] ?? 0
            removeEntry(key)
        }
    }

    private func evictUnreferenced(until limit: Int64, protecting: String?) {
        var total = Self.totalSize(sizes)
        guard total > limit else { return }

        let candidates = sizes.keys
            .filter { $0 != protecting && (referenceCounts[$0] ?? 0) == 0 }
            .sorted { (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast) }

        for key in candidates {
            guard total > limit else { break }
            total -= sizes[key] ?? 0
            removeEntry(key)
        }
    }

    private func removeEntry(_ key: String) {
        let payloadDirectory = options.cacheDirectory.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: payloadDirectory)
        sizes.removeValue(forKey: key)
        lastUsed.removeValue(forKey: key)
        referenceCounts.removeValue(forKey: key)
        scannedDocuments.removeValue(forKey: key)
    }

    private static func totalSize(_ sizes: [String: Int64]) -> Int64 {
        sizes.values.reduce(0, +)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func cacheKey(entry: ArchiveEntry, document: ArchiveDocument) -> String {
        let material = "nested|\(document.identity.cacheKeyComponent)|\(entry.ordinal)|\(entry.path)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return String(hex)
    }

    /// Re-frames a failure from "reading an archive" to "opening the archive
    /// inside this one", preserving the original explanation.
    private static func describeFailure(_ error: Error, entry: ArchiveEntry?) -> ArchiveError {
        if let archiveError = error as? ArchiveError {
            switch archiveError {
            case .cancelled:
                return .cancelled
            case .nestedArchiveUnavailable:
                return archiveError
            case let .unsupportedFormat(_, details):
                return .nestedArchiveUnavailable(
                    path: entry?.path ?? "",
                    reason: "The file is not an archive ArchiveCat can read. \(details ?? "")".trimmingCharacters(in: .whitespaces)
                )
            case let .encrypted(_, _):
                return .nestedArchiveUnavailable(
                    path: entry?.path ?? "",
                    reason: "The archive is password protected, and ArchiveCat cannot decrypt it."
                )
            case let .corrupted(_, _, details):
                return .nestedArchiveUnavailable(
                    path: entry?.path ?? "",
                    reason: "The archive inside is damaged. \(details ?? "")".trimmingCharacters(in: .whitespaces)
                )
            case let .cannotOpen(_, reason, _):
                return .nestedArchiveUnavailable(path: entry?.path ?? "", reason: reason)
            case let .limitExceeded(kind, limit, observed):
                return .nestedArchiveUnavailable(
                    path: entry?.path ?? "",
                    reason: "\(kind.localizedDescription) exceeded the configured limit of \(ArchiveCatFormat.byteCount(limit)) (observed \(ArchiveCatFormat.byteCount(observed)))."
                )
            default:
                return .nestedArchiveUnavailable(path: entry?.path ?? "", reason: archiveError.explanation)
            }
        }
        return .nestedArchiveUnavailable(path: entry?.path ?? "", reason: error.localizedDescription)
    }
}
