//
//  EmptyStateView.swift
//  ArchiveCat
//
//  The window shown when no archive is open, and the small pieces reused by the
//  browser's warning banner.
//
//  Deliberately not a wizard: one sentence, one button, and a drop target. The
//  cat lives in the icon and the copy, not in every control.
//

import ArchiveCore
import SwiftUI
import UniformTypeIdentifiers

struct EmptyStateView: View {

    let onChooseArchive: () -> Void
    let onOpenURLs: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("ArchiveCat")
                    .font(.title2.weight(.semibold))
                Text("Open an archive to look inside.")
                    .foregroundStyle(.secondary)
            }

            Button("Open Archive…", action: onChooseArchive)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            Text("or drag an archive here")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 320)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(10)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadURLs(from: providers)
            return true
        }
    }

    /// Resolves dropped `public.file-url` items and hands them to the opener.
    private func loadURLs(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            onOpenURLs(urls)
        }
    }
}

/// A thin banner for archive-level warnings.
///
/// Informative, not modal: the archive is still perfectly browsable, so this
/// must not interrupt.
struct WarningBannerView: View {

    let warning: ArchiveWarning

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: warning.kind.isSecurityRelevant ? "exclamationmark.shield.fill" : "info.circle.fill")
                .foregroundStyle(warning.kind.isSecurityRelevant ? .orange : .secondary)

            Text(warning.message)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The sheet shown while a large archive is being extracted.
struct ExtractionSummaryBanner: View {

    let message: String
    let destination: URL
    let onReveal: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 1) {
                Text(message)
                    .font(.callout)
                Text(destination.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button("Show in Finder", action: onReveal)
                .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
