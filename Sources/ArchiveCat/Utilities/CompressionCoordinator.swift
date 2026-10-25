//
//  CompressionCoordinator.swift
//  ArchiveCat
//
//  Turns "Create Archive…" into a real archive: pick sources, pick a
//  destination and format, watch progress, cancel if needed.
//
//  Everything expensive happens in `ArchiveCore.CompressionService`; this file
//  only collects the user's intent and shows what is happening. The save panel
//  is also where the "replace an existing file?" question is answered: macOS
//  asks, and only a confirmed answer sets `overwriteExisting`, so no archive is
//  ever written over a file the user did not agree to replace.
//

import AppKit
import ArchiveCore
import UniformTypeIdentifiers

@MainActor
enum CompressionCoordinator {

    // MARK: - Entry point

    /// Runs the whole "create an archive" flow.
    static func createArchive(from window: NSWindow?) {
        Task { await run(from: window) }
    }

    // MARK: - Flow

    private struct Settings {
        let destination: URL
        let format: ArchiveFormatDescriptor
        let level: Int?
        let overwriteExisting: Bool
    }

    private static func run(from window: NSWindow?) async {
        let formats = ArchiveFormatCatalog.creatableFormats
        guard !formats.isEmpty else {
            ErrorPresenter.present(ArchiveError.compressionFailed(
                destination: URL(fileURLWithPath: NSHomeDirectory()),
                reason: "This build of libarchive has no usable archive writer.",
                technicalDetails: "Every creatable format failed its capability probe."
            ))
            return
        }

        guard let sources = await chooseSources(from: window), !sources.isEmpty else { return }
        guard let settings = await chooseDestination(for: sources, formats: formats, from: window) else { return }
        await compress(sources: sources, settings: settings, from: window)
    }

    // MARK: - Source picker

    private static func chooseSources(from window: NSWindow?) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "Compress"
        panel.message = "Choose files and folders to compress into a new archive."

        let response = await present(panel, on: window)
        guard response == .OK else { return nil }
        return panel.urls
    }

    // MARK: - Destination picker

    private static func chooseDestination(
        for sources: [URL],
        formats: [ArchiveFormatDescriptor],
        from window: NSWindow?
    ) async -> Settings? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Create Archive"
        panel.message = "Choose a name and location for the new archive."
        panel.prompt = "Create"

        let initialFormat = rememberedFormat(in: formats) ?? formats[0]
        let accessory = CompressionSettingsAccessory(
            panel: panel,
            formats: formats,
            initialFormat: initialFormat,
            suggestedBaseName: suggestedBaseName(for: sources)
        )
        panel.accessoryView = accessory.view
        panel.nameFieldStringValue = accessory.currentFileName

        let response = await present(panel, on: window)
        guard response == .OK, let destination = panel.url else { return nil }

        remember(accessory.selectedFormat)

        // The save panel asks before returning OK when the file exists, so an
        // existing destination at this point means the user confirmed replacing
        // it. Anything else must use the atomic no-clobber path.
        let existed = FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))

        return Settings(
            destination: destination,
            format: accessory.selectedFormat,
            level: accessory.selectedLevel,
            overwriteExisting: existed
        )
    }

    // MARK: - The operation

    private static func compress(sources: [URL], settings: Settings, from window: NSWindow?) async {
        let sheet = CompressionProgressSheet(title: "Creating “\(settings.destination.lastPathComponent)”")
        sheet.present(on: window)

        let service = CompressionService()
        let options = CompressionOptions(
            formatID: settings.format.id,
            compressionLevel: settings.level,
            overwriteExisting: settings.overwriteExisting
        )

        let task = Task {
            try await service.compress(
                sources: sources,
                to: settings.destination,
                options: options
            ) { progress in
                Task { @MainActor in
                    sheet.update(progress)
                }
            }
        }
        sheet.onCancel = { task.cancel() }

        do {
            let result = try await task.value
            sheet.dismiss()

            if !result.warnings.isEmpty {
                await presentCreationReport(result, on: window)
            }
            // Showing the archive that was just created is the most useful
            // confirmation there is: it is also the first read-back of the file.
            DocumentOpener.shared.open([result.destination])
        } catch {
            sheet.dismiss()
            if (error as? ArchiveError)?.isCancellation == true {
                // The user pressed Cancel; saying so with an alert would be noise.
                return
            }
            ErrorPresenter.present(error)
        }
    }

    private static func presentCreationReport(_ result: CompressionResult, on window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Archive created"
        alert.informativeText = "\(result.itemCount.formatted()) items were added to “\(result.destination.lastPathComponent)”."
            + "\n\n"
            + result.warnings.joined(separator: "\n")
        alert.addButton(withTitle: "OK")

        if let window, window.isVisible {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { _ in continuation.resume() }
            }
        } else {
            alert.runModal()
        }
    }

    // MARK: - Panel plumbing

    private static func present(_ panel: NSSavePanel, on window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        }
        return panel.runModal()
    }

    private static func present(_ panel: NSOpenPanel, on window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        }
        return panel.runModal()
    }

    // MARK: - Suggestions and memory

    /// `Project.zip` for one selected folder, `Archive.zip` for a mixed
    /// selection.
    private static func suggestedBaseName(for sources: [URL]) -> String {
        guard sources.count == 1, let source = sources.first else { return "Archive" }
        let name = (source.lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty ? "Archive" : name
    }

    private static let rememberedFormatKey = "ArchiveCatLastCompressionFormatID"

    private static func rememberedFormat(in formats: [ArchiveFormatDescriptor]) -> ArchiveFormatDescriptor? {
        guard let identifier = UserDefaults.standard.string(forKey: rememberedFormatKey) else { return nil }
        return formats.first { $0.id == identifier }
    }

    private static func remember(_ format: ArchiveFormatDescriptor) {
        UserDefaults.standard.set(format.id, forKey: rememberedFormatKey)
    }
}

