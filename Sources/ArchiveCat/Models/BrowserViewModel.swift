//
//  BrowserViewModel.swift
//  ArchiveCat
//
//  All of the browser's behaviour: navigation, archive levels, history, sorting,
//  search, selection, preview and extraction. The SwiftUI views are thin on
//  purpose — they render this model and forward intents to it, which keeps the
//  logic testable and the views replaceable.
//
//  Archive levels
//  --------------
//  The window always belongs to one document (the archive the user opened), but
//  the browser can be *inside* a nested archive. That stack of archives lives
//  here as `levels`: `levels[0]` is the document itself, and each further level
//  is an archive materialised from a member of the one below it. Each level owns
//  its own session, scanned document and per-archive navigation history, so
//  going Back inside a nested tarball does not disturb the parent's position.
//
//  Dropping a level releases its pin in the nested-archive cache; the document
//  (and therefore the user's archive file) is never modified.
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

    /// One archive in the navigation stack.
    struct Level: Identifiable {
        let id = UUID()
        let session: ArchiveSession
        let document: ArchiveDocument
        /// Name shown in the breadcrumb: the root archive's file name, then the
        /// nested member's name.
        let displayName: String
        /// Nested-cache pin to release when this level goes away. `nil` for the
        /// document's own archive, which is not materialised.
        let cacheKey: String?

        /// Position inside this archive, remembered while a nested level is
        /// open so popping back returns the user to where they were.
        var currentPath: String = ""
        var backStack: [String] = []
        var forwardStack: [String] = []
    }

    /// A failure opening a nested archive, for the view layer to present.
    ///
    /// The model deliberately does not put up an alert itself: presenting UI was
    /// making the model unusable outside a running app (and the alert is modal,
    /// so it would block whatever triggered it).
    struct NestedFailure: Identifiable {
        let id = UUID()
        let error: ArchiveError
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

    /// The archive the document was opened with. It stays the window's identity
    /// even while a nested archive is on screen.
    let archiveURL: URL
    private let nestedStore: NestedArchiveStore?

    /// The document's own session. Kept separately so it can outlive a level
    /// rebuild and so `load()` always has a target.
    private let rootSession: ArchiveSession

    // MARK: - Observable state

    private(set) var phase: Phase = .loading
    private(set) var levels: [Level] = []
    private(set) var currentLevelIndex = 0
    private(set) var scanProgress: ArchiveScanProgress?
    private(set) var rows: [EntryRow] = []
    private(set) var folderRows: [EntryRow] = []
    private(set) var isOpeningNestedArchive = false
    /// Message describing the last nested-open failure (also shown as status).
    private(set) var nestedArchiveError: String?
    /// The failure itself, for the view to present with a real error sheet.
    private(set) var nestedArchiveFailure: NestedFailure?
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

    private var searchIndex: ArchiveSearchIndex?
    private var scanTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?
    private var nestedTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    // MARK: - Init

    init(session: ArchiveSession, archiveURL: URL, nestedStore: NestedArchiveStore? = nil) {
        self.rootSession = session
        self.archiveURL = archiveURL
        self.nestedStore = nestedStore
    }

    // MARK: - Current level

    /// The archive currently being browsed (the root, or a nested one).
    var currentLevel: Level? {
        guard levels.indices.contains(currentLevelIndex) else { return nil }
        return levels[currentLevelIndex]
    }

    var document: ArchiveDocument? { currentLevel?.document }
    var tree: ArchiveTree? { currentLevel?.document.tree }
    var session: ArchiveSession { currentLevel?.session ?? rootSession }

    /// Name of the archive currently on screen, which is not the document's name
    /// when a nested archive is open.
    var currentArchiveName: String { currentLevel?.displayName ?? archiveURL.lastPathComponent }

    /// The chain of archives, root first: `project.zip`, `backup.tar.gz`.
    var archiveChain: [Level] { levels }

    var isInsideNestedArchive: Bool { currentLevelIndex > 0 }

    // MARK: - Derived state

    var title: String { archiveURL.lastPathComponent }

    var currentDirectoryName: String {
        currentPath.isEmpty ? currentArchiveName : ArchivePath.name(of: currentPath)
    }

    /// The location shown in the window subtitle.
    ///
    /// The window title is already the document's archive name, so the root
    /// archive is not repeated here. Nested archives are, because the title does
    /// not mention them: `backup.tar.gz ▸ database` means "the backup archive
    /// inside this document, in its database folder".
    var locationDescription: String {
        guard let tree else { return "" }
        let nestedArchiveNames = levels.dropFirst().map(\.displayName)
        let directories = tree.breadcrumb(to: currentPath)
            .map(\.name)
            .filter { !$0.isEmpty }
        return (nestedArchiveNames + directories).joined(separator: " ▸ ")
    }

    var canGoBack: Bool {
        if currentLevel?.backStack.isEmpty == false { return true }
        return currentLevelIndex > 0
    }

    var canGoForward: Bool { currentLevel?.forwardStack.isEmpty == false }

    var canGoUp: Bool { !currentPath.isEmpty || currentLevelIndex > 0 }

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

    // MARK: - Nested archive affordance

    /// Whether a file row can be opened as an archive.
    ///
    /// The name only decides whether the command is *offered*; opening validates
    /// the real bytes by scanning them, so a misnamed file fails with a normal
    /// error rather than being trusted.
    func canOpenAsNestedArchive(_ row: EntryRow) -> Bool {
        guard let entry = row.entry, entry.isRegularFile else { return false }
        return ArchiveFormatCatalog.isArchiveCandidate(fileName: entry.name)
    }

    var canOpenSelectedNestedArchive: Bool {
        guard selection.count == 1, let entry = primarySelection else { return false }
        return entry.isRegularFile && ArchiveFormatCatalog.isArchiveCandidate(fileName: entry.name)
    }

    // MARK: - Loading

    /// Scans the document's archive and shows its root.
    func load() {
        scanTask?.cancel()
        phase = .loading
        statusMessage = nil
        nestedArchiveError = nil

        let url = archiveURL
        let rootURL = archiveURL
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let scanned = try await rootSession.open(url: url, options: .default) { progress in
                    Task { @MainActor [weak self] in
                        self?.scanProgress = progress
                    }
                }
                self.apply(scanned, rootURL: rootURL)
            } catch {
                if (error as? ArchiveError)?.isCancellation == true { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    func rescan() {
        // A rescan re-reads the document's archive; nested levels are discarded
        // because their parent may have changed underneath them.
        releaseNestedLevels()
        load()
    }

    private func apply(_ scanned: ArchiveDocument, rootURL: URL) {
        nestedArchiveFailure = nil
        let level = Level(
            session: rootSession,
            document: scanned,
            displayName: rootURL.lastPathComponent,
            cacheKey: nil
        )
        levels = [level]
        currentLevelIndex = 0
        searchIndex = ArchiveSearchIndex(entries: scanned.entries)
        currentPath = ""
        selection.removeAll()
        scanProgress = nil
        nestedArchiveError = nil
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

        if recordHistory, levels.indices.contains(currentLevelIndex) {
            levels[currentLevelIndex].backStack.append(currentPath)
            levels[currentLevelIndex].forwardStack.removeAll()
        }
        currentPath = path
        selection.removeAll()
        rebuildRows()
    }

    func goBack() {
        if levels.indices.contains(currentLevelIndex), !levels[currentLevelIndex].backStack.isEmpty {
            let previous = levels[currentLevelIndex].backStack.removeLast()
            levels[currentLevelIndex].forwardStack.append(currentPath)
            currentPath = previous
            selection.removeAll()
            rebuildRows()
            return
        }
        // Nothing left inside this archive: step out of the nested archive.
        popLevel()
    }

    func goForward() {
        guard levels.indices.contains(currentLevelIndex),
              !levels[currentLevelIndex].forwardStack.isEmpty
        else { return }
        let next = levels[currentLevelIndex].forwardStack.removeLast()
        levels[currentLevelIndex].backStack.append(currentPath)
        currentPath = next
        selection.removeAll()
        rebuildRows()
    }

    func goUp() {
        if !currentPath.isEmpty, let parent = ArchivePath.parent(of: currentPath) {
            navigate(to: parent)
            return
        }
        popLevel()
    }

    /// Reveals an entry: navigates into a folder, or into a nested archive.
    ///
    /// - Returns: whether the entry could be opened.
    @discardableResult
    func open(row: EntryRow) -> Bool {
        if let directoryPath = row.directoryPath {
            searchText = ""
            navigate(to: directoryPath)
            return true
        }
        if canOpenAsNestedArchive(row), let entry = row.entry {
            openNestedArchive(entry)
            return true
        }
        return false
    }

    func selectAll() {
        selection = allSelectableRowIDs
    }

    func fillSelection(withToBeSelected row: EntryRow) {
        selection = [row.id]
    }

    // MARK: - Nested archives

    /// Opens `entry` as its own archive level.
    func openNestedArchive(_ entry: ArchiveEntry) {
        guard nestedTask == nil, !isOpeningNestedArchive else { return }
        guard let level = currentLevel else { return }

        guard let nestedStore else {
            setStatus("Archives inside archives are unavailable right now.")
            return
        }

        isOpeningNestedArchive = true
        nestedArchiveError = nil
        nestedArchiveFailure = nil
        setStatus("Opening “\(entry.name)”…")

        let depth = currentLevelIndex
        let parentDocument = level.document
        let parentSession = level.session

        nestedTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isOpeningNestedArchive = false
                self.nestedTask = nil
            }
            do {
                let opened = try await nestedStore.open(
                    entry: entry,
                    document: parentDocument,
                    session: parentSession,
                    depth: depth
                )
                // Remember where the parent was, then push the new level.
                guard self.currentLevelIndex < self.levels.count else { return }
                self.levels[self.currentLevelIndex].currentPath = self.currentPath
                self.levels.append(Level(
                    session: opened.session,
                    document: opened.document,
                    displayName: entry.name,
                    cacheKey: opened.cacheKey
                ))
                self.currentLevelIndex = self.levels.count - 1
                self.currentPath = ""
                self.selection.removeAll()
                self.searchText = ""
                self.searchIndex = ArchiveSearchIndex(entries: opened.document.entries)
                self.rebuildRows()
                self.setStatus("Opened “\(entry.name)”.")
            } catch {
                guard (error as? ArchiveError)?.isCancellation != true else { return }
                let archiveError = (error as? ArchiveError)
                    ?? ArchiveError.underlying(reason: error.localizedDescription, technicalDetails: nil)
                self.nestedArchiveError = Self.message(for: error)
                self.nestedArchiveFailure = NestedFailure(error: archiveError)
                self.setStatus("“\(entry.name)” could not be opened.")
            }
        }
    }

    /// Opens the single selected entry as a nested archive (menu/context menu).
    func openSelectedNestedArchive() {
        guard let entry = primarySelection else { return }
        guard ArchiveFormatCatalog.isArchiveCandidate(fileName: entry.name) else { return }
        openNestedArchive(entry)
    }

    /// Goes back to the archive at `index` in the chain, closing levels above it.
    func popToLevel(_ index: Int) {
        guard index >= 0, index < levels.count, index < currentLevelIndex else { return }
        while currentLevelIndex > index {
            let removed = levels.removeLast()
            releaseLevel(removed)
            currentLevelIndex = levels.count - 1
        }
        let restored = levels[currentLevelIndex]
        currentPath = restored.currentPath
        selection.removeAll()
        searchIndex = ArchiveSearchIndex(entries: restored.document.entries)
        rebuildRows()
    }

    /// Steps out of the current nested archive.
    func popLevel() {
        guard currentLevelIndex > 0 else { return }
        popToLevel(currentLevelIndex - 1)
    }

    /// Drops every nested level, releasing their cache pins.
    private func releaseNestedLevels() {
        guard currentLevelIndex > 0 else { return }
        for level in levels[(currentLevelIndex + 1)...] {
            releaseLevel(level)
        }
        levels.removeSubrange((currentLevelIndex + 1)...)
    }

    private func releaseLevel(_ level: Level) {
        guard let cacheKey = level.cacheKey, let nestedStore else { return }
        Task {
            await nestedStore.release(cacheKey: cacheKey)
        }
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
        } else if tree.directory(at: currentPath) != nil {
            // Directory enumeration goes through the virtual filesystem, so the
            // browser and the engine cannot disagree about what a directory
            // contains.
            let fileSystem = ArchiveFileSystem(document: document)
            var built: [EntryRow] = []
            for node in fileSystem.children(ofDirectoryAt: currentPath) {
                if let entry = node.entry, !entry.isDirectory {
                    built.append(EntryRow(entry: entry, containingPath: currentPath))
                } else if let directory = node.directory {
                    // Directories (explicit or implied) are represented by their
                    // directory node, exactly as the filesystem lists them.
                    built.append(EntryRow(directory: directory, containingPath: currentPath))
                } else if let entry = node.entry {
                    built.append(EntryRow(entry: entry, containingPath: currentPath))
                }
            }
            rows = built
        } else {
            rows = []
            folderRows = []
            return
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
        let session = self.session
        let document = self.document
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

        // Bind the extraction to the level it started from, so navigating into a
        // nested archive mid-extraction cannot change what is being read.
        let session = self.session

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

    /// Empties the preview cache the current session has been using.
    func clearPreviewCache() {
        let session = self.session
        Task { [weak self] in
            await session.purgePreviewCache()
            self?.setStatus("Preview cache cleared.")
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Clipboard

    func copyPathsOfSelection() {
        let entries = selectedRealEntries
        guard !entries.isEmpty else { return }
        // The whole location — every archive in the chain plus the path inside
        // the innermost one — is the useful thing to paste elsewhere.
        let chain = levels.map(\.displayName).joined(separator: " ▸ ")
        let text = entries.map { entry -> String in
            "\(chain) ▸ \(entry.path)"
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
