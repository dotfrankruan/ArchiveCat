//
//  BrowserViewModel.swift
//  ArchiveCat
//
//  All of the browser's behaviour: navigation, history, sorting, search,
//  selection, preview and extraction. The SwiftUI views are thin on purpose —
//  they render this model and forward intents to it, which keeps the logic
//  testable and the views replaceable.
//

import AppKit
import ArchiveCore
import Observation
import SwiftUI

@MainActor
@Observable
final class BrowserViewModel {

    // MARK: - Types

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// What the extraction sheet is currently doing.
    struct ExtractionState: Equatable {
        var isRunning = false
        var title = ""
        var progress: ExtractionProgress?
        var destination: URL?
        var completedSummary: String?
        /// Where "Show in Finder" should go after a finished extraction.
        var revealURL: URL?
        /// True while a conflict sheet is up and the engine is waiting for the
        /// user, so the progress strip can say so instead of looking stuck.
        var awaitingDecision = false
    }

    // MARK: - Identity

    let archiveURL: URL
    /// The engine session. Shared deliberately: extraction, preview and
    /// drag-and-drop all run through the same session for this archive.
    let session: ArchiveSession

    // MARK: - Observable state

    private(set) var phase: Phase = .loading
    private(set) var document: ArchiveDocument?
    private(set) var tree: ArchiveTree?
    private(set) var scanProgress: ArchiveScanProgress?
    private(set) var rows: [EntryRow] = []
    private(set) var folderRows: [EntryRow] = []
    var currentPath: String = ""
    var selection: Set<String> = []
    var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            rebuildRows()
        }
    }
    var sortSpec: EntrySortSpec = .default {
        didSet {
            guard oldValue != sortSpec else { return }
            rebuildRows()
        }
    }
    var isSidebarVisible = true
    var showsInspector = false
    var showsTechnicalColumns = false
    var extraction = ExtractionState()
    /// Non-blocking message shown in the status area (extraction results, etc).
    private(set) var statusMessage: String?
    /// Set while a Quick Look item is being prepared.
    private(set) var isPreparingPreview = false

    // MARK: - Private state

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var searchIndex: ArchiveSearchIndex?
    private var scanTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    // MARK: - Init

    init(session: ArchiveSession, archiveURL: URL) {
        self.session = session
        self.archiveURL = archiveURL
    }

    // MARK: - Derived state

    var title: String { archiveURL.lastPathComponent }

    var currentDirectoryName: String {
        currentPath.isEmpty ? archiveURL.lastPathComponent : ArchivePath.name(of: currentPath)
    }

    /// The path shown in the window subtitle: `Archive.zip ▸ usr ▸ local`.
    var locationDescription: String {
        guard let tree else { return "" }
        return tree.breadcrumb(to: currentPath).map(\.name).filter { !$0.isEmpty }.joined(separator: " ▸ ")
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !currentPath.isEmpty }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Selected entries, in archive order, with implied folders expanded.
    ///
    /// A folder the archive never stored explicitly still has to behave like a
    /// folder: selecting it selects everything inside it, which is what the
    /// user pointed at.
    var selectedEntries: [ArchiveEntry] {
        guard let document else { return [] }
        var collected: Set<ArchiveEntry> = []

        for row in rows where selection.contains(row.id) {
            if let entry = row.entry {
                collected.insert(entry)
                // An explicit folder also drags its children in, so extraction
                // and drag produce the whole subtree the user sees.
                if entry.isDirectory {
                    let prefix = entry.path + "/"
                    for descendant in document.entries
                    where descendant.safety.isSafe && descendant.path.hasPrefix(prefix) {
                        collected.insert(descendant)
                    }
                }
            } else if let directoryPath = row.directoryPath {
                let prefix = directoryPath + "/"
                for descendant in document.entries
                where descendant.safety.isSafe && descendant.path.hasPrefix(prefix) {
                    collected.insert(descendant)
                }
            }
        }

        return collected.sorted { $0.ordinal < $1.ordinal }
    }

    /// Entries that exist in the archive itself, ignoring implied folders.
    /// Used by Quick Look and Copy Path, which act on real items only.
    var selectedRealEntries: [ArchiveEntry] {
        rows
            .filter { selection.contains($0.id) }
            .compactMap(\.entry)
            .sorted { $0.ordinal < $1.ordinal }
    }

    var primarySelection: ArchiveEntry? { selectedRealEntries.first }

    /// The row the inspector should describe (first selected).
    var inspectedRow: EntryRow? {
        rows.first { selection.contains($0.id) }
    }

    var allSelectableRowIDs: Set<String> { Set(rows.map(\.id)) }

    var itemCountDescription: String {
        guard let document else { return "" }
        let count = document.summary.entryCount
        let files = document.summary.fileCount
        let folders = document.summary.directoryCount
        return "\(count.formatted()) entries • \(files.formatted()) files, \(folders.formatted()) folders"
    }

    var sizeDescription: String {
        guard let summary = document?.summary else { return "" }
        var text = ArchiveCatFormat.byteCount(summary.totalUncompressedSize)
        if summary.totalUncompressedSizeIsPartial { text = "at least " + text }
        return text
    }

    func warnings(ofKind kind: ArchiveWarning.Kind) -> [ArchiveWarning] {
        document?.warnings.filter { $0.kind == kind } ?? []
    }

    // MARK: - Loading

    /// Scans the archive and shows its root.
    func load() {
        scanTask?.cancel()
        phase = .loading
        statusMessage = nil

        let url = archiveURL
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let scanned = try await session.open(url: url, options: .default) { progress in
                    Task { @MainActor [weak self] in
                        self?.scanProgress = progress
                    }
                }
                self.apply(scanned)
            } catch {
                if (error as? ArchiveError)?.isCancellation == true { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    func rescan() {
        guard case .failed = phase else {
            load()
            return
        }
        load()
    }

    private func apply(_ scanned: ArchiveDocument) {
        document = scanned
        tree = scanned.tree
        searchIndex = ArchiveSearchIndex(entries: scanned.entries)
        backStack.removeAll()
        forwardStack.removeAll()
        currentPath = ""
        selection.removeAll()
        scanProgress = nil
        phase = .ready
        rebuildRows()

        ArchiveCatLog.ui.debug(
            "opened \(scanned.fileName, privacy: .public): \(scanned.summary.entryCount, privacy: .public) entries in \(scanned.scanDuration, privacy: .public)s"
        )
    }

    // MARK: - Navigation

    func navigate(to path: String, recordHistory: Bool = true) {
        guard let tree, tree.containsDirectory(at: path) else { return }
        guard path != currentPath || !recordHistory else { return }

        if recordHistory, !currentPath.isEmpty || path.isEmpty == false {
            backStack.append(currentPath)
            forwardStack.removeAll()
        }
        currentPath = path
        selection.removeAll()
        rebuildRows()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        currentPath = previous
        selection.removeAll()
        rebuildRows()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        currentPath = next
        selection.removeAll()
        rebuildRows()
    }

    func goUp() {
        guard let parent = ArchivePath.parent(of: currentPath) else { return }
        navigate(to: parent)
    }

    /// Reveals an entry: navigates into it when it is a directory, and reports
    /// whether it did.
    @discardableResult
    func open(row: EntryRow) -> Bool {
        guard let directoryPath = row.directoryPath else { return false }
        searchText = ""
        navigate(to: directoryPath)
        return true
    }

    func selectAll() {
        selection = allSelectableRowIDs
    }

    func fillSelection(withToBeSelected row: EntryRow) {
        selection = [row.id]
    }

    // MARK: - Search

    /// Entries matching the current query, ranked.
    func searchResults(limit: Int = 1000) -> [ArchiveEntry] {
        guard let searchIndex, isSearching else { return [] }
        return searchIndex.search(searchText, limit: limit).compactMap { index in
            document?.entries[index]
        }
    }

    private func rebuildRows() {
        guard let document, let tree else {
            rows = []
            folderRows = []
            return
        }

        if isSearching {
            rows = searchResults().map { EntryRow(entry: $0, containingPath: ArchivePath.parent(of: $0.path)) }
        } else {
            guard let directory = tree.directory(at: currentPath) else {
                rows = []
                folderRows = []
                return
            }

            var built: [EntryRow] = []
            built.reserveCapacity(directory.childDirectoryPaths.count + directory.childEntryIndices.count)

            // Directories first is handled by `sortName`, but the *listing*
            // follows the archive's own order, exactly like Finder's unsorted
            // listing follows the file system's.
            for childPath in directory.childDirectoryPaths {
                guard let child = tree.directory(at: childPath) else { continue }
                if let entryIndex = child.entryIndex {
                    built.append(EntryRow(entry: document.entries[entryIndex], containingPath: currentPath))
                } else {
                    built.append(EntryRow(directory: child, containingPath: currentPath))
                }
            }
            for entryIndex in directory.childEntryIndices {
                let entry = document.entries[entryIndex]
                // An explicit directory entry is already represented by its
                // directory node above; skip it here so it is not listed twice.
                if entry.isDirectory, tree.containsDirectory(at: entry.path) { continue }
                built.append(EntryRow(entry: entry, containingPath: currentPath))
            }
            rows = built
        }

        // The archive's own order is never mutated: sorting produces a new
        // presentation array, exactly like Finder's list view.
        rows = EntrySortSpec.sorted(rows, by: sortSpec)

        folderRows = ArchiveTree.subdirectories(of: currentPath, in: tree)
            .map { EntryRow(directory: $0, containingPath: nil) }
        // Keep selection consistent with what is on screen.
        let selectable = allSelectableRowIDs
        selection = selection.intersection(selectable)
    }

    // MARK: - Quick Look

    func quickLook() {
        let entries = selectedRealEntries
        guard !entries.isEmpty else { return }
        Task { await QuickLookCoordinator.shared.toggle(entries: entries, session: session, document: document) }
    }

    // MARK: - Extraction

    func extractSelection(to destination: URL, options: ExtractionOptions) {
        extract(entries: selectedEntries, destination: destination, options: options, label: "Extracting")
    }

    func extractEverything(to destination: URL, options: ExtractionOptions) {
        guard let document else { return }
        extract(
            entries: document.entries.filter { $0.safety.isSafe },
            destination: destination,
            options: options,
            label: "Extracting archive"
        )
    }

    func cancelExtraction() {
        extractionTask?.cancel()
    }

    /// Starts an extraction and keeps the task so it can be cancelled.
    func extract(
        entries: [ArchiveEntry],
        destination: URL,
        options: ExtractionOptions,
        label: String
    ) {
        guard !entries.isEmpty, document != nil else { return }
        guard extractionTask == nil else { return }

        extraction = ExtractionState(isRunning: true, title: label, progress: nil, destination: destination)

        extractionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.extractionTask = nil }
            do {
                let report = try await session.extract(
                    entries: entries,
                    to: destination,
                    options: options
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.extraction.progress = progress
                    }
                }
                self.finishExtraction(report)
            } catch {
                self.extraction.isRunning = false
                self.extraction.awaitingDecision = false
                if (error as? ArchiveError)?.isCancellation == true {
                    self.setStatus("Extraction cancelled.")
                    return
                }
                ErrorPresenter.present(error)
            }
        }
    }

    private func finishExtraction(_ report: ExtractionReport) {
        extraction.isRunning = false
        extraction.progress = nil
        extraction.awaitingDecision = false

        var parts: [String] = []
        if report.extractedCount > 0 {
            parts.append("\(report.extractedCount.formatted()) extracted")
        }
        if !report.skipped.isEmpty {
            parts.append("\(report.skipped.count.formatted()) skipped")
        }
        if !report.failures.isEmpty {
            parts.append("\(report.failures.count.formatted()) failed")
        }
        var summary = parts.isEmpty ? "Nothing was extracted." : parts.joined(separator: ", ") + "."
        if report.wasCancelled {
            // Cancelling from a conflict prompt leaves whatever was already
            // written on disk, which the counts above describe.
            summary = "Cancelled. " + summary
        }
        extraction.completedSummary = summary
        // Reveal the item itself when there is exactly one, so the Finder
        // highlights what the user asked for rather than its parent folder.
        extraction.revealURL = report.extracted.count == 1
            ? report.extracted[0].destination
            : report.destination
        setStatus(summary)

        if let failure = report.firstFailure {
            ArchiveCatLog.extraction.error("extraction finished with failures")
            ErrorPresenter.present(failure.error, url: report.destination)
        }
    }

    func dismissExtractionSummary() {
        extraction.completedSummary = nil
        extraction.revealURL = nil
    }

    /// Empties the preview cache this document has been using.
    func clearPreviewCache() {
        Task { [session] in
            await session.purgePreviewCache()
            setStatus("Preview cache cleared.")
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Clipboard

    func copyPathsOfSelection() {
        let entries = selectedRealEntries
        guard !entries.isEmpty else { return }
        let text = entries.map { entry -> String in
            // The full path inside the archive, including the archive name, is
            // the most useful thing to paste into a shell or a bug report.
            "\(archiveURL.lastPathComponent) ▸ \(entry.path)"
        }.joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        setStatus(entries.count == 1 ? "Path copied." : "\(entries.count) paths copied.")
    }

    // MARK: - Status

    func setStatus(_ message: String?) {
        statusMessage = message
        statusClearTask?.cancel()
        guard message != nil else { return }
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    // MARK: - Helpers

    private static func message(for error: Error) -> String {
        if let archiveError = error as? ArchiveError {
            var text = archiveError.headline
            if let suggestion = archiveError.recoverySuggestion {
                text += " " + suggestion
            }
            return text
        }
        return error.localizedDescription
    }
}

extension ArchiveTree {
    /// Immediate subdirectories of `path`.
    static func subdirectories(of path: String, in tree: ArchiveTree) -> [ArchiveDirectory] {
        guard let directory = tree.directory(at: path) else { return [] }
        return directory.childDirectoryPaths.compactMap { tree.directory(at: $0) }
    }
}
