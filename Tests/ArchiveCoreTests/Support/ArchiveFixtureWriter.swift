//
//  ArchiveFixtureWriter.swift
//  ArchiveCoreTests
//
//  Writes archive fixtures with libarchive's *write* API.
//
//  This lives in the test target on purpose. ArchiveCat v1 is read-only, and
//  keeping the writer out of `ArchiveCore` is what makes that promise
//  structural rather than a matter of discipline.
//
//  Using libarchive rather than `/usr/bin/zip` and `/usr/bin/tar` means the
//  suite can build archives no command line tool would produce — entries named
//  `../../escape`, a symlink pointing at `/etc`, duplicate paths, 300-byte
//  filenames — which is exactly what the security tests need.
//

import CArchive
import Foundation

/// One entry to place in a fixture archive.
struct FixtureEntry {
    enum Kind {
        case file
        case directory
        case symlink
        case hardlink
        case fifo
    }

    var path: String
    var kind: Kind = .file
    var contents: Data = Data()
    var mode: UInt16? = 0o644
    var uid: UInt32? = 501
    var gid: UInt32? = 20
    var modificationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    var linkTarget: String?

    static func file(_ path: String, _ contents: String, mode: UInt16? = 0o644) -> FixtureEntry {
        FixtureEntry(path: path, kind: .file, contents: Data(contents.utf8), mode: mode)
    }

    static func file(_ path: String, bytes: Int, mode: UInt16? = 0o644) -> FixtureEntry {
        FixtureEntry(path: path, kind: .file, contents: Data(repeating: 0x41, count: bytes), mode: mode)
    }

    static func directory(_ path: String, mode: UInt16? = 0o755) -> FixtureEntry {
        FixtureEntry(path: path, kind: .directory, mode: mode)
    }

    static func symlink(_ path: String, to target: String) -> FixtureEntry {
        FixtureEntry(path: path, kind: .symlink, mode: 0o777, linkTarget: target)
    }

    static func hardlink(_ path: String, to target: String) -> FixtureEntry {
        FixtureEntry(path: path, kind: .hardlink, mode: 0o644, linkTarget: target)
    }

    static func fifo(_ path: String) -> FixtureEntry {
        FixtureEntry(path: path, kind: .fifo, mode: 0o644)
    }
}

/// Archive containers the fixture writer can produce.
enum FixtureFormat {
    case tar
    case tarGzip
    case tarBzip2
    case tarXz
    case tarZstd
    case zip
    case sevenZip
    case cpio

    var fileExtension: String {
        switch self {
        case .tar: return "tar"
        case .tarGzip: return "tar.gz"
        case .tarBzip2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .tarZstd: return "tar.zst"
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .cpio: return "cpio"
        }
    }
}

struct ArchiveFixtureError: Error, CustomStringConvertible {
    let message: String

    var description: String { "fixture writer: \(message)" }
}

enum ArchiveFixtureWriter {

    /// Writes `entries` to `url`.
    static func write(_ entries: [FixtureEntry], format: FixtureFormat, to url: URL) throws {
        guard let archive = archive_write_new() else {
            throw ArchiveFixtureError(message: "archive_write_new() returned NULL")
        }
        defer { archive_write_free(archive) }

        try configureFormat(format, archive: archive)
        try configureFilter(format, archive: archive)

        let openResult = url.path(percentEncoded: false).withCString { path in
            archive_write_open_filename(archive, path)
        }
        guard openResult == ARCHIVE_OK else {
            throw ArchiveFixtureError(message: "archive_write_open_filename failed: \(lastMessage(archive))")
        }

        for entry in entries {
            try write(entry, to: archive)
        }

        guard archive_write_close(archive) == ARCHIVE_OK else {
            throw ArchiveFixtureError(message: "archive_write_close failed: \(lastMessage(archive))")
        }
    }

    // MARK: - Private

