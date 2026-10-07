//
//  IconProvider.swift
//  ArchiveCat
//
//  Finder-like icons for archive entries.
//
//  Icons come from the system: `NSWorkspace` resolves a `UTType` to whatever
//  icon the user's Mac actually uses for that kind of file, including any
//  application-supplied icons. Nothing is shipped, and folders, symlinks and
//  packages get their proper system treatment.
//

import AppKit
import ArchiveCore
import UniformTypeIdentifiers

@MainActor
enum IconProvider {

    private static var cache: [String: NSImage] = [:]

    /// The icon for an entry, based on its type and extension.
    static func icon(for entry: ArchiveEntry) -> NSImage {
        icon(forType: entry.type, fileExtension: entry.fileExtension)
    }

    static func icon(for row: EntryRow) -> NSImage {
        icon(forType: row.type, fileExtension: row.entry?.fileExtension)
    }

    static func icon(forType type: EntryType, fileExtension: String?) -> NSImage {
        switch type {
        case .directory:
            return cached(key: "folder") { NSWorkspace.shared.icon(for: .folder) }
        case .symbolicLink:
            return cached(key: "symlink") { NSWorkspace.shared.icon(for: .symbolicLink) }
        case .hardLink:
            return cached(key: "hardlink") { NSWorkspace.shared.icon(for: .symbolicLink) }
        case .fifo:
            return cached(key: "fifo") { NSWorkspace.shared.icon(for: .item) }
        case .socket:
            return cached(key: "socket") { NSWorkspace.shared.icon(for: .item) }
        case .characterDevice, .blockDevice:
            return cached(key: "device") { NSWorkspace.shared.icon(for: .volume) }
        case .unknown:
            return cached(key: "unknown") { NSWorkspace.shared.icon(for: .data) }
        case .regularFile:
            guard let fileExtension, !fileExtension.isEmpty,
                  let type = UTType(filenameExtension: fileExtension) else {
                return cached(key: "data") { NSWorkspace.shared.icon(for: .data) }
            }
            return cached(key: type.identifier) { NSWorkspace.shared.icon(for: type) }
        }
    }

    /// A small SF Symbol for status areas, where a full colour icon would be
    /// too loud.
    static func symbol(_ name: String, accessibilityDescription: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
    }

    private static func cached(key: String, make: () -> NSImage) -> NSImage {
        if let cached = cache[key] { return cached }
        let image = make()
        cache[key] = image
        return image
    }

    /// Drops the icon cache. Called when the system appearance changes, because
    /// the returned icons are appearance-specific.
    static func invalidate() {
        cache.removeAll()
    }
}
