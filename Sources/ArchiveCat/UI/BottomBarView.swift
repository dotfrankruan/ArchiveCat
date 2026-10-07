//
//  BottomBarView.swift
//  ArchiveCat
//
//  The bar under the file list: a clickable breadcrumb of the current location
//  plus the archive's status — entry counts, sizes, compression, and the
//  progress of a running extraction.
//
//  This is Finder's path bar and status bar folded into one strip, which keeps
//  the window uncluttered while still answering "where am I", "how big is this"
//  and "what is happening right now".
//

import ArchiveCore
import SwiftUI

struct BottomBarView: View {

    @Bindable var model: BrowserViewModel

    var body: some View {
        HStack(spacing: 10) {
            breadcrumb

            Spacer(minLength: 8)

            if model.extraction.isRunning {
                extractionProgress
            } else if let message = model.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                status
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 26)
        .background(.bar)
        .help(helpText)
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 2) {
            if let document = model.document {
                crumb(title: document.fileName, systemImage: "archivebox", path: "")
            }

            ForEach(crumbs, id: \.path) { crumbItem in
                Image(systemName: "chevron.compact.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                crumb(
                    title: crumbItem.name,
                    systemImage: nil,
                    path: crumbItem.path
                )
            }
        }
        .lineLimit(1)
    }

    private func crumb(title: String, systemImage: String?, path: String) -> some View {
        Button {
            model.navigate(to: path)
        } label: {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                }
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(path == model.currentPath ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(path == model.currentPath)
    }

    /// Every directory from the root down to the current one, root first.
    private var crumbs: [ArchiveDirectory] {
        guard let tree = model.tree, !model.currentPath.isEmpty else { return [] }
        return Array(tree.breadcrumb(to: model.currentPath).dropFirst())
    }

    // MARK: - Status

    private var status: some View {
        HStack(spacing: 8) {
            if model.isSearching {
                Text("\(model.rows.count.formatted()) results")
            } else if let document = model.document {
                Text(model.rows.count == 1 ? "1 item" : "\(model.rows.count.formatted()) items")
                Text("•").foregroundStyle(.tertiary)
                Text("\(document.summary.entryCount.formatted()) in archive")
                Text("•").foregroundStyle(.tertiary)
                Text(model.sizeDescription)
                if let compressed = document.summary.comparableCompressedSize {
                    Text("•").foregroundStyle(.tertiary)
                    Text("\(ArchiveCatFormat.byteCount(compressed)) compressed")
                }
                if let ratio = document.summary.compressionRatio {
                    Text("•").foregroundStyle(.tertiary)
                    Text("\(ArchiveCatFormat.ratio(ratio)) saved")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var extractionProgress: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)

            if let progress = model.extraction.progress {
                Text("\(progress.completedEntries.formatted()) of \(progress.totalEntries.formatted())")
                Text("•").foregroundStyle(.tertiary)
                Text(ArchiveCatFormat.byteCount(progress.bytesWritten))
            } else {
                Text("Preparing…")
            }

            Button("Cancel") {
                model.cancelExtraction()
            }
            .controlSize(.small)
        }
        .font(.callout)
        .monospacedDigit()
    }

    private var helpText: String {
        guard let summary = model.document?.summary else { return "" }
        var lines = [summary.formatDescription, model.itemCountDescription]
        if let ratio = summary.compressionRatio {
            lines.append("Ratio \(ArchiveCatFormat.ratio(ratio))")
        }
        return lines.joined(separator: "\n")
    }
}
