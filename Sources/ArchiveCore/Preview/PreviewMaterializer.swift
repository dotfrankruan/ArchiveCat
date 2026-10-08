//
//  PreviewMaterializer.swift
//  ArchiveCore
//
//  Materialises exactly one entry so macOS Quick Look can display it.
//
//  Rules
//  -----
//  * One entry is extracted. Never the archive, never a directory subtree.
//  * The cache key folds in the archive's path, size, mtime and inode plus the
//    entry's ordinal and path, so entries from two different archives can never
//    collide even when the archives share a filename.
//  * A cached file is reused when it is still valid: it exists and is not older
//    than the archive it came from.
//  * Concurrent requests for the same entry share one extraction.
//  * The cache is bounded and can be purged; nothing here touches the user's
//    Documents.
//

import CryptoKit
import Foundation

/// Caches single-entry extractions for Quick Look and drag-and-drop.
public actor PreviewMaterializer {

    // MARK: Configuration

    public struct Configuration: Sendable {
        /// Root of the preview cache. Defaults to
        /// `~/Library/Caches/<bundle-id>/Preview`.
        public var cacheDirectory: URL
        /// Soft limit; the oldest entries are removed past it.
        public var maximumCacheBytes: Int64
        /// Entries older than this are removed by `purgeExpired`.
        public var maximumAge: TimeInterval
        /// Reuse a cached file when valid.
        public var reuseExisting: Bool
        /// Safety bounds applied to the single-entry extraction.
        public var limits: ExtractionLimits

        public init(
            cacheDirectory: URL? = nil,
            maximumCacheBytes: Int64 = 4 * 1024 * 1024 * 1024,
            maximumAge: TimeInterval = 14 * 24 * 60 * 60,
            reuseExisting: Bool = true,
            limits: ExtractionLimits = .conservative
        ) {
            self.cacheDirectory = cacheDirectory ?? Configuration.defaultCacheDirectory()
            self.maximumCacheBytes = maximumCacheBytes
            self.maximumAge = maximumAge
            self.reuseExisting = reuseExisting
            self.limits = limits
        }

        public static func defaultCacheDirectory() -> URL {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base
                .appendingPathComponent(ArchiveCatBuildInfo.bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Preview", isDirectory: true)
        }
    }

    // MARK: State

    public let configuration: Configuration
    private let service = ExtractionService()
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        do {
            try FileManager.default.createDirectory(
                at: configuration.cacheDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ArchiveError.previewUnavailable(
                entryPath: "",
                reason: "The preview cache at \(configuration.cacheDirectory.path(percentEncoded: false)) could not be created."
            )
        }
    }

    public var cacheDirectory: URL { configuration.cacheDirectory }

    // MARK: Materialisation

    /// Extracts `entry` into the cache and returns a URL Quick Look can open.
    ///
    /// - Throws: `ArchiveError.previewUnavailable` when the entry cannot be
    ///   prepared, or the underlying extraction error.
    public func materialize(
        entry: ArchiveEntry,
        in document: ArchiveDocument,
        openOptions: ArchiveOpenOptions = .default
    ) async throws -> URL {
        guard entry.safety.isSafe else {
            throw ArchiveError.unsafePath(path: entry.rawPath, violation: entry.safety.violation ?? .parentTraversal)
        }

        let key = Self.cacheKey(for: entry, in: document)
        let payloadDirectory = configuration.cacheDirectory.appendingPathComponent(key, isDirectory: true)

        if configuration.reuseExisting, let cached = validCachedURL(entry: entry, document: document, in: payloadDirectory) {
            ArchiveCatLog.preview.debug("preview cache hit")
            return cached
        }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<URL, Error>.detached(priority: .userInitiated) { [service, configuration, payloadDirectory] in
            // A folder preview is just an empty folder carrying the right name:
            // extracting a subtree to preview it would betray the product's
            // central promise, and Quick Look only needs the name and the icon.
            if entry.isDirectory {
                let directory = payloadDirectory.appendingPathComponent(entry.name, isDirectory: true)
                try? FileManager.default.removeItem(at: payloadDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return directory
            }

            guard let relativePath = ExtractionPreflight.relativePath(for: entry, options: .default) else {
                throw ArchiveError.previewUnavailable(entryPath: entry.path, reason: "Its path is not safe to write.")
            }

            let payloadURL = payloadDirectory.appendingPathComponent(relativePath)

            // Start from a clean directory: a half-written cache entry is worse
            // than no cache entry.
            try? FileManager.default.removeItem(at: payloadDirectory)
            try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)

            do {
                let report = try await service.extract(
                    archiveURL: document.url,
                    entries: [entry],
                    to: payloadDirectory,
                    options: ExtractionOptions(
                        conflictPolicy: .replace,
                        preservePermissions: false,
                        preserveModificationDates: false,
                        stripSetuidAndSetgid: true,
                        checkAvailableSpace: false,
                        limits: configuration.limits,
                        extractSpecialFiles: false
                    )
                )

                if let failure = report.firstFailure {
                    throw failure.error
                }
                if report.wasCancelled {
                    throw ArchiveError.cancelled
                }
                guard FileManager.default.fileExists(atPath: payloadURL.path(percentEncoded: false)) else {
                    throw ArchiveError.previewUnavailable(
                        entryPath: entry.path,
                        reason: "The entry produced no file. It may be a link or a special file."
                    )
                }
                return payloadURL
            } catch {
                try? FileManager.default.removeItem(at: payloadDirectory)
                throw error
            }
        }

        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let url = try await task.value
            trimIfNeeded()
            return url
        } catch let error as ArchiveError {
            throw error
        } catch is CancellationError {
            throw ArchiveError.cancelled
        } catch {
            throw ArchiveError.previewUnavailable(entryPath: entry.path, reason: error.localizedDescription)
        }
    }

    /// Materialises a set of entries into a fresh directory and returns it.
    ///
    /// Used by drag-and-drop: the returned directory holds the dragged items
    /// with their archive-relative paths preserved, and is cleaned up by
    /// `removeMaterializedDirectory`.
    public func materializeForDrag(
        entries: [ArchiveEntry],
        in document: ArchiveDocument
    ) async throws -> URL {
        guard !entries.isEmpty else {
            throw ArchiveError.previewUnavailable(entryPath: "", reason: "Nothing was selected.")
        }

        let key = Self.dragCacheKey(for: entries, in: document)
        let directory = configuration.cacheDirectory
            .appendingPathComponent("Drag", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)

        let service = self.service
        let limits = configuration.limits

        return try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let report = try await service.extract(
                archiveURL: document.url,
                entries: entries,
                to: directory,
                options: ExtractionOptions(
                    conflictPolicy: .replace,
                    preservePermissions: true,
                    preserveModificationDates: true,
                    stripSetuidAndSetgid: true,
                    checkAvailableSpace: false,
                    limits: limits,
                    extractSpecialFiles: false
                )
            )

            if let failure = report.firstFailure {
                throw failure.error
            }
            return directory
        }.value
    }

    public func removeMaterializedDirectory(_ url: URL) {
        // Only ever delete inside our own cache.
        let cachePath = configuration.cacheDirectory.standardizedFileURL.path(percentEncoded: false)
        let targetPath = url.standardizedFileURL.path(percentEncoded: false)
        guard targetPath.hasPrefix(cachePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Maintenance

    /// Removes cache entries older than the configured age.
    @discardableResult
    public func purgeExpired(now: Date = Date()) -> Int {
        let deadline = now.addingTimeInterval(-configuration.maximumAge)
        var removed = 0
        for directory in cacheEntryDirectories() {
            let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < deadline {
                try? FileManager.default.removeItem(at: directory)
                removed += 1
            }
        }
        if removed > 0 {
            ArchiveCatLog.preview.debug("purged \(removed, privacy: .public) preview cache entries")
        }
        return removed
    }

    /// Deletes everything in the preview cache.
    public func clear() {
        for directory in cacheEntryDirectories() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Total size of the cache, in bytes.
    public func currentCacheSize() -> Int64 {
        var total: Int64 = 0
        for directory in cacheEntryDirectories() {
            total += Self.directorySize(directory)
        }
        return total
    }

    /// Removes the least recently used entries until the cache fits the limit.
    private func trimIfNeeded() {
        guard configuration.maximumCacheBytes > 0 else { return }

        var entries: [(url: URL, date: Date, size: Int64)] = []
        var total: Int64 = 0

        for directory in cacheEntryDirectories() {
            let size = Self.directorySize(directory)
            let date = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            entries.append((directory, date, size))
            total += size
        }

        guard total > configuration.maximumCacheBytes else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= configuration.maximumCacheBytes { break }
        }
    }

    private func cacheEntryDirectories() -> [URL] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: configuration.cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
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

    // MARK: Cache keys

    /// Whether a previously extracted copy is still good.
    private func validCachedURL(entry: ArchiveEntry, document: ArchiveDocument, in payloadDirectory: URL) -> URL? {
        let candidate: URL
        if entry.isDirectory {
            candidate = payloadDirectory.appendingPathComponent(entry.name, isDirectory: true)
        } else {
            guard let relativePath = ExtractionPreflight.relativePath(for: entry, options: .default) else { return nil }
            candidate = payloadDirectory.appendingPathComponent(relativePath)
        }

        guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) else { return nil }

        // A cached copy is stale if the archive has been modified since.
        if let archiveDate = document.identity.modificationDate,
           let cachedDate = (try? candidate.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           cachedDate < archiveDate {
            return nil
        }

        // Zero-length files are legitimate; only a size mismatch is suspicious.
        if !entry.isDirectory, let expected = entry.uncompressedSize, expected > 0 {
            let actual = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if let actual, Int64(actual) != expected { return nil }
        }

        return candidate
    }

    /// A key that cannot collide across archives or across duplicate paths
    /// inside one archive.
    static func cacheKey(for entry: ArchiveEntry, in document: ArchiveDocument) -> String {
        let material = "preview|\(document.identity.cacheKeyComponent)|\(entry.ordinal)|\(entry.path)"
        return digest(material: material, name: entry.name)
    }

    static func dragCacheKey(for entries: [ArchiveEntry], in document: ArchiveDocument) -> String {
        let ordinals = entries.map(\.ordinal).sorted().map(String.init).joined(separator: ",")
        let material = "drag|\(document.identity.cacheKeyComponent)|\(ordinals)"
        let name = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        return digest(material: material, name: name)
    }

    private static func digest(material: String, name: String) -> String {
        let hash = SHA256.hash(data: Data(material.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined().prefix(32)
        // Keep a readable, filesystem-safe name so Quick Look and the Finder
        // drag image show something meaningful.
        let sanitized = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        let trimmed = sanitized.count > 64 ? String(sanitized.prefix(64)) : sanitized
        return trimmed.isEmpty ? String(hex) : "\(hex)-\(trimmed)"
    }
}
