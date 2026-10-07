//
//  FileInspectorTests.swift
//  ArchiveCoreTests
//
//  Content identification is pure logic over bytes, so it is tested directly
//  with synthetic headers rather than real binaries.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("file inspection")
struct FileInspectorTests {

    private func inspect(_ bytes: [UInt8], name: String? = nil) -> FileInspection {
        FileInspector.inspect(head: Data(bytes), fileName: name)
    }

    @Test("Mach-O thin binaries report their architecture")
    func thinMachO() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: [0xCF, 0xFA, 0xED, 0xFE]) // MH_MAGIC_64, little endian
        bytes.append(contentsOf: [0x0C, 0x00, 0x00, 0x01]) // CPU_TYPE_ARM64
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // CPU_SUBTYPE_ARM64_ALL
        bytes.append(contentsOf: [0x02, 0x00, 0x00, 0x00]) // MH_EXECUTE

        let result = inspect(bytes)
        #expect(result.kind == .machOExecutable)
        #expect(result.architectures.map(\.name) == ["arm64"])
        #expect(result.detail?.contains("arm64") == true)
    }

    @Test("arm64e is distinguished from arm64")
    func arm64e() {
        var bytes: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE] // little-endian 64-bit Mach-O
        bytes.append(contentsOf: [0x0C, 0x00, 0x00, 0x01]) // CPU_TYPE_ARM64
        bytes.append(contentsOf: [0x02, 0x00, 0x00, 0x00]) // CPU_SUBTYPE_ARM64E
        bytes.append(contentsOf: [0x06, 0x00, 0x00, 0x00]) // MH_DYLIB

        let result = inspect(bytes)
        #expect(result.kind == .machODynamicLibrary)
        #expect(result.architectures.first?.name == "arm64e")
    }

    @Test("universal binaries list every slice")
    func fatMachO() {
        var bytes: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE] // FAT_MAGIC, big endian
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // two architectures

        // arm64
        bytes.append(contentsOf: [0x01, 0x00, 0x00, 0x0C])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0x00, 0x00, 0x10, 0x00])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // x86_64
        bytes.append(contentsOf: [0x01, 0x00, 0x00, 0x07])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x03])
        bytes.append(contentsOf: [0x00, 0x00, 0x10, 0x00])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        let result = inspect(bytes)
        #expect(result.kind == .machOUniversalBinary)
        #expect(result.architectures.map(\.name) == ["arm64", "x86_64"])
        #expect(result.detail?.contains("2 architectures") == true)
    }

    @Test("ELF object types are recognised")
    func elf() {
        var bytes: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))  // padding to e_type
        bytes.append(contentsOf: [0x03, 0x00])                      // ET_DYN, little endian

        #expect(inspect(bytes).kind == .elfSharedObject)
    }

    @Test("JSON, property lists, XML, scripts and text")
    func textualFormats() {
        #expect(inspect(Array(#"{"name": "ArchiveCat", "entries": [1, 2]}"#.utf8)).kind == .json)
        // A JSON array is valid JSON, not binary data.
        #expect(inspect(Array("[1, 2, 3]".utf8)).kind == .json)
        #expect(inspect(Array("<!DOCTYPE plist PUBLIC><plist version=\"1.0\"></plist>".utf8)).kind == .propertyList)
        #expect(inspect(Array("<?xml version=\"1.0\"?><root/>".utf8)).kind == .xml)
        #expect(inspect(Array("#!/bin/zsh\necho hello\n".utf8)).kind == .script)
        #expect(inspect(Array("Just some notes about the build.\n".utf8)).kind == .text)
    }

    @Test("archive magic is recognised even with no file name")
    func archiveMagic() {
        #expect(inspect([0x50, 0x4B, 0x03, 0x04, 0x00]).kind == .zipArchive)
        #expect(inspect([0x1F, 0x8B, 0x08, 0x00]).kind == .gzipArchive)
        #expect(inspect([0x42, 0x5A, 0x68, 0x39]).kind == .bzip2Archive)
        #expect(inspect([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]).kind == .xzArchive)
        #expect(inspect([0x28, 0xB5, 0x2F, 0xFD, 0x00]).kind == .zstdArchive)
        #expect(inspect([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]).kind == .sevenZipArchive)
    }

    @Test("images and databases")
    func binaryFormats() {
        #expect(inspect([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).kind == .image)
        #expect(inspect([0xFF, 0xD8, 0xFF, 0xE0]).kind == .image)
        #expect(inspect(Array("SQLite format 3\0".utf8)).kind == .sqliteDatabase)
        #expect(inspect(Array("%PDF-1.7".utf8)).kind == .pdfDocument)
        #expect(inspect(Array("!<arch>\n".utf8)).kind == .staticLibrary)
    }

    @Test("an empty file is empty, not unknown")
    func emptyFile() {
        #expect(inspect([]).kind == .empty)
    }

    @Test("a NUL byte marks binary data")
    func binaryData() {
        #expect(inspect([0x00, 0x01, 0x02, 0x03]).kind == .binary)
    }
}

@Suite("POSIX file type bits")
struct POSIXFileTypeTests {
    @Test("the constants match sys/stat.h")
    func matchesStat() {
        // The `AE_IF*` macros from libarchive cannot be imported into Swift, so
        // ArchiveCore restates them; this keeps the restatement honest.
        #expect(POSIXFileType.mask == S_IFMT)
        #expect(POSIXFileType.regular == S_IFREG)
        #expect(POSIXFileType.directory == S_IFDIR)
        #expect(POSIXFileType.symbolicLink == S_IFLNK)
        #expect(POSIXFileType.fifo == S_IFIFO)
        #expect(POSIXFileType.socket == S_IFSOCK)
        #expect(POSIXFileType.characterDevice == S_IFCHR)
        #expect(POSIXFileType.blockDevice == S_IFBLK)
    }

    @Test("mode bits split into type and permissions")
    func splitting() {
        let mode = mode_t(0o100644)
        #expect(POSIXFileType.of(mode: mode) == POSIXFileType.regular)
        #expect(mode & 0o7777 == 0o644)
    }
}
