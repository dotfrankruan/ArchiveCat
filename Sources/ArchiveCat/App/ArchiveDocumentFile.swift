//
//  ArchiveDocumentFile.swift
//  ArchiveCat
//
//  The NSDocument subclass for an archive.
//
//  AppKit owns everything that makes this a real document-based macOS app:
//  one window per archive, the Open panel, Open Recent, reopening at launch,
//  Finder's "Open With", and the Dock drop. The document itself is read-only —
//  it never marks itself dirty, never writes, and never offers Save — because
//  v1 deliberately cannot modify archives.
//
//  NOTE: the window controller is filled in by `ArchiveDocumentWindowController`;
//  this file owns lifetime, security-scoped access and rescanning.
//

import AppKit
import ArchiveCore
import SwiftUI
import UniformTypeIdentifiers

final class ArchiveDocumentFile: NSDocument {

    /// The archive this document shows.
    private(set) var archiveURL: URL = URL(fileURLWithPath: "/")

    /// Security-scoped access for the lifetime of the document. macOS grants
    /// this when the file arrives through the Open panel, Finder or a bookmark.
    private var scopedAccess: SecurityScopedAccess?

    /// The browsing session (scan, extraction, preview materialisation).
    let session = ArchiveSession()

    /// Set by the window controller so the menu bar can reach the browser.
    weak var browser: BrowserViewModel?

    // NOTE: `readableTypes` is deliberately *not* overridden.
    //
    // It looks like the natural place to advertise archive formats, but the
    // values it takes are UTTypes and AppKit consults it while resolving a file
    // to a document class. Overriding it with a list of file extensions (as an
    // earlier revision did) makes NSDocumentController reject every archive
    // with "the type isn't supported". The authoritative list lives in
    // Info.plist's CFBundleDocumentTypes; `openPanelContentTypes` below is only
    // for the panels ArchiveCat opens itself.

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        true
    }

    /// ArchiveCat never modifies an archive.
    override var isEntireFileLoaded: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        // Held for the document's lifetime; released in `close()`.
        scopedAccess = SecurityScopedAccess(url: url, enabled: true)
        archiveURL = url
    }

    override func makeWindowControllers() {
        let controller = ArchiveDocumentWindowController(document: self)
        addWindowController(controller)
    }

    override func close() {
        scopedAccess?.end()
        scopedAccess = nil
        super.close()
    }

    // MARK: - Read-only

    /// No document is ever dirty, so AppKit never offers Save or "Close and
    /// Save" dialogs.
    override var isDocumentEdited: Bool { false }

    override func data(ofType typeName: String) throws -> Data {
        throw ArchiveError.underlying(
            reason: "ArchiveCat is a read-only archive browser and cannot write archives.",
            technicalDetails: "NSDocument data(ofType:) was called for \(typeName)."
        )
    }

    // MARK: - Archive types

    /// Extensions ArchiveCat advertises. Formats are detected by libarchive,
    /// not by extension, but the Open panel still needs a list to filter with.
    static let archiveExtensions = [
        "zip", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tar.gz", "tar.bz2", "tar.xz", "tar.zst",
        "7z", "rar", "cpio", "gz", "bz2", "xz", "zst", "lz4", "lzh", "lha", "cab", "xar", "iso", "ar",
        "war", "jar", "apk", "ipa", "deb", "rpm", "pkg", "dmg",
    ]

    static var declaredArchiveTypes: [String] { archiveExtensions }

    /// Content types for ArchiveCat's own Open panels.
    ///
    /// `NSDocumentController` reads the application's `CFBundleDocumentTypes`,
    /// but the welcome window builds its own panel, so it needs a list too.
    static var openPanelContentTypes: [UTType] {
        var types: Set<UTType> = [.archive, .zip, .gzip, .bz2]
        for fileExtension in archiveExtensions {
            if let type = UTType(filenameExtension: fileExtension) {
                types.insert(type)
            }
        }
        return types.sorted { $0.identifier < $1.identifier }
    }
}
