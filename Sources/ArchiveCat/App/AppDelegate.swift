//
//  AppDelegate.swift
//  ArchiveCat
//
//  Application-level delegate: menu construction, open-with handling and
//  document controller wiring live here. Window contents are SwiftUI.
//

import AppKit
import ArchiveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu bar first: NSDocumentController installs its own items, so ours
        // must exist before documents start opening.
        MainMenuBuilder.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ArchiveCatLog.ui.debug("ArchiveCat ready (\(LibArchive.versionString, privacy: .public))")

        // Nothing to browse? Show the empty state window rather than a blank
        // "Untitled" document that could never be saved.
        if NSDocumentController.shared.documents.isEmpty {
            WelcomeWindowController.shared.show()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // ArchiveCat has no notion of an untitled document.
        false
    }

    /// Dock click with no windows: bring back the empty state.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, NSDocumentController.shared.documents.isEmpty {
            WelcomeWindowController.shared.show()
        }
        return true
    }

    /// Close the welcome window once a real document is on screen, so the app
    /// does not accumulate empty windows.
    func applicationDidUpdate(_ notification: Notification) {
        guard !NSDocumentController.shared.documents.isEmpty else { return }
        if let welcome = WelcomeWindowController.shared.window, welcome.isVisible {
            welcome.orderOut(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Task { await DocumentOpener.shared.open(urls) }
        sender.reply(toOpenOrPrint: .success)
    }
}
