//
//  MainMenuBuilder.swift
//  ArchiveCat
//
//  The application menu bar, built in code.
//
//  Why not a nib? Because the menu is part of the product's behaviour: the
//  keyboard contract in the brief (⌘O, ⌘F, Space, ⌘I, ⌘A, ⌘←, ⌘→, Return) has
//  to be exact, and a 300-line source file is easier to review and diff than a
//  binary nib. Every item uses the standard selector for its job so the
//  responder chain, validation and any future system integration behave like
//  they do in Finder.
//
//  Items whose `target` is nil are dispatched down the responder chain to the
//  frontmost window's content view controller (`BrowserViewController`).
//

import AppKit

/// Selectors ArchiveCat adds on top of AppKit's own.
///
/// Declared as an `@objc` protocol so `#selector` can reference them without
/// the menu builder needing to know which object implements them.
@MainActor
@objc protocol ArchiveCatMenuActions: AnyObject {
    /// Space / ⌘Y — preview the selection with Quick Look.
    func quickLookSelection(_ sender: Any?)
    /// ⌘I — show or hide the inspector.
    func toggleInspector(_ sender: Any?)
    /// ⌘↑ — go to the enclosing folder.
    func goToEnclosingFolder(_ sender: Any?)
    /// ⌘← — back in the navigation history.
    func navigateBack(_ sender: Any?)
    /// ⌘→ — forward in the navigation history.
    func navigateForward(_ sender: Any?)
    /// Return — open the selected directory, or preview the selected file.
    func openSelectedEntry(_ sender: Any?)
    /// ⇧⌘E — extract the selection…
    func extractSelection(_ sender: Any?)
    /// ⌥⌘E — extract the selection straight to ~/Downloads.
    func extractSelectionToDownloads(_ sender: Any?)
    /// ⇧⌘A — extract every entry in the archive…
    func extractEntireArchive(_ sender: Any?)
    /// ⌥⌘C — copy the selected entries' archive paths.
    func copyEntryPaths(_ sender: Any?)
    /// ⌘F — focus the search field.
    func focusSearchField(_ sender: Any?)
    /// ⌘R — rescan the archive.
    func rescanArchive(_ sender: Any?)
    /// Help ▸ ArchiveCat Help.
    func showHelp(_ sender: Any?)
    /// ⌃⌘S — show or hide the folder list.
    func toggleSidebar(_ sender: Any?)
    /// Application menu — empty the preview cache.
    func clearPreviewCache(_ sender: Any?)
}

@MainActor
enum MainMenuBuilder {

