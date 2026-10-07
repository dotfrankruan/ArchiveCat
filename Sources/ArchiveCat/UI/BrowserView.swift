//
//  BrowserView.swift
//  ArchiveCat
//
//  The archive browser window's content.
//
//  Layout follows the brief (and the Finder):
//
//      ┌───────────────────────────────────────────────┐
//      │ toolbar (AppKit, in the window)               │
//      ├─────────────┬─────────────────────────────────┤
//      │ sidebar     │  file list                      │
//      │ (tree)      │                       inspector │
//      ├─────────────┴─────────────────────────────────┤
//      │ breadcrumb + status                           │
//      └───────────────────────────────────────────────┘
//
//  Everything here is SwiftUI except the file list itself, which is a real
//  `NSTableView` (see `EntryListContainerView` for why).
//

import AppKit
import ArchiveCore
import SwiftUI

struct BrowserView: View {

    @Bindable var model: BrowserViewModel

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 420)
        } detail: {
            detail
                .inspector(isPresented: $model.showsInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 520)
                }
        }
        // The hosting controller sizes the window from this view's ideal size,
        // so the browser's first launch is driven from here rather than by
        // poking `NSWindow` after the fact.
        .frame(minWidth: 900, idealWidth: 1_060, minHeight: 560, idealHeight: 660)
        .onAppear {
            if model.document == nil, model.phase != .ready {
                model.load()
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let warning = model.warnings(ofKind: .unsafeEntries).first {
                WarningBannerView(warning: warning)
            } else if let warning = model.warnings(ofKind: .suspiciousSize).first {
                WarningBannerView(warning: warning)
            }

            switch model.phase {
            case .loading:
                LoadingView(progress: model.scanProgress)

            case let .failed(message):
                FailureView(message: message) { model.rescan() }

            case .ready:
                if model.rows.isEmpty {
                    EmptyDirectoryView(model: model)
                } else {
                    EntryListView(model: model)
                }
            }

            if let summary = model.extraction.completedSummary, let revealURL = model.extraction.revealURL {
                ExtractionSummaryBanner(
                    message: summary,
                    destination: revealURL,
                    onReveal: { model.revealInFinder(revealURL) },
                    onDismiss: { model.dismissExtractionSummary() }
                )
            }

            Divider()
            BottomBarView(model: model)
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    /// Maps the model's plain `Bool` onto SwiftUI's column visibility so the
    /// toolbar button, the View menu and the split view all agree.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.isSidebarVisible ? .all : .detailOnly },
            set: { model.isSidebarVisible = ($0 != .detailOnly) }
        )
    }
}

// MARK: - File list

/// Bridges the AppKit table into SwiftUI.
///
/// The representable takes plain values (not the model) so SwiftUI re-runs
/// `updateNSView` whenever any of them changes; the coordinator holds the model
/// for the callbacks that need to act on it.
struct EntryListView: View {

    @Bindable var model: BrowserViewModel

    var body: some View {
        EntryListRepresentable(
            rows: model.rows,
            selection: $model.selection,
            sortSpec: $model.sortSpec,
            showsTechnicalColumns: model.showsTechnicalColumns,
            isSearching: model.isSearching,
            model: model
        )
    }
}

private struct EntryListRepresentable: NSViewRepresentable {

    let rows: [EntryRow]
    @Binding var selection: Set<String>
    @Binding var sortSpec: EntrySortSpec
    let showsTechnicalColumns: Bool
    let isSearching: Bool
    let model: BrowserViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> EntryListContainerView {
        let view = EntryListContainerView()
        view.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: EntryListContainerView, context: Context) {
        context.coordinator.model = model
        view.setColumns(Self.columns(showsTechnicalColumns: showsTechnicalColumns))
        view.isShowingSearchResults = isSearching
        view.sortSpec = sortSpec
        view.rows = rows
        view.selectedRowIDs = selection
    }

    private static func columns(showsTechnicalColumns: Bool) -> [EntrySortColumn] {
        var columns: [EntrySortColumn] = [.name, .size, .compressedSize, .compressionRatio, .modified, .kind]
        if showsTechnicalColumns {
            columns.append(contentsOf: [.permissions, .uid, .gid, .linkTarget])
        }
        return columns
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, EntryListContainerDelegate {

        var model: BrowserViewModel
        weak var view: EntryListContainerView?

        init(model: BrowserViewModel) {
            self.model = model
        }

        func entryList(_ view: EntryListContainerView, didChangeSelectionTo rowIDs: Set<String>) {
            guard model.selection != rowIDs else { return }
            model.selection = rowIDs
        }

        func entryListDidActivateSelection(_ view: EntryListContainerView) {
            activate()
        }

        func entryListDidRequestQuickLook(_ view: EntryListContainerView) {
            model.quickLook()
        }

        func entryList(_ view: EntryListContainerView, didChangeSortTo spec: EntrySortSpec) {
            guard model.sortSpec != spec else { return }
            model.sortSpec = spec
        }

        func entryList(_ view: EntryListContainerView, promiseFor row: EntryRow) -> NSFilePromiseProvider? {
            guard let document = model.document else { return nil }
            return EntryFilePromise.make(for: row, document: document, session: model.session)
        }

        func entryList(_ view: EntryListContainerView, menuFor rowIDs: Set<String>) -> NSMenu? {
            guard !rowIDs.isEmpty else { return nil }
            return ContextMenuBuilder.menu(forRowIDs: rowIDs, rows: view.rows)
        }

        /// Return and double-click: a folder opens, a file previews.
        private func activate() {
            let selected = model.rows.filter { model.selection.contains($0.id) }
            guard let row = selected.first else { return }

            if selected.count == 1, model.open(row: row) {
                return
            }
            model.quickLook()
        }
    }
}

// MARK: - Loading, failure and empty directory states

private struct LoadingView: View {
    let progress: ArchiveScanProgress?

    var body: some View {
        VStack(spacing: 12) {
            if let fraction = progress?.fractionCompleted {
                ProgressView(value: fraction) {
                    Text("Reading archive…")
                }
                .progressViewStyle(.linear)
                .frame(width: 260)
            } else {
                ProgressView()
                Text("Reading archive…")
                    .foregroundStyle(.secondary)
            }

            if let progress {
                Text("\(progress.entriesScanned.formatted()) entries")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("ArchiveCat couldn’t read this archive", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

private struct EmptyDirectoryView: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        if model.isSearching {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView(
                "This folder is empty",
                systemImage: "folder",
                description: Text("“\(model.currentDirectoryName)” contains no entries.")
            )
        }
    }
}
