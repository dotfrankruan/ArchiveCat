//
//  ArchiveDocumentWindowController.swift
//  ArchiveCat
//
//  One window per archive: the native toolbar, the responder-chain home for
//  every ArchiveCat command, and the Quick Look panel's host.
//
//  The toolbar is a real `NSToolbar` (the same control Finder uses) rather than
//  a SwiftUI `.toolbar`, because this window is hosted from AppKit and because
//  the search field needs to be an `NSSearchField` that keeps focus behaviour
//  identical to every other Mac app.
//

import AppKit
import ArchiveCore
import Observation
import QuickLookUI
import SwiftUI

final class ArchiveDocumentWindowController: NSWindowController {

    private let archiveDocument: ArchiveDocumentFile
    let model: BrowserViewModel

    /// Versioned so that a change to the default geometry is not defeated by a
    /// frame saved by an older build.
    private static let windowFrameAutosaveName = "ArchiveCatBrowserWindowV1"

    /// Versioned for the same reason as the frame autosave name: a toolbar
    /// configuration saved by an older build (one whose window was too narrow
    /// to show every item) must not be restored over the current defaults.
    private static let toolbarIdentifier = "ArchiveCatBrowserToolbarV1"

    /// The browser toolbar, kept so it can be re-installed if something else
    /// claims the window's toolbar. See `installToolbarIfNeeded()`.
    private var browserToolbar: NSToolbar?

    private var searchField: NSSearchField?
    private var backForwardControl: NSSegmentedControl?
    private var observationTask: Task<Void, Never>?

    init(document: ArchiveDocumentFile) {
        self.archiveDocument = document
        self.model = BrowserViewModel(session: document.session, archiveURL: document.archiveURL)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = document.archiveURL.lastPathComponent
        window.minSize = NSSize(width: 640, height: 380)
        window.titlebarAppearsTransparent = false
        // `.automatic` rather than `.preferred`: each archive gets its own
        // window, as the brief asks, and users who want several archives in one
        // window can still use Window > Merge All Windows. `.preferred` would
        // put a tab rail next to every single-archive window.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "ArchiveCatDocument"
        window.isRestorable = true

        super.init(window: window)

        document.browser = model

        let hosting = NSHostingController(rootView: BrowserView(model: model))
        window.contentViewController = hosting

        // `BrowserView` declares the window's ideal size; all that is left here
        // is to stop AppKit from shrinking below a usable browser and to let the
        // user's own frame win on later launches.
        window.contentMinSize = NSSize(width: 640, height: 380)
        if !window.setFrameUsingName(Self.windowFrameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.windowFrameAutosaveName)

        configureToolbar()
        observeModel()

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ArchiveDocumentWindowController is created in code only")
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Lifecycle

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.setFrameAutosaveName(Self.windowFrameAutosaveName)
    }

    /// Keeps the title, subtitle and toolbar state in step with the model.
    ///
    /// `withObservationTracking` re-arms itself after every change, which is
    /// the supported way to bridge `@Observable` into AppKit.
    private func observeModel() {
        withObservationTracking { [weak self] in
            guard let self, let window else { return }
            installToolbarIfNeeded()
            window.title = model.title
            window.subtitle = model.locationDescription.isEmpty
                ? (model.document?.summary.formatDescription ?? "")
                : model.locationDescription
            window.isDocumentEdited = false
            backForwardControl?.setEnabled(model.canGoBack, forSegment: 0)
            backForwardControl?.setEnabled(model.canGoForward, forSegment: 1)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeModel()
            }
        }
    }

    // MARK: - Toolbar

    private static let searchItem = NSToolbarItem.Identifier("ArchiveCat.search")
    private static let navigationItem = NSToolbarItem.Identifier("ArchiveCat.navigation")
    private static let quickLookItem = NSToolbarItem.Identifier("ArchiveCat.quickLook")
    private static let extractItem = NSToolbarItem.Identifier("ArchiveCat.extract")

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        browserToolbar = toolbar
        installToolbarIfNeeded()
        window?.toolbarStyle = .unified
    }

    /// Puts the browser toolbar back if SwiftUI has replaced it.
    ///
    /// `NavigationSplitView` is hosted inside this AppKit window, and on macOS
    /// it claims the window's toolbar to install its own sidebar toggle. Left
    /// alone that silently removes every toolbar item ArchiveCat defines. This
    /// is called after the window is on screen, which is when SwiftUI has
    /// finished its setup.
    private func installToolbarIfNeeded() {
        guard let window, let browserToolbar else { return }
        guard window.toolbar !== browserToolbar else { return }
        window.toolbar = browserToolbar
        window.toolbarStyle = .unified
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        installToolbarIfNeeded()
    }

    // MARK: - Actions

    @objc private func goBack(_ sender: Any?) { model.goBack() }
    @objc private func goForward(_ sender: Any?) { model.goForward() }
    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        model.searchText = sender.stringValue
    }
    @objc private func quickLookClicked(_ sender: Any?) { model.quickLook() }
    @objc private func extractClicked(_ sender: Any?) {
        ExtractionCoordinator.extractSelection(from: model, window: window)
    }
}