    /// Builds and installs the main menu.
    static func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenu())
        mainMenu.addItem(fileMenu())
        mainMenu.addItem(editMenu())
        mainMenu.addItem(viewMenu())
        mainMenu.addItem(goMenu())
        mainMenu.addItem(windowMenu())
        mainMenu.addItem(helpMenu())

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Menus

    private static func applicationMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "ArchiveCat")

        menu.addItem(withTitle: "About ArchiveCat",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Clear Preview Cache",
                     action: #selector(ArchiveCatMenuActions.clearPreviewCache(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        NSApplication.shared.servicesMenu = servicesMenu

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide ArchiveCat",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")

        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ArchiveCat",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    private static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        menu.addItem(withTitle: "Open…",
                     action: #selector(NSDocumentController.openDocument(_:)),
                     keyEquivalent: "o")

        // NSDocumentController finds this submenu by its title and keeps it
        // populated, which is why the title has to be exactly "Open Recent".
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        let clearItem = recentMenu.addItem(withTitle: "Clear Menu",
                                           action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                                           keyEquivalent: "")
        clearItem.target = NSDocumentController.shared
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")

        menu.addItem(.separator())

        // Extraction is deliberately in the File menu, where "do something with
        // this document" commands live. Nothing here modifies the archive.
        menu.addItem(withTitle: "Extract…",
                     action: #selector(ArchiveCatMenuActions.extractSelection(_:)),
                     keyEquivalent: "e",
                     modifiers: [.command, .shift])

        menu.addItem(withTitle: "Extract to Downloads",
                     action: #selector(ArchiveCatMenuActions.extractSelectionToDownloads(_:)),
                     keyEquivalent: "e",
                     modifiers: [.command, .option])

        menu.addItem(withTitle: "Extract Archive…",
                     action: #selector(ArchiveCatMenuActions.extractEntireArchive(_:)),
                     keyEquivalent: "e",
                     modifiers: [.command, .shift, .option])

        item.submenu = menu
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")

        menu.addItem(withTitle: "Copy Path",
                     action: #selector(ArchiveCatMenuActions.copyEntryPaths(_:)),
                     keyEquivalent: "c",
                     modifiers: [.command, .option])

        menu.addItem(.separator())

        menu.addItem(withTitle: "Select All",
                     action: Selector(("selectAll:")),
                     keyEquivalent: "a")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Find…",
                     action: #selector(ArchiveCatMenuActions.focusSearchField(_:)),
                     keyEquivalent: "f")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Refresh",
                     action: #selector(ArchiveCatMenuActions.rescanArchive(_:)),
                     keyEquivalent: "r")

        item.submenu = menu
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        menu.addItem(withTitle: "Show/Hide Sidebar",
                     action: #selector(ArchiveCatMenuActions.toggleSidebar(_:)),
                     keyEquivalent: "s",
                     modifiers: [.command, .control])

        menu.addItem(withTitle: "Show/Hide Inspector",
                     action: #selector(ArchiveCatMenuActions.toggleInspector(_:)),
                     keyEquivalent: "i")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Quick Look",
                     action: #selector(ArchiveCatMenuActions.quickLookSelection(_:)),
                     keyEquivalent: "y")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Sort by Name",
                     action: #selector(BrowserSortActions.sortByName(_:)),
                     keyEquivalent: "1",
                     modifiers: [.command, .control])
        menu.addItem(withTitle: "Sort by Size",
                     action: #selector(BrowserSortActions.sortBySize(_:)),
                     keyEquivalent: "2",
                     modifiers: [.command, .control])
        menu.addItem(withTitle: "Sort by Kind",
                     action: #selector(BrowserSortActions.sortByKind(_:)),
                     keyEquivalent: "3",
                     modifiers: [.command, .control])
        menu.addItem(withTitle: "Sort by Date Modified",
                     action: #selector(BrowserSortActions.sortByDateModified(_:)),
                     keyEquivalent: "4",
                     modifiers: [.command, .control])

        item.submenu = menu
        return item
    }

    private static func goMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Go")

        menu.addItem(withTitle: "Back",
                     action: #selector(ArchiveCatMenuActions.navigateBack(_:)),
                     keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                     modifiers: [.command])

        menu.addItem(withTitle: "Forward",
                     action: #selector(ArchiveCatMenuActions.navigateForward(_:)),
                     keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                     modifiers: [.command])

        menu.addItem(withTitle: "Enclosing Folder",
                     action: #selector(ArchiveCatMenuActions.goToEnclosingFolder(_:)),
                     keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                     modifiers: [.command])

        menu.addItem(.separator())

        menu.addItem(withTitle: "Open",
                     action: #selector(ArchiveCatMenuActions.openSelectedEntry(_:)),
                     keyEquivalent: "\r")

        item.submenu = menu
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")

        item.submenu = menu
        NSApplication.shared.windowsMenu = menu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "ArchiveCat Help",
                     action: #selector(ArchiveCatMenuActions.showHelp(_:)),
                     keyEquivalent: "?")
        item.submenu = menu
        NSApplication.shared.helpMenu = menu
        return item
    }
}

/// A second small protocol so the View ▸ Sort menu can be wired without the
/// menu builder importing the browser.
@MainActor
@objc protocol BrowserSortActions: AnyObject {
    func sortByName(_ sender: Any?)
    func sortBySize(_ sender: Any?)
    func sortByKind(_ sender: Any?)
    func sortByDateModified(_ sender: Any?)
}

private extension NSMenu {
    /// Adds an item with an explicit modifier mask, which the convenience
    /// initialiser cannot express.
    @discardableResult
    func addItem(
        withTitle title: String,
        action: Selector?,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
