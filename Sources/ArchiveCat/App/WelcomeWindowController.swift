//
//  WelcomeWindowController.swift
//  ArchiveCat
//
//  The window shown when ArchiveCat is launched with nothing to open, and when
//  the Dock icon is clicked with no documents open.
//
//  One sentence, one button, and a drop target. No wizard, no recent-file grid,
//  no marketing copy.
//

import AppKit
import ArchiveCore
import SwiftUI

@MainActor
final class WelcomeWindowController: NSWindowController {

    static let shared = WelcomeWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ArchiveCat"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)

        let view = EmptyStateView(
            onChooseArchive: { [weak self] in
                self?.chooseArchive()
            },
            onOpenURLs: { urls in
                DocumentOpener.shared.open(urls)
            }
        )
        window.contentViewController = NSHostingController(rootView: view)
    }

    /// Brings the empty state forward. Does nothing if it is already visible,
    /// so callers can invoke it freely from lifecycle notifications.
    func show() {
        guard let window else { return }
        if !window.isVisible {
            showWindow(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Takes the empty state away once an archive is open.
    func hide() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
    }

    /// Standard Open panel, filtered to archive types.
    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose an archive to browse."
        panel.allowedContentTypes = ArchiveDocumentFile.openPanelContentTypes

        guard panel.runModal() == .OK else { return }
        DocumentOpener.shared.open(panel.urls)
    }
}