// MARK: - Toolbar delegate

extension ArchiveDocumentWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Deliberately no sidebar or inspector item: SwiftUI's
        // `NavigationSplitView` and `.inspector` already draw their own toggles
        // exactly where macOS puts them, and adding ours alongside showed two
        // identical buttons for each. ⌘I and Entry ▸ Show Info still reach the
        // inspector through the model, and ⌃⌘S toggles the sidebar.
        //
        // QL, Extract and Inspector items are marked navigational, which puts
        // them in the leading group next to back/forward, leaving the search
        // field at the trailing edge — the Finder's arrangement.
        [
            Self.navigationItem,
            .flexibleSpace,
            Self.quickLookItem,
            Self.extractItem,
            Self.searchItem,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // `.toggleSidebar` stays available so a user customising the toolbar can
        // still add the system item.
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .toggleSidebar, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.navigationItem:
            let control = NSSegmentedControl()
            control.segmentCount = 2
            control.segmentStyle = .separated
            control.trackingMode = .momentary
            control.setImage(NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back"), forSegment: 0)
            control.setImage(NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward"), forSegment: 1)
            control.setWidth(32, forSegment: 0)
            control.setWidth(32, forSegment: 1)
            control.setEnabled(model.canGoBack, forSegment: 0)
            control.setEnabled(model.canGoForward, forSegment: 1)
            control.target = self
            control.action = #selector(navigationSegmentChanged(_:))
            control.segmentCount = 2

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Back/Forward"
            item.paletteLabel = "Back/Forward"
            item.view = control
            item.isNavigational = true
            item.minSize = control.fittingSize
            item.maxSize = control.fittingSize
            backForwardControl = control
            return item

        case Self.searchItem:
            let field = NSSearchField()
            field.placeholderString = "Search archive"
            field.sendsWholeSearchString = false
            field.sendsSearchStringImmediately = true
            field.target = self
            field.action = #selector(searchFieldChanged(_:))
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.paletteLabel = "Search"
            item.toolTip = "Search file names and paths in this archive (⌘F)"
            item.view = field
            item.minSize = NSSize(width: 180, height: field.fittingSize.height)
            item.maxSize = NSSize(width: 340, height: field.fittingSize.height)
            searchField = field
            return item

        case Self.quickLookItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Quick Look"
            item.paletteLabel = "Quick Look"
            item.toolTip = "Preview the selected items (Space)"
            item.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Quick Look")
            item.target = self
            item.action = #selector(quickLookClicked(_:))
            item.isNavigational = true
            return item

        case Self.extractItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Extract"
            item.paletteLabel = "Extract"
            item.toolTip = "Extract the selected items (⇧⌘E)"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Extract")
            item.target = self
            item.action = #selector(extractClicked(_:))
            item.isNavigational = true
            return item

        default:
            return nil
        }
    }

    @objc private func navigationSegmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: model.goBack()
        case 1: model.goForward()
        default: break
        }
    }
}

// MARK: - Quick Look panel hosting

extension ArchiveDocumentWindowController {

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookCoordinator.shared
        panel.delegate = QuickLookCoordinator.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

// MARK: - Menu commands

extension ArchiveDocumentWindowController: ArchiveCatMenuActions, BrowserSortActions {

