//
//  DocumentOpener.swift
//  ArchiveCat
//
//  One place that turns user intent ("open these files") into document windows.
//
//  Finder's "Open With", a drag onto the Dock icon, the Open panel and the
//  welcome window all funnel through here so they behave identically: existing
//  windows are reused, files that are already open are brought forward, and
//  failures are reported once, in one style.
//

import AppKit
import ArchiveCore

@MainActor
final class DocumentOpener {
    static let shared = DocumentOpener()

    private init() {}

    /// Opens each URL, reporting failures in a single alert.
    func open(_ urls: [URL], completion: (() -> Void)? = nil) {
        let unique = urls.map(\.standardizedFileURL).removingDuplicates()
        guard !unique.isEmpty else {
            completion?()
            return
        }

        var failures: [(url: URL, error: Error)] = []
        var remaining = unique.count

        for url in unique {
            // If the archive is already open, bring its window forward instead
            // of scanning it again.
            if let existing = document(for: url) {
                existing.showWindows()
                remaining -= 1
                if remaining == 0 { completion?() }
                continue
            }

            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if document == nil, let error {
                    failures.append((url, error))
                }
                remaining -= 1
                if remaining == 0 {
                    self.presentFailures(failures)
                    completion?()
                }
            }
        }
    }

    /// The archive document already showing `url`, if any.
    func document(for url: URL) -> ArchiveDocumentFile? {
        let target = url.standardizedFileURL.path(percentEncoded: false)
        return NSDocumentController.shared.documents
            .compactMap { $0 as? ArchiveDocumentFile }
            .first { $0.archiveURL.standardizedFileURL.path(percentEncoded: false) == target }
    }

    private func presentFailures(_ failures: [(url: URL, error: Error)]) {
        guard !failures.isEmpty else { return }

        // One alert for one file (with the engine's full explanation); a
        // summary plus details for several.
        if failures.count == 1, let failure = failures.first {
            ErrorPresenter.present(failure.error, url: failure.url)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ArchiveCat couldn’t open \(failures.count) archives."
        alert.informativeText = failures
            .map { "• \($0.url.lastPathComponent)" }
            .joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private extension Array where Element: Hashable {
    /// Keeps the first occurrence of each element, preserving order.
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
