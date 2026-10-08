//
//  ExtractionCoordinator.swift
//  ArchiveCat
//
//  Turns "Extract…" into a running extraction: destination picker, a real
//  question for every collision, then the work itself.
//
//  The conflict prompt is not cosmetic. The engine never overwrites silently:
//  it reports each collision through `ExtractionOptions.conflictResolver`, this
//  file puts the choice to the user as a sheet, and the engine executes exactly
//  the answer it gets back. Nothing here touches libarchive, and nothing in
//  ArchiveCore knows about AppKit.
//

import AppKit
import ArchiveCore
import UniformTypeIdentifiers

@MainActor
enum ExtractionCoordinator {

    // MARK: - Entry points

    /// Extract the current selection, asking for a destination.
    static func extractSelection(from model: BrowserViewModel, window: NSWindow?) {
        let entries = model.selectedEntries
        guard !entries.isEmpty else { return }
        Task {
            guard let destination = await chooseDestination(window: window) else { return }
            run(entries: entries, destination: destination, model: model, window: window, label: "Extracting")
        }
    }

    /// Extract the current selection straight to ~/Downloads.
    static func extractSelectionToDownloads(from model: BrowserViewModel, window: NSWindow?) {
        let entries = model.selectedEntries
        guard !entries.isEmpty else { return }
        guard let downloads = downloadsDirectory() else {
            ErrorPresenter.present(ArchiveError.destinationUnusable(
                url: URL(fileURLWithPath: NSHomeDirectory()),
                reason: "The Downloads folder could not be located."
            ))
            return
        }
        // Deliberately the same path as a chosen destination: writing straight
        // to Downloads must not be the one place that overwrites without asking.
        run(entries: entries, destination: downloads, model: model, window: window, label: "Extracting to Downloads")
    }

    /// Extract every entry in the archive. Explicitly requested, never automatic.
    static func extractEntireArchive(from model: BrowserViewModel, window: NSWindow?) {
        guard let document = model.document else { return }
        let entries = document.entries.filter { $0.safety.isSafe }
        guard !entries.isEmpty else { return }
        Task {
            guard let destination = await chooseDestination(window: window) else { return }
            run(
                entries: entries,
                destination: destination,
                model: model,
                window: window,
                label: "Extracting archive"
            )
        }
    }

    // MARK: - Flow

    private static func run(
        entries: [ArchiveEntry],
        destination: URL,
        model: BrowserViewModel,
        window: NSWindow?,
        label: String
    ) {
        // One prompt per operation, so "Apply to all" can stick for the rest of
        // this extraction and only this one.
        let prompt = ExtractionConflictPrompt(window: window, model: model)

        let options = ExtractionOptions(
            conflictPolicy: .ask,
            conflictResolver: { conflict in
                await prompt.resolution(for: conflict)
            },
            preservePermissions: true,
            preserveModificationDates: true,
            stripSetuidAndSetgid: true,
            checkAvailableSpace: true,
            limits: .unlimited,
            stripLeadingPathComponents: 0,
            extractSpecialFiles: false
        )

        model.extract(entries: entries, destination: destination, options: options, label: label)
    }

    // MARK: - Destination picker

    /// Native destination picker, as a sheet on the document window when one is
    /// available.
    private static func chooseDestination(window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Extract"
        panel.message = "Choose where to extract the selected items."
        panel.directoryURL = lastUsedDestination() ?? downloadsDirectory()

        let url: URL?
        if let window, window.isVisible {
            url = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }

        if let url { rememberDestination(url) }
        return url
    }

    // MARK: - Locations

    private static func downloadsDirectory() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// The last destination the user picked, so repeat extractions land in the
    /// same place. Persisted as a path rather than a bookmark: it is only a
    /// convenience default, and the sandbox grants access again through the
    /// Open panel.
    private static var lastUsedDestinationKey: String { "LastExtractionDestinationPath" }

    private static func lastUsedDestination() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: lastUsedDestinationKey) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func rememberDestination(_ url: URL) {
        UserDefaults.standard.set(url.path(percentEncoded: false), forKey: lastUsedDestinationKey)
    }
}

// MARK: - Conflict prompt

/// Puts one collision to the user, and remembers "Apply to all".
///
/// Presented as a sheet on the document window when there is one, so it belongs
/// to the window rather than blocking the whole application. The engine suspends
/// on `resolution(for:)` while the sheet is up.
@MainActor
final class ExtractionConflictPrompt {

    private weak var window: NSWindow?
    /// Told when a sheet goes up and comes down, so the progress strip can
    /// explain why extraction appears to be waiting.
    private weak var model: BrowserViewModel?
    /// The answer to reuse without asking again, once "Apply to all" is ticked.
    private var appliedToAll: ExtractionConflictResolution?
    /// Counts the collisions in this operation, so the sheet can say so.
    private var resolvedCount = 0

    init(window: NSWindow?, model: BrowserViewModel?) {
        self.window = window
        self.model = model
    }

    /// Asks about `conflict` unless the user already said "apply to all".
    func resolution(for conflict: ExtractionConflict) async -> ExtractionConflictResolution {
        if let appliedToAll {
            resolvedCount += 1
            return appliedToAll
        }

        model?.extraction.awaitingDecision = true
        let answer = await present(conflict)
        model?.extraction.awaitingDecision = false

        // If the operation was cancelled while the sheet was up, that is the
        // answer the engine should act on now.
        if Task.isCancelled {
            return .cancel
        }

        resolvedCount += 1
        if answer.applyToAll {
            appliedToAll = answer.resolution
        }
        return answer.resolution
    }

    private struct Answer {
        let resolution: ExtractionConflictResolution
        let applyToAll: Bool
    }

    private func present(_ conflict: ExtractionConflict) async -> Answer {
        let alert = NSAlert()
        alert.alertStyle = .warning

        alert.messageText = "An item named “\(conflict.entry.name)” already exists in “\(conflict.destination.lastPathComponent)”."

        var lines: [String] = []
        if resolvedCount > 0 {
            lines.append("\(resolvedCount) \(resolvedCount == 1 ? "item has" : "items have") already been handled in this extraction.")
            lines.append("")
        }
        lines.append("ArchiveCat can replace it, skip this entry, or keep both by giving the extracted item a new name.")
        if conflict.relativePath != conflict.entry.name {
            lines.append("")
            lines.append("Path: \(conflict.relativePath)")
        }
        alert.informativeText = lines.joined(separator: "\n")

        // Keep Both first: it is the only answer that cannot destroy anything,
        // so it is what Return does.
        alert.addButton(withTitle: "Keep Both")   // first button: default
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")

        let applyToAllButton = NSButton(checkboxWithTitle: "Apply to all", target: nil, action: nil)
        applyToAllButton.state = .off
        applyToAllButton.toolTip = "Use this answer for every remaining conflict in this extraction."
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        applyToAllButton.frame = NSRect(x: 0, y: 0, width: 320, height: 20)
        accessory.addSubview(applyToAllButton)
        alert.accessoryView = accessory

        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        } else {
            response = alert.runModal()
        }

        let resolution: ExtractionConflictResolution
        switch response {
        case .alertFirstButtonReturn: resolution = .keepBoth
        case .alertSecondButtonReturn: resolution = .replace
        case .alertThirdButtonReturn: resolution = .skip
        default: resolution = .cancel
        }

        return Answer(resolution: resolution, applyToAll: applyToAllButton.state == .on)
    }
}
