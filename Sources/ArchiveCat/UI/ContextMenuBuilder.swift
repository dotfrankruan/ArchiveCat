//
//  ContextMenuBuilder.swift
//  ArchiveCat
//
//  The right-click menu for archive entries.
//
//  Every item uses a standard action and a `nil` target, so it travels the same
//  responder chain as the menu bar: one implementation, one validation path,
//  and the same behaviour whether the user reaches a command from the menu, the
//  toolbar or a right-click.
//
//  There are intentionally no archive-editing items: v1 cannot rename, delete
//  or add entries, and a disabled "Delete" would only be a tease.
//

import AppKit
import ArchiveCore

@MainActor
enum ContextMenuBuilder {

    static func menu(forRowIDs rowIDs: Set<String>, rows: [EntryRow]) -> NSMenu? {
        let selected = rows.filter { rowIDs.contains($0.id) }
        guard !selected.isEmpty else { return nil }

        let menu = NSMenu()
        let containsDirectory = selected.contains { $0.isDirectory }
        let containsFile = selected.contains { !$0.isDirectory }
        let multiple = selected.count > 1

        if containsDirectory, !multiple {
            menu.addItem(item("Open", #selector(ArchiveCatMenuActions.openSelectedEntry(_:))))
        }
        if containsFile {
            menu.addItem(item("Quick Look", #selector(ArchiveCatMenuActions.quickLookSelection(_:))))
        }

        if containsFile || containsDirectory {
            menu.addItem(.separator())
        }

        menu.addItem(item("Extract…", #selector(ArchiveCatMenuActions.extractSelection(_:))))
        menu.addItem(item("Extract to Downloads", #selector(ArchiveCatMenuActions.extractSelectionToDownloads(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Copy Path", #selector(ArchiveCatMenuActions.copyEntryPaths(_:))))
        menu.addItem(item("Show Info", #selector(ArchiveCatMenuActions.toggleInspector(_:))))

        return menu
    }

    private static func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        // `nil` target: the action travels the responder chain to the window
        // controller, exactly like the menu bar equivalent.
        item.target = nil
        return item
    }
}
