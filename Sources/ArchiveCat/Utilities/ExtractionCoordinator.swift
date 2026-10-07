//
//  ExtractionCoordinator.swift
//  ArchiveCat
//
//  Turns "Extract…" into a running extraction: destination picker, a real
//  question when the destination already has files, then the work itself.
//
//  The conflict sheet is not cosmetic. The engine never overwrites silently, so
//  when a conflict exists the user is asked *before* anything is written, and
//  "Cancel" leaves the destination untouched.
//

import AppKit
import ArchiveCore
import UniformTypeIdentifiers

@MainActor
enum ExtractionCoordinator {

    /// How the user wants an extraction to proceed.
    private struct Decision {
        var destination: URL
        var policy: ExtractionConflictPolicy
    }

    // MARK: - Entry points

    /// Extract the current selection, asking for a destination.
    static func extractSelection(from model: BrowserViewModel, window: NSWindow?) {
        let entries = model.selectedEntries
        guard !entries.isEmpty else { return }
        Task { await run(entries: entries, model: model, window: window, label: "Extracting") }
    }

    /// Extract the current selection straight to ~/Downloads.
    static func extractSelectionToDownloads(from model: BrowserViewModel, window: NSWindow?) {
        let entries = model.selectedEntries
        guard !entries.isEmpty else { return }
        guard let downloads = downloadsDirectory() else {
            presentError(ArchiveError.destinationUnusable(
                url: URL(fileURLWithPath: NSHomeDirectory()),
                reason: "The Downloads folder could not be located."
            ), window: window)
            return
        }
        model.extract(entries: entries, destination: downloads, options: .default, label: "Extracting to Downloads")
    }

    /// Extract every entry in the archive. Explicitly requested, never automatic.
    static func extractEntireArchive(from model: BrowserViewModel, window: NSWindow?) {
        guard let document = model.document else { return }
        let entries = document.entries.filter { $0.safety.isSafe }
        guard !entries.isEmpty else { return }
        Task { await run(entries: entries, model: model, window: window, label: "Extracting archive") }
    }

    // MARK: - Flow

    private static func run(
        entries: [ArchiveEntry],
        model: BrowserViewModel,
        window: NSWindow?,
        label: String
    ) async {
        guard let decision = await decideDestination(entries: entries, window: window) else { return }

        let options = ExtractionOptions(
            conflictPolicy: decision.policy,
            preservePermissions: true,
            preserveModificationDates: true,
            stripSetuidAndSetgid: true,
            checkAvailableSpace: true,
            limits: .unlimited,
            stripLeadingPathComponents: 0,
            extractSpecialFiles: false
        )

        model.extract(entries: entries, destination: decision.destination, options: options, label: label)
    }

    /// Asks for a destination and, if needed, how to resolve conflicts.
    ///
    /// - Returns: `nil` when the user cancelled.
    private static func decideDestination(entries: [ArchiveEntry], window: NSWindow?) async -> Decision? {
        guard let destination = chooseDestination(window: window) else { return nil }

        // Preflight with the *expanded* selection so folder selections report
        // the files inside them, not just the folder.
        let conflicts = ExtractionPreflight.conflicts(entries: entries, in: destination)
        guard !conflicts.isEmpty else {
            return Decision(destination: destination, policy: .replace)
        }

        guard let policy = askAboutConflicts(conflicts: conflicts, destination: destination, window: window) else {
            return nil
        }
        return Decision(destination: destination, policy: policy)
    }

    // MARK: - Pickers and questions

    /// Native destination picker.
    private static func chooseDestination(window: NSWindow?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Extract"
        panel.message = "Choose where to extract the selected items."
        panel.directoryURL = lastUsedDestination() ?? downloadsDirectory()

        if let window {
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return nil }
            rememberDestination(url)
            return url
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        rememberDestination(url)
        return url
    }

    /// Asks how to handle files that already exist.
    ///
    /// - Returns: the chosen policy, or `nil` when the user cancelled.
    private static func askAboutConflicts(
        conflicts: [ExtractionConflict],
        destination: URL,
        window: NSWindow?
    ) -> ExtractionConflictPolicy? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = conflicts.count == 1
            ? "An item named “\(conflicts[0].entry.name)” already exists."
            : "\(conflicts.count) items already exist in “\(destination.lastPathComponent)”."

        let preview = conflicts.prefix(6).map { "• \($0.entry.path)" }.joined(separator: "\n")
        let remainder = conflicts.count > 6 ? "\n…and \(conflicts.count - 6) more." : ""
        alert.informativeText = "\(preview)\(remainder)\n\nChoose how to continue. Nothing has been written yet."

        alert.addButton(withTitle: "Keep Both")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Replace")     // .alertSecondButtonReturn
        alert.addButton(withTitle: "Skip")        // .alertThirdButtonReturn
        alert.addButton(withTitle: "Cancel")

        // Modal rather than window-modal: the question is about the
        // destination, not about the document window, and it must be answered
        // before anything is written.
        _ = window
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
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

    private static func presentError(_ error: ArchiveError, window: NSWindow?) {
        _ = window
        ErrorPresenter.present(error)
    }
}
