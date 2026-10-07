//
//  ErrorPresenter.swift
//  ArchiveCat
//
//  One place that turns an `ArchiveError` into a macOS alert.
//
//  The product brief is explicit about error UX: a plain sentence the user can
//  act on, with the raw libarchive diagnostic available but folded away. Every
//  alert therefore has exactly one button, one sentence, and — when there is a
//  low-level message — a disclosure triangle's worth of detail in the
//  informative text.
//

import AppKit
import ArchiveCore
import os

@MainActor
enum ErrorPresenter {

    /// Presents `error` modally. `url` is used when the error itself does not
    /// carry one.
    static func present(_ error: Error, url: URL? = nil) {
        let archiveError = asArchiveError(error)

        // Cancellation is not an error the user needs to be told about.
        if archiveError.isCancellation { return }

        ArchiveCatLog.ui.debug("presenting error: \(String(describing: archiveError), privacy: .public)")

        let alert = NSAlert()
        alert.alertStyle = archiveError.isSecurityRelevant ? .critical : .warning
        alert.messageText = archiveError.headline
        alert.informativeText = informativeText(for: archiveError, url: url)
        alert.addButton(withTitle: "OK")

        if let details = archiveError.technicalDetails {
            let accessory = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 64))
            accessory.isEditable = false
            accessory.drawsBackground = false
            accessory.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            accessory.string = details
            accessory.textContainerInset = NSSize(width: 0, height: 4)
            alert.accessoryView = accessory
        }

        if let suggestion = archiveError.recoverySuggestion {
            alert.informativeText += "\n\n\(suggestion)"
        }

        alert.runModal()
    }

    /// A non-modal banner message for things that are informative rather than
    /// blocking (an entry that could not be previewed, say).
    static func presentTransient(_ message: String, in window: NSWindow?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private static func informativeText(for error: ArchiveError, url: URL?) -> String {
        var text = error.explanation
        if case .cannotOpen = error, let url {
            text = "“\(url.lastPathComponent)” could not be opened. \(error.explanation)"
        }
        return text
    }

    private static func asArchiveError(_ error: Error) -> ArchiveError {
        if let archiveError = error as? ArchiveError { return archiveError }
        return .underlying(reason: error.localizedDescription, technicalDetails: String(describing: error))
    }
}

extension ArchiveError {
    /// Errors that concern untrusted input get the more serious alert style.
    var isSecurityRelevant: Bool {
        switch self {
        case .unsafePath, .corrupted, .limitExceeded, .encrypted: return true
        case .cannotOpen, .unsupportedFormat, .extractionFailed, .destinationUnusable,
             .cancelled, .previewUnavailable, .underlying:
            return false
        }
    }
}