// MARK: - Save panel accessory

/// Format and compression-level controls inside the standard save panel.
///
/// Using the system panel (rather than a custom window) means the replace
/// question, the destination validation and the sandbox access grant are all
/// handled by macOS exactly as users expect.
@MainActor
final class CompressionSettingsAccessory: NSObject {

    let view: NSView
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let levelLabel = NSTextField(labelWithString: "Compression:")

    private let formats: [ArchiveFormatDescriptor]
    private weak var panel: NSSavePanel?
    private let initialSuggestedFileName: String
    private var levelValues: [Int] = []

    private(set) var selectedFormat: ArchiveFormatDescriptor

    var currentFileName: String { initialSuggestedFileName }

    var selectedLevel: Int? {
        guard !levelValues.isEmpty else { return nil }
        let index = levelPopup.indexOfSelectedItem
        guard levelValues.indices.contains(index) else { return selectedFormat.defaultCompressionLevel }
        return levelValues[index]
    }

    init(
        panel: NSSavePanel,
        formats: [ArchiveFormatDescriptor],
        initialFormat: ArchiveFormatDescriptor,
        suggestedBaseName: String
    ) {
        self.panel = panel
        self.formats = formats
        self.selectedFormat = initialFormat
        self.initialSuggestedFileName = initialFormat.fileName(baseName: suggestedBaseName)
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 86))
        super.init()

        buildInterface()
    }

    private func buildInterface() {
        formatPopup.removeAllItems()
        for format in formats {
            formatPopup.addItem(withTitle: format.displayName)
            formatPopup.lastItem?.representedObject = format.id
        }
        if let index = formats.firstIndex(where: { $0.id == selectedFormat.id }) {
            formatPopup.selectItem(at: index)
        }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        levelLabel.alignment = .right
        levelPopup.target = self
        levelPopup.action = #selector(levelChanged)

        let note = NSTextField(wrappingLabelWithString:
            "Folders keep their contents and symlinks are stored as links, never followed.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Format:"), formatPopup],
            [levelLabel, levelPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            formatPopup.widthAnchor.constraint(equalToConstant: 240),
            levelPopup.widthAnchor.constraint(equalToConstant: 240),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])

        rebuildLevelPopup()
    }

    private func rebuildLevelPopup() {
        levelValues = []
        levelPopup.removeAllItems()

        guard let range = selectedFormat.compressionLevelRange else {
            levelLabel.isHidden = true
            levelPopup.isHidden = true
            return
        }

        levelLabel.isHidden = false
        levelPopup.isHidden = false

        // Offer every level the format accepts. The endpoints are labelled so a
        // user who does not think in numbers can still choose sensibly.
        for level in range {
            levelValues.append(level)
            let title: String
            switch level {
            case range.lowerBound where range.lowerBound == range.upperBound:
                title = "Level \(level)"
            case range.lowerBound:
                title = "Level \(level) — fastest"
            case range.upperBound:
                title = "Level \(level) — best"
            default:
                title = "Level \(level)"
            }
            levelPopup.addItem(withTitle: title)
        }

        if let defaultLevel = selectedFormat.defaultCompressionLevel,
           let index = levelValues.firstIndex(of: defaultLevel) {
            levelPopup.selectItem(at: index)
        }
    }

    @objc private func formatChanged() {
        let index = formatPopup.indexOfSelectedItem
        guard formats.indices.contains(index) else { return }
        selectedFormat = formats[index]

        rebuildLevelPopup()

        // Carry the user's typed name across, replacing only the extension.
        guard let panel else { return }
        let current = panel.nameFieldStringValue
        let base = stripKnownExtension(from: current)
        panel.nameFieldStringValue = selectedFormat.fileName(baseName: base.isEmpty ? "Archive" : base)
    }

    @objc private func levelChanged() {
        // The selected level is read when the panel is accepted; nothing to do.
    }

    /// Removes the longest matching known extension, so `.tar.gz` wins over `.gz`.
    private func stripKnownExtension(from fileName: String) -> String {
        let lowered = fileName.lowercased()
        let suffixes = formats
            .map { "." + $0.fileExtension }
            .sorted { $0.count > $1.count }
        for suffix in suffixes where lowered.hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count))
        }
        return (fileName as NSString).deletingPathExtension
    }
}
