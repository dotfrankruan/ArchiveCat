//
//  EntryDragSource.swift
//  ArchiveCat
//
//  Dragging entries out to the Finder.
//
//  This uses `NSFilePromiseProvider`, the macOS mechanism designed for exactly
//  ArchiveCat's situation: the Finder is told "there will be a file called X",
//  the drag proceeds immediately, and the payload is produced only when the
//  user actually drops it. Nothing is extracted at drag time, and a large file
//  never freezes the UI.
//
//  When the drop happens the entry — or, for a folder, its subtree — is
//  materialised into ArchiveCat's preview cache and then copied to the
//  destination the Finder chose. There is no whole-archive extraction anywhere
//  in this path.
//

import AppKit
import ArchiveCore
import UniformTypeIdentifiers

/// One pending drag.
///
/// Immutable and free of shared mutable state, so the promise can be written
/// from the operation queue the system uses for promises.
final class EntryFilePromise: NSFilePromiseProvider {

    struct Payload: Sendable {
        /// Name the Finder should create.
        let name: String
        /// Entries to materialise into the cache.
        let entries: [ArchiveEntry]
        /// Path, inside the materialised cache directory, of the item to hand
        /// over. For a folder this is the folder itself.
        let sourceRelativePath: String
        let session: ArchiveSession
        let document: ArchiveDocument
        /// True when the dragged item is a folder (affects the promised type).
        let isDirectory: Bool
    }

    let payload: Payload

    init(payload: Payload) {
        self.payload = payload
        super.init()
        self.fileType = Self.fileTypeIdentifier(for: payload)
        self.userInfo = ["path": payload.sourceRelativePath, "count": payload.entries.count]
        self.delegate = EntryFilePromiseDelegate.shared
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EntryFilePromise is created in code only")
    }

    /// The type identifier the Finder should be told about.
    static func fileTypeIdentifier(for payload: Payload) -> String {
        if payload.isDirectory { return UTType.folder.identifier }
        guard let fileExtension = (payload.name as NSString).pathExtension.isEmpty
            ? nil
            : (payload.name as NSString).pathExtension,
            let type = UTType(filenameExtension: fileExtension) else {
            return UTType.data.identifier
        }
        return type.identifier
    }

    /// Builds a promise for a listed row.
    ///
    /// Real entries promise themselves; a directory that only exists implicitly
    /// in the archive promises the subtree beneath it, because that is what the
    /// user pointed at.
    static func make(
        for row: EntryRow,
        document: ArchiveDocument,
        session: ArchiveSession
    ) -> EntryFilePromise? {
        if let entry = row.entry {
            return EntryFilePromise(payload: Payload(
                name: entry.name,
                entries: [entry],
                sourceRelativePath: entry.path,
                session: session,
                document: document,
                isDirectory: entry.isDirectory
            ))
        }

        // Implied directory: promise everything under it.
        let prefix = row.path + "/"
        let descendants = document.entries.filter { $0.safety.isSafe && $0.path.hasPrefix(prefix) }
        guard !descendants.isEmpty else { return nil }

        return EntryFilePromise(payload: Payload(
            name: row.name,
            entries: descendants,
            sourceRelativePath: row.path,
            session: session,
            document: document,
            isDirectory: true
        ))
    }
}

/// Fulfils file promises.
///
/// A single shared instance is used because `NSFilePromiseProvider` holds its
/// delegate weakly and there is nothing per-drag to keep.
final class EntryFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {

    static let shared = EntryFilePromiseDelegate()

    private override init() {
        super.init()
    }

    /// The name the Finder should create, including the extension.
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let promise = provider as? EntryFilePromise else { return "ArchiveCat item" }
        let name = promise.payload.name
        return name.isEmpty ? "ArchiveCat item" : name
    }

    /// Produces the payload at the destination the Finder chose.
    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let promise = provider as? EntryFilePromise else {
            completionHandler(ArchiveError.underlying(
                reason: "ArchiveCat lost track of the dragged item.",
                technicalDetails: nil
            ))
            return
        }

        let payload = promise.payload
        // AppKit's promise completion handler is not annotated `@Sendable`,
        // but it is documented to be callable from any thread.
        let completion = SendableBox(completionHandler)

        Task.detached(priority: .userInitiated) {
            do {
                // Materialise only the dragged entries into the preview cache…
                let materialisedRoot = try await payload.session.materializeForDrag(entries: payload.entries)
                let source = materialisedRoot.appendingPathComponent(payload.sourceRelativePath)

                guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                    throw ArchiveError.previewUnavailable(
                        entryPath: payload.sourceRelativePath,
                        reason: "The archive produced no file, so there was nothing to hand to the Finder."
                    )
                }

                // …then copy it to the exact path the Finder asked for.
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: url)
                }
                try fileManager.copyItem(at: source, to: url)

                ArchiveCatLog.drag.debug("fulfilled a file promise for \(payload.sourceRelativePath, privacy: .public)")
                completion.value(nil)
            } catch {
                ArchiveCatLog.drag.error("a file promise could not be fulfilled")
                completion.value(error)
            }
        }
    }

    /// Promises are written off the main thread so a multi-gigabyte entry never
    /// blocks the UI.
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.promiseQueue
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.frankruan.ArchiveCat.file-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
}
