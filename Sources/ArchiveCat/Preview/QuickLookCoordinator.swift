//
//  QuickLookCoordinator.swift
//  ArchiveCat
//
//  Space-to-preview, backed by the system Quick Look panel.
//
//  The contract with the rest of the app is narrow: hand over a selection, get
//  back a panel. Everything expensive happens behind `ArchiveSession`:
//
//   1. only the selected entries are extracted, into the preview cache;
//   2. the cache is keyed by archive identity + entry ordinal + path, so two
//      archives with the same name cannot collide;
//   3. an entry that is already cached and still valid is not extracted again.
//
//  The whole archive is never touched.
//

import AppKit
import ArchiveCore
import QuickLookUI

@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    static let shared = QuickLookCoordinator()

    /// URLs currently being previewed, in selection order.
    private var previewURLs: [URL] = []
    /// The selection the panel is showing, so a repeat Space hides it.
    private var previewedEntryIDs: [ArchiveEntryID] = []
    private var preparationTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    // MARK: - Toggling

    /// Shows Quick Look for `entries`, or hides the panel if it is already
    /// showing exactly that selection — the Finder's Space behaviour.
    func toggle(entries: [ArchiveEntry], session: ArchiveSession, document: ArchiveDocument?) async {
        guard let document else { return }

        let ids = entries.map(\.id)
        if let panel = QLPreviewPanel.shared(), panel.isVisible, ids == previewedEntryIDs, !ids.isEmpty {
            panel.orderOut(nil)
            return
        }

        preparationTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var urls: [URL] = []
                for entry in entries {
                    if Task.isCancelled { return }
                    let url = try await session.materializeForPreview(entry: entry)
                    urls.append(url)
                }
                guard !Task.isCancelled else { return }
                self.present(urls: urls, entries: entries)
            } catch let error as ArchiveError where error.isCancellation {
                return
            } catch let error as ArchiveError {
                ErrorPresenter.present(error)
            } catch {
                ErrorPresenter.present(ArchiveError.previewUnavailable(
                    entryPath: entries.first?.path ?? "",
                    reason: error.localizedDescription
                ))
            }
        }
        preparationTask = task
        await task.value
    }

    /// Convenience for a single entry.
    func preview(entry: ArchiveEntry, session: ArchiveSession, document: ArchiveDocument?) async {
        await toggle(entries: [entry], session: session, document: document)
    }

    private func present(urls: [URL], entries: [ArchiveEntry]) {
        previewURLs = urls
        previewedEntryIDs = entries.map(\.id)

        guard let panel = QLPreviewPanel.shared() else {
            ArchiveCatLog.preview.error("Quick Look is unavailable on this system")
            return
        }

        // Set the data source directly as well as through the window
        // controller: whichever route the system takes, the panel finds us.
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Clears cached state when the panel closes.
    ///
    /// Quick Look calls its data source and delegate on the main thread, but
    /// the system protocols are not annotated for it, so each entry point
    /// asserts the main actor rather than being isolated.
    nonisolated func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewURLs = []
            previewedEntryIDs = []
        }
    }

    // MARK: - Data source

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // Only the path crosses the isolation boundary (a `String`); the item
        // itself is rebuilt on the caller's side, because `QLPreviewItem` is
        // not annotated `Sendable`.
        let path: String? = MainActor.assumeIsolated {
            guard index >= 0, index < previewURLs.count else { return nil }
            return previewURLs[index].path(percentEncoded: false)
        }
        guard let path else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    // MARK: - Delegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Space closes the panel again, like the Finder.
        guard event.type == .keyDown, event.charactersIgnoringModifiers == " " else { return false }
        MainActor.assumeIsolated {
            panel.orderOut(nil)
        }
        return true
    }
}