    func quickLookSelection(_ sender: Any?) {
        model.quickLook()
    }

    func toggleInspector(_ sender: Any?) {
        model.showsInspector.toggle()
    }

    func goToEnclosingFolder(_ sender: Any?) {
        model.goUp()
    }

    func navigateBack(_ sender: Any?) {
        model.goBack()
    }

    func navigateForward(_ sender: Any?) {
        model.goForward()
    }

    func openSelectedEntry(_ sender: Any?) {
        let selected = model.rows.filter { model.selection.contains($0.id) }
        guard let first = selected.first else { return }
        if selected.count == 1, model.open(row: first) { return }
        model.quickLook()
    }

    func extractSelection(_ sender: Any?) {
        ExtractionCoordinator.extractSelection(from: model, window: window)
    }

    func extractSelectionToDownloads(_ sender: Any?) {
        ExtractionCoordinator.extractSelectionToDownloads(from: model, window: window)
    }

    func extractEntireArchive(_ sender: Any?) {
        ExtractionCoordinator.extractEntireArchive(from: model, window: window)
    }

    func copyEntryPaths(_ sender: Any?) {
        model.copyPathsOfSelection()
    }

    func focusSearchField(_ sender: Any?) {
        guard let searchField else { return }
        window?.makeFirstResponder(searchField)
    }

    func rescanArchive(_ sender: Any?) {
        model.searchText = ""
        model.load()
    }

    func clearPreviewCache(_ sender: Any?) {
        model.clearPreviewCache()
    }

    func showHelp(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/dotfrankruan/ArchiveCat") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Sidebar

    func toggleSidebar(_ sender: Any?) {
        model.isSidebarVisible.toggle()
    }

    // MARK: Sorting

    func sortByName(_ sender: Any?) { applySort(.name) }
    func sortBySize(_ sender: Any?) { applySort(.size) }
    func sortByKind(_ sender: Any?) { applySort(.kind) }
    func sortByDateModified(_ sender: Any?) { applySort(.modified) }

    /// Re-selecting the same column flips the direction, like clicking a header.
    private func applySort(_ column: EntrySortColumn) {
        if model.sortSpec.column == column {
            model.sortSpec.ascending.toggle()
        } else {
            model.sortSpec = EntrySortSpec(column: column, ascending: true)
        }
    }
}

// MARK: - Menu validation

extension ArchiveDocumentWindowController: NSMenuItemValidation {

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasDocument = model.document != nil
        let hasSelection = !model.selection.isEmpty
        let hasEntries = !model.rows.isEmpty

        switch menuItem.action {
        case #selector(quickLookSelection(_:)):
            return hasSelection
        case #selector(openSelectedEntry(_:)):
            return hasSelection
        case #selector(extractSelection(_:)), #selector(extractSelectionToDownloads(_:)):
            return hasSelection && !model.extraction.isRunning
        case #selector(extractEntireArchive(_:)):
            return hasDocument && !model.extraction.isRunning
        case #selector(copyEntryPaths(_:)):
            return hasSelection
        case #selector(navigateBack(_:)):
            return model.canGoBack
        case #selector(navigateForward(_:)):
            return model.canGoForward
        case #selector(goToEnclosingFolder(_:)):
            return model.canGoUp
        case #selector(focusSearchField(_:)), #selector(rescanArchive(_:)):
            return hasDocument
        case #selector(sortByName(_:)):
            menuItem.state = model.sortSpec.column == .name ? .on : .off
            return hasEntries
        case #selector(sortBySize(_:)):
            menuItem.state = model.sortSpec.column == .size ? .on : .off
            return hasEntries
        case #selector(sortByKind(_:)):
            menuItem.state = model.sortSpec.column == .kind ? .on : .off
            return hasEntries
        case #selector(sortByDateModified(_:)):
            menuItem.state = model.sortSpec.column == .modified ? .on : .off
            return hasEntries
        case #selector(toggleInspector(_:)):
            menuItem.state = model.showsInspector ? .on : .off
            return hasDocument
        case #selector(toggleSidebar(_:)):
            menuItem.state = model.isSidebarVisible ? .on : .off
            return hasDocument
        default:
            return true
        }
    }
}
