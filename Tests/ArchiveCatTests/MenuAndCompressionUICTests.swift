//
//  MenuAndCompressionUICTests.swift
//  ArchiveCatTests
//
//  Checks the parts of the new UI that can be verified without clicking:
//  the menu bar wiring and the save-panel accessory's format/level logic.
//

import AppKit
import Testing

@testable import ArchiveCat
@testable import ArchiveCore

@Suite("menu and compression UI wiring")
@MainActor
struct MenuAndCompressionUICTests {

    private func installMenu() -> NSMenu {
        MainMenuBuilder.install()
        return NSApplication.shared.mainMenu ?? NSMenu()
    }

    private func findItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let found = findItem(title, in: submenu) {
                return found
            }
        }
        return nil
    }

    @Test("File ▸ Create Archive… exists with ⇧⌘N")
    func createArchiveMenuItem() throws {
        let menu = installMenu()
        let item = try #require(findItem("Create Archive…", in: menu))
        #expect(item.keyEquivalent == "n")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
        #expect(item.action == #selector(ArchiveCatMenuActions.createArchive(_:)))
        #expect(item.target == nil, "menu items travel the responder chain")
    }

    @Test("Go ▸ Open Archive Inside exists with ⇧⌘O")
    func nestedMenuItem() throws {
        let menu = installMenu()
        let item = try #require(findItem("Open Archive Inside", in: menu))
        #expect(item.keyEquivalent == "o")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
        #expect(item.action == #selector(ArchiveCatMenuActions.openNestedArchive(_:)))
    }

    @Test("the save panel accessory offers the probed formats and a sensible name")
    func accessoryDefaults() throws {
        let formats = ArchiveFormatCatalog.creatableFormats
        try #require(!formats.isEmpty)
        let zip = try #require(formats.first { $0.id == "zip" })

        let panel = NSSavePanel()
        let accessory = CompressionSettingsAccessory(
            panel: panel,
            formats: formats,
            initialFormat: zip,
            suggestedBaseName: "Project"
        )
        _ = accessory.view

        #expect(accessory.currentFileName == "Project.zip")
        #expect(accessory.selectedFormat.id == "zip")
        #expect(accessory.selectedLevel == zip.defaultCompressionLevel)
        #expect(accessory.selectedLevel != nil, "ZIP advertises a level range")
    }

    @Test("formats without a level range report no level")
    func accessoryWithoutLevels() throws {
        let formats = ArchiveFormatCatalog.creatableFormats
        let tar = try #require(formats.first { $0.id == "tar" })
        let panel = NSSavePanel()
        let accessory = CompressionSettingsAccessory(
            panel: panel,
            formats: formats,
            initialFormat: tar,
            suggestedBaseName: "Backup"
        )
        _ = accessory.view
        #expect(accessory.currentFileName == "Backup.tar")
        #expect(accessory.selectedLevel == nil)
    }

    @Test("every creatable format produces its own extension")
    func fileNamePerFormat() {
        for format in ArchiveFormatCatalog.creatableFormats {
            let name = format.fileName(baseName: "Archive")
            #expect(name == "Archive." + format.fileExtension)
            #expect(name.hasSuffix("." + format.fileExtension))
        }
    }

    @Test("capability model does not expose archive modification")
    func noModificationCapability() {
        // A compile-time statement of the product rule: there is no flag for
        // editing, so no code path can offer it.
        let capabilities = ArchiveCapabilities.reading(format: ArchiveFormatInfo(
            formatCode: Int32(0x50000),
            formatName: "ZIP",
            filterCode: 0,
            compressionName: nil,
            hasEncryptedEntries: false,
            isUncompressed: true
        ))
        #expect(capabilities.canRead)
        #expect(capabilities.canCreate == false)
    }
}