    private static func configureFormat(_ format: FixtureFormat, archive: OpaquePointer) throws {
        let result: Int32
        switch format {
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd:
            // pax restricted is what `/usr/bin/tar` writes by default and is
            // what keeps long paths and sub-second timestamps intact.
            result = archive_write_set_format_pax_restricted(archive)
        case .zip:
            result = archive_write_set_format_zip(archive)
        case .sevenZip:
            result = archive_write_set_format_7zip(archive)
        case .cpio:
            result = archive_write_set_format_cpio(archive)
        }
        guard result == ARCHIVE_OK else {
            throw ArchiveFixtureError(message: "could not select format \(format)")
        }
    }

    private static func configureFilter(_ format: FixtureFormat, archive: OpaquePointer) throws {
        let result: Int32
        switch format {
        case .tar, .zip, .sevenZip, .cpio:
            result = archive_write_add_filter_none(archive)
        case .tarGzip:
            result = archive_write_add_filter_gzip(archive)
        case .tarBzip2:
            result = archive_write_add_filter_bzip2(archive)
        case .tarXz:
            result = archive_write_add_filter_xz(archive)
        case .tarZstd:
            result = archive_write_add_filter_zstd(archive)
        }
        // A missing filter (for example zstd in an older libarchive) is not
        // fatal for the caller to detect here; the write call will fail loudly.
        _ = result
    }

    private static func write(_ entry: FixtureEntry, to archive: OpaquePointer) throws {
        guard let archiveEntry = archive_entry_new() else {
            throw ArchiveFixtureError(message: "archive_entry_new() returned NULL")
        }
        defer { archive_entry_free(archiveEntry) }

        entry.path.withCString { archive_entry_set_pathname(archiveEntry, $0) }

        let typeBits: UInt32
        switch entry.kind {
        case .file: typeBits = 0o100000
        case .directory: typeBits = 0o040000
        case .symlink: typeBits = 0o120000
        case .hardlink: typeBits = 0o100000
        case .fifo: typeBits = 0o010000
        }
        archive_entry_set_filetype(archiveEntry, typeBits)

        if let mode = entry.mode {
            archive_entry_set_perm(archiveEntry, mode)
        }
        if let uid = entry.uid {
            archive_entry_set_uid(archiveEntry, Int64(uid))
        }
        if let gid = entry.gid {
            archive_entry_set_gid(archiveEntry, Int64(gid))
        }
        if let date = entry.modificationDate {
            let seconds = Int(date.timeIntervalSince1970)
            archive_entry_set_mtime(archiveEntry, seconds, 0)
        }

        switch entry.kind {
        case .directory, .fifo:
            archive_entry_set_size(archiveEntry, 0)
        case .symlink:
            if let target = entry.linkTarget {
                target.withCString { archive_entry_set_symlink(archiveEntry, $0) }
            }
            archive_entry_set_size(archiveEntry, 0)
        case .hardlink:
            if let target = entry.linkTarget {
                target.withCString { archive_entry_set_hardlink(archiveEntry, $0) }
            }
            archive_entry_set_size(archiveEntry, 0)
        case .file:
            archive_entry_set_size(archiveEntry, Int64(entry.contents.count))
        }

        let headerResult = archive_write_header(archive, archiveEntry)
        guard headerResult == ARCHIVE_OK || headerResult == ARCHIVE_WARN else {
            throw ArchiveFixtureError(
                message: "archive_write_header(\(entry.path)) failed: \(lastMessage(archive))"
            )
        }

        guard entry.kind == .file, !entry.contents.isEmpty else { return }

        let written = entry.contents.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return archive_write_data(archive, base, raw.count)
        }
        guard written == entry.contents.count else {
            throw ArchiveFixtureError(
                message: "archive_write_data(\(entry.path)) wrote \(written) of \(entry.contents.count) bytes"
            )
        }
    }

    private static func lastMessage(_ archive: OpaquePointer) -> String {
        guard let pointer = archive_error_string(archive) else { return "unknown error" }
        return String(cString: pointer)
    }
}
