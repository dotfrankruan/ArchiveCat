//
//  AppDelegate.swift
//  ArchiveCat
//
//  Application-level delegate: menu construction, document lifecycle and
//  open-with handling. Window contents are SwiftUI.
//
//  Document behaviour is deliberately ordinary. `NSDocumentController` owns
//  which archives are open — one `NSDocument` per archive, one window
//  controller per document — the same arrangement as Preview or TextEdit. The
//  only thing this delegate adds is the empty state: an archive browser has
//  nothing to show in an untitled document, so when no archive is open it shows
//  a welcome window that can open, or accept, a dropped archive instead.
//

import AppKit
import ArchiveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set once the application has been asked to quit.
    ///
    /// Documents are closed as part of quitting, and that must not bring the
    /// welcome window back on screen.
    private var isTerminating = false

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu bar first: NSDocumentController installs its own items, so ours
        // must exist before documents start opening.
        MainMenuBuilder.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ArchiveCatLog.ui.debug("ArchiveCat ready (\(LibArchive.versionString, privacy: .public))")

        // Either macOS restored archives to reopen, or there is nothing to show
        // and the empty state goes up instead of a blank "Untitled" document.
        showEmptyStateIfNeeded()
    }

    /// ArchiveCat has no notion of an untitled document.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Document lifecycle

    /// Closing the last archive window leaves the application running, exactly
    /// like every other document-based Mac app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Called by `ArchiveDocumentFile` after a document has closed.
    ///
    /// Hopping to the next main-loop pass matters: `NSDocumentController` drops
    /// the document from `documents` as part of the close, and the window is
    /// still being torn down while `close()` returns.
    func documentDidClose() {
        guard !isTerminating else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showEmptyStateIfNeeded()
        }
    }

    /// Dock click, or a relaunch request: the empty state comes back only when
    /// there genuinely is nothing open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, NSDocumentController.shared.documents.isEmpty else { return true }
        showEmptyStateIfNeeded()
        return true
    }

    /// Hide the welcome window as soon as a real document is on screen.
    ///
    /// Note that this only ever *hides* it. Re-showing the empty state from
    /// here would fight the user closing it with ⌘W.
    func applicationDidUpdate(_ notification: Notification) {
        guard !NSDocumentController.shared.documents.isEmpty else { return }
        WelcomeWindowController.shared.hide()
    }

    // MARK: - Termination

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // No ArchiveCat document is ever edited, so there is nothing to review.
        isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
    }

    // MARK: - Opening archives

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        // Answer the Apple Event first, then open on the next runloop pass
        // rather than re-entering document creation from inside the handler.
        sender.reply(toOpenOrPrint: .success)
        DispatchQueue.main.async {
            DocumentOpener.shared.open(urls)
        }
    }

    /// `File > Open…` (⌘O), which has to work whatever is on screen.
    ///
    /// AppKit consults `NSDocumentController` late in the responder chain for
    /// document-based apps, and that is usually enough. Implementing the action
    /// here as well — forwarding to exactly the same call — makes ⌘O work from a
    /// window that is not a document window, such as the empty state, without
    /// depending on where in the chain the controller happens to sit.
    @objc func openDocument(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    // MARK: - Empty state

    private func showEmptyStateIfNeeded() {
        guard !isTerminating else { return }
        guard NSDocumentController.shared.documents.isEmpty else {
            WelcomeWindowController.shared.hide()
            return
        }
        WelcomeWindowController.shared.show()
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// The only action this delegate answers is `openDocument:`; everything else
    /// in the menu reaches the window controllers.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        true
    }
}
