//
//  InspectorView.swift
//  ArchiveCat
//
//  The entry inspector.
//
//  Two halves: the metadata the archive itself records — every strange Unix
//  detail normal GUI tools hide — and an on-demand content check that extracts
//  only the selected entry into the preview cache to identify it.
//
//  Nothing here ever extracts the archive, and nothing runs until the user
//  asks for it.
//

import ArchiveCore
import SwiftUI

struct InspectorView: View {

    @Bindable var model: BrowserViewModel
    @State private var inspection: FileInspection?
    @State private var isInspecting = false
    @State private var inspectionError: String?

    var body: some View {
        Group {
            if let row = model.inspectedRow {
                content(for: row)
            } else {
                ContentUnavailableView(
                    "Nothing Selected",
                    systemImage: "sidebar.right",
                    description: Text("Select an entry to see its metadata.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selection) { _, _ in
            // Invalidation matters: a stale inspection would describe the
            // previously selected file.
            inspection = nil
            inspectionError = nil
        }
        .onChange(of: model.document?.id) { _, _ in
            inspection = nil
            inspectionError = nil
        }
    }

    // MARK: - Content

    private func content(for row: EntryRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(for: row)

                if let entry = row.entry {
                    section("Archive") {
                        InspectorRow("Name", entry.name)
                        InspectorRow("Path", entry.path.isEmpty ? "/" : entry.path)
                        if entry.rawPath != entry.path {
                            InspectorRow("Stored path", entry.rawPath, isTechnical: true)
                        }
                        InspectorRow("Type", CachedKindName.name(for: entry))
                    }

                    section("Size") {
                        InspectorRow("Uncompressed", entry.uncompressedSize.map(ArchiveCatFormat.byteCount))
                        InspectorRow("Compressed", entry.compressedSize.map {
                            (entry.compressedSizeIsEstimated ? "≈ " : "") + ArchiveCatFormat.byteCount($0)
                        })
                        InspectorRow("Compression", entry.compressionRatio.map(ArchiveCatFormat.ratio))
                        InspectorRow("CRC-32", entry.crc32.map { String(format: "%08X", $0) })
                    }

                    section("Dates") {
                        InspectorRow("Modified", entry.modificationDate.map(ArchiveCatFormat.timestamp))
                    }

                    section("Unix metadata") {
                        InspectorRow("Permissions", entry.permissionString.map { "\($0)  (\(entry.octalPermissionString ?? ""))" })
                        InspectorRow("Mode", entry.posixMode.map { String(format: "0o%04o", $0) })
                        InspectorRow("Owner (UID)", ArchiveCatFormat.number(entry.uid))
                        InspectorRow("Group (GID)", ArchiveCatFormat.number(entry.gid))
                        InspectorRow("Link count", ArchiveCatFormat.number(entry.linkCount))
                        InspectorRow("Device", deviceDescription(entry))
                    }

                    if entry.symlinkTarget != nil || entry.hardlinkTarget != nil {
                        section("Link") {
                            InspectorRow("Symbolic target", entry.symlinkTarget)
                            InspectorRow("Hard link target", entry.hardlinkTarget)
                            if let target = entry.symlinkTarget {
                                InspectorRow("Resolves to", symlinkResolutionDescription(target: target, linkPath: entry.path))
                            }
                        }
                    }

                    section("Contents") {
                        contentInspection(for: row, entry: entry)
                    }
                } else {
                    section("Folder") {
                        InspectorRow("Name", row.name)
                        InspectorRow("Path", row.path.isEmpty ? "/" : row.path)
                        InspectorRow("Type", "Folder (implied by its contents)")
                        InspectorRow("Subfolders", String(model.tree?.directory(at: row.path)?.childDirectoryPaths.count ?? 0))
                        InspectorRow("Entries", String(model.tree?.directory(at: row.path)?.childEntryIndices.count ?? 0))
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(for row: EntryRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: IconProvider.icon(for: row))
                .resizable()
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(row.kindName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sections

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
    }

    // MARK: - Content inspection

    @ViewBuilder
    private func contentInspection(for row: EntryRow, entry: ArchiveEntry) -> some View {
        if entry.isDirectory {
            Text("Folders have no contents to inspect.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let inspection {
            InspectorRow("Kind", inspection.kind.localizedName)
            if !inspection.architectures.isEmpty {
                InspectorRow("Architectures", inspection.architectures.map(\.name).joined(separator: ", "))
            }
            if let detail = inspection.detail {
                InspectorRow("Detail", detail)
            }
            InspectorRow("Examined", "\(inspection.bytesExamined.formatted()) bytes")
        } else if isInspecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the first bytes…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Identify Contents") {
                Task { await inspect(entry: entry) }
            }
            .help("Extracts only this entry into the preview cache and inspects its header. The archive is not unpacked.")

            if let inspectionError {
                Text(inspectionError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func inspect(entry: ArchiveEntry) async {
        isInspecting = true
        inspectionError = nil
        defer { isInspecting = false }

        do {
            let url = try await model.session.materializeForPreview(entry: entry)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: 4096) ?? Data()
            inspection = FileInspector.inspect(head: head, fileName: entry.name)
        } catch let error as ArchiveError {
            inspectionError = error.explanation
        } catch {
            inspectionError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func deviceDescription(_ entry: ArchiveEntry) -> String? {
        guard let major = entry.deviceMajor, let minor = entry.deviceMinor else { return nil }
        return "\(major), \(minor)"
    }

    private func symlinkResolutionDescription(target: String, linkPath: String) -> String {
        switch ArchivePath.resolveSymlinkTarget(target, linkPath: linkPath) {
        case let .insideRoot(normalized):
            return normalized.isEmpty ? "(the archive root)" : normalized
        case let .escapesRoot(violation):
            return "outside the archive — \(violation.localizedDescription)"
        }
    }
}

/// A label/value pair, monospaced on the value side so numbers line up.
struct InspectorRow: View {

    let label: String
    let value: String?
    let isTechnical: Bool

    init(_ label: String, _ value: String?, isTechnical: Bool = false) {
        self.label = label
        self.value = value
        self.isTechnical = isTechnical
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value ?? "—")
                .font(isTechnical ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// Small cache so the inspector does not rebuild kind strings constantly.
@MainActor
private enum CachedKindName {
    private static var cache: [ArchiveEntryID: String] = [:]

    static func name(for entry: ArchiveEntry) -> String {
        if let cached = cache[entry.id] { return cached }
        let name = FileKindDescription.describe(entry)
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[entry.id] = name
        return name
    }
}
