//
//  LibArchiveBridgeTests.swift
//  ArchiveCoreTests
//
//  Sanity checks that the C bridge is wired up correctly: the version we
//  compile against must match the version we link against, and a reader must
//  be creatable and failable without leaking or crashing.
//

import Foundation
import Testing

@testable import ArchiveCore

@Suite("libarchive bridge")
struct LibArchiveBridgeTests {
    @Test("Compiled and linked libarchive versions agree")
    func versionsAgree() {
        // `compiledVersionNumber` comes from the headers, `versionNumber` from
        // the linked dylib. A mismatch means the two are from different
        // installs, which is a silent ABI hazard.
        let compiled = LibArchive.compiledVersionNumber
        let linked = LibArchive.versionNumber
        #expect(compiled == linked, "headers \(compiled) vs dylib \(linked)")
        #expect(LibArchive.versionString.hasPrefix("libarchive"))
        #expect(LibArchive.versionNumber >= 3000000)
    }

    @Test("A reader can be created and freed")
    func readerLifecycle() throws {
        let stream = try LibArchiveReadStream()
        try stream.enableAutoDetection()
        stream.close()
        stream.free()
    }

    @Test("Opening a non-archive fails with a libarchive diagnostic")
    func nonArchiveFails() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("archivecat-not-an-archive-\(UUID().uuidString).bin")
        try Data("this is definitely not an archive".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try LibArchiveReadStream()
        try stream.enableAutoDetection()

        do {
            // libarchive rejects a non-archive either while opening a seekable
            // file or on the first header read, depending on which format
            // handlers are compiled in. Both paths must produce a typed,
            // human-readable error rather than a crash — and `LibArchiveScanner`
            // maps this one onto "this is not an archive we can read".
            try stream.open(path: url.path(percentEncoded: false))
            while try stream.nextHeader() {}
            Issue.record("expected libarchive to reject a file that is not an archive")
        } catch let failure as LibArchiveFailure {
            #expect(failure.message == "Unrecognized archive format")
            #expect(failure.diagnostic.hasPrefix("libarchive:"))
        }

        stream.free()
    }
}
