//
//  ArchiveSession.swift
//  ArchiveCore
//
//  The concrete `ArchiveReading` implementation, backed by libarchive.
//
//  A session is bound to one archive. It owns:
//   * metadata scanning (streamed, cancellable, off the main thread);
//   * selective extraction;
//   * single-entry materialisation for Quick Look and drag-and-drop.
//
//  It is an actor because the preview cache and the "current document" are
//  shared mutable state that several UI commands can touch at once. The heavy
//  blocking work is pushed onto detached tasks so the actor never blocks.
//

import Foundation

public actor ArchiveSession: ArchiveReading {

    /// Archive this session is bound to, once opened.
    public private(set) var url: URL?
    /// The most recent scan result.
    public private(set) var document: ArchiveDocument?

    private let openOptions: ArchiveOpenOptions
    private let previewConfiguration: PreviewMaterializer.Configuration
    private let extractionService = ExtractionService()
    private var materializer: PreviewMaterializer?
    private var materializerFailure: String?

    public init(
        url: URL? = nil,
        openOptions: ArchiveOpenOptions = .default,
        previewConfiguration: PreviewMaterializer.Configuration = PreviewMaterializer.Configuration()
    ) {
        self.url = url
        self.openOptions = openOptions
        self.previewConfiguration = previewConfiguration
    }

    // MARK: - Scanning

    /// Streams scan events so the UI can show progress on huge archives.
    ///
    /// The stream finishes with `.finished(document)` or throws. Cancelling the
    /// consuming task cancels the scan.
    public nonisolated func scan(
        url: URL,
        options: ArchiveOpenOptions? = nil
    ) -> AsyncThrowingStream<ArchiveScanEvent, Error> {
        let effectiveOptions = options ?? openOptions

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let document = try LibArchiveScanner.scan(url: url, options: effectiveOptions) { event in
                        continuation.yield(event)
                    }
                    continuation.yield(.finished(document))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ArchiveError.cancelled)
                } catch let error as ArchiveError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ArchiveError.underlying(
                        reason: error.localizedDescription,
                        technicalDetails: String(describing: error)
                    ))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Scans the archive and returns the finished document.
    @discardableResult
    public func open(url: URL) async throws -> ArchiveDocument {
        try await open(url: url, options: nil, progress: nil)
    }

    /// Convenience overload with explicit options.
    @discardableResult
    public func open(url: URL, options: ArchiveOpenOptions) async throws -> ArchiveDocument {
        try await open(url: url, options: options, progress: nil)
    }

    /// Scans the archive, reporting progress, and records the result.
    @discardableResult
    public func open(
        url: URL,
        options: ArchiveOpenOptions?,
        progress: (@Sendable (ArchiveScanProgress) -> Void)?
    ) async throws -> ArchiveDocument {
        let stream = scan(url: url, options: options)
        var finished: ArchiveDocument?

        for try await event in stream {
            switch event {
            case let .detected(format):
                ArchiveCatLog.archive.debug(
                    "detected \(format.formatName ?? "unknown", privacy: .public) / \(format.compressionName ?? "none", privacy: .public)"
                )
            case let .progress(update):
                progress?(update)
            case let .finished(document):
                finished = document
            }
        }

        guard let finished else { throw ArchiveError.unsupportedFormat(url: url, technicalDetails: nil) }

        self.url = url
        self.document = finished
        return finished
    }

    // MARK: - Extraction

    /// Extracts one entry, preserving its path inside the archive.
    public func extract(entry: ArchiveEntry, to destination: URL) async throws {
        let report = try await extract(entries: [entry], to: destination, options: .default, progress: nil)
        if let failure = report.firstFailure { throw failure.error }
        if report.wasCancelled { throw ArchiveError.cancelled }
    }

    /// Extracts several entries; directories are expanded recursively.
    public func extract(entries: [ArchiveEntry], to destination: URL) async throws {
        let report = try await extract(entries: entries, to: destination, options: .default, progress: nil)
        if let failure = report.firstFailure { throw failure.error }
        if report.wasCancelled { throw ArchiveError.cancelled }
    }

    /// The full-fat extraction entry point used by the UI.
    ///
    /// - Parameter entries: the selection; folders are expanded recursively.
    /// - Returns: a report including skipped entries and per-entry failures.
    @discardableResult
    public func extract(
        entries: [ArchiveEntry],
        to destination: URL,
        options: ExtractionOptions,
        progress: (@Sendable (ExtractionProgress) -> Void)? = nil
    ) async throws -> ExtractionReport {
        guard let document else {
            throw ArchiveError.underlying(reason: "No archive is open.", technicalDetails: nil)
        }

        let expanded = document.expandingRecursively(entries)
        guard !expanded.isEmpty else {
            throw ArchiveError.underlying(
                reason: "Nothing can be extracted from this selection.",
                technicalDetails: "The selection expanded to zero entries."
            )
        }

        let archiveURL = document.url
        let service = extractionService

        return try await Task.detached(priority: .userInitiated) {
            do {
                // Off the main thread, but asynchronous: a conflict prompt
                // suspends inside here until the user answers.
                return try await service.extract(
                    archiveURL: archiveURL,
                    entries: expanded,
                    to: destination,
                    options: options,
                    progress: progress
                )
            } catch is CancellationError {
                throw ArchiveError.cancelled
            }
        }.value
    }

    /// Extracts every entry in the archive. Only used when the user explicitly
    /// asks for it.
    @discardableResult
    public func extractEverything(
        to destination: URL,
        options: ExtractionOptions,
        progress: (@Sendable (ExtractionProgress) -> Void)? = nil
    ) async throws -> ExtractionReport {
        guard let document else {
            throw ArchiveError.underlying(reason: "No archive is open.", technicalDetails: nil)
        }
        return try await extract(
            entries: document.entries.filter { $0.safety.isSafe },
            to: destination,
            options: options,
            progress: progress
        )
    }

    // MARK: - Preview

    /// Extracts one entry into the preview cache and returns a URL Quick Look
    /// (or the Finder) can use.
    public func materializeForPreview(entry: ArchiveEntry) async throws -> URL {
        guard let document else {
            throw ArchiveError.previewUnavailable(entryPath: entry.path, reason: "No archive is open.")
        }
        let materializer = try makeMaterializer()
        return try await materializer.materialize(entry: entry, in: document, openOptions: openOptions)
    }

    /// Materialises a drag payload (one or more entries) into the cache.
    public func materializeForDrag(entries: [ArchiveEntry]) async throws -> URL {
        guard let document else {
            throw ArchiveError.previewUnavailable(entryPath: "", reason: "No archive is open.")
        }
        let expanded = document.expandingRecursively(entries)
        let materializer = try makeMaterializer()
        return try await materializer.materializeForDrag(entries: expanded, in: document)
    }

    public func previewCacheSize() async -> Int64 {
        guard let materializer = try? makeMaterializer() else { return 0 }
        return await materializer.currentCacheSize()
    }

    public func purgePreviewCache() async {
        guard let materializer = try? makeMaterializer() else { return }
        await materializer.clear()
    }

    private func makeMaterializer() throws -> PreviewMaterializer {
        if let materializer { return materializer }
        if let materializerFailure {
            throw ArchiveError.previewUnavailable(entryPath: "", reason: materializerFailure)
        }
        do {
            let created = try PreviewMaterializer(configuration: previewConfiguration)
            materializer = created
            return created
        } catch {
            let reason = (error as? ArchiveError)?.explanation ?? error.localizedDescription
            materializerFailure = reason
            throw ArchiveError.previewUnavailable(entryPath: "", reason: reason)
        }
    }
}
