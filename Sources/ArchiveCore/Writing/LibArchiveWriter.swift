//
//  LibArchiveWriter.swift
//  ArchiveCore
//
//  The write half of the libarchive bridge.
//
//  Rules, mirroring the reader bridge:
//   * one owner per `struct archive *`, freed in `deinit`, so a throw cannot
//     leak a writer;
//   * every libarchive status is checked; nothing is "best effort";
//   * source files are opened with `O_NOFOLLOW` and their size is taken from
//     `fstat` on the descriptor, not from the plan, so a file swapped for a
//     symlink (or replaced mid-run) cannot redirect a read;
//   * payloads stream in fixed-size blocks: peak memory is one block, whatever
//     the file size.
//
//  This type writes into a path it is given. It knows nothing about the
//  destination the user chose, about temporary files or about atomic commit —
//  `CompressionService` owns those, because they are policy rather than format.
//

import CArchive
import Darwin
import Foundation

// MARK: - Entry description

/// One item to place in the archive being written.
struct ArchiveWriteEntry: Sendable {
    enum Content: Sendable {
        /// A regular file to stream from disk, identified by a canonical,
        /// slash-free POSIX path.
        case file(sourcePath: String)
        /// A directory. Its path carries a trailing slash.
        case directory
        /// A symbolic link, stored as a link. The target is never read.
        case symbolicLink(target: String)
    }

    let path: String
    let content: Content
    let modificationDate: Date?
    let posixMode: UInt16?
    let uid: UInt32?
    let gid: UInt32?
}

/// A failure reported by libarchive's write API.
struct LibArchiveWriterFailure: Error, Sendable, CustomStringConvertible {
    let message: String
    let status: Int32
    let errorNumber: Int32

    var description: String {
        if errorNumber != 0 {
            return "libarchive: \(message) (errno \(errorNumber): \(String(cString: strerror(errorNumber))))"
        }
        return "libarchive: \(message)"
    }
}

// MARK: - Writer

/// Owns one libarchive write stream.
///
/// Not `Sendable`: a writer is stateful and must be used from the task that
/// created it. `CompressionService` confines it to a single detached task.
final class LibArchiveWriter {

    /// 256 KiB keeps syscall and libarchive overhead low while capping memory.
    static let blockSize = 256 * 1024

    private var handle: OpaquePointer?
    private let format: ArchiveFormatDescriptor

    init(format: ArchiveFormatDescriptor, compressionLevel: Int?) throws {
        self.format = format
        guard let handle = archive_write_new() else {
            throw LibArchiveWriterFailure(message: "archive_write_new() returned NULL", status: ARCHIVE_FATAL, errorNumber: ENOMEM)
        }
        self.handle = handle
        do {
            try Self.configure(handle, format: format, compressionLevel: compressionLevel)
        } catch {
            archive_write_free(handle)
            self.handle = nil
            throw error
        }
    }

    deinit {
        abort()
    }

    // MARK: Lifecycle

    /// Opens the output file. libarchive creates/truncates it.
    func openOutput(path: String) throws {
        guard let handle else { throw failure("writer used after close") }
        let status = path.withCString { archive_write_open_filename(handle, $0) }
        try Self.check(status, "open output", handle: handle)
    }

    /// Writes one entry and its payload.
    ///
    /// - Parameter onBytes: called with the number of source bytes consumed for
    ///   each block, so the caller can report progress inside a large file.
    func write(_ entry: ArchiveWriteEntry, onBytes: ((Int) -> Void)? = nil) throws {
        guard let handle else { throw failure("writer used after close") }
        guard let archiveEntry = archive_entry_new() else {
            throw failure("archive_entry_new() returned NULL")
        }
        defer { archive_entry_free(archiveEntry) }

        entry.path.withCString { archive_entry_set_pathname(archiveEntry, $0) }

        if let mode = entry.posixMode {
            archive_entry_set_perm(archiveEntry, mode_t(mode))
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

        switch entry.content {
        case .directory:
            archive_entry_set_filetype(archiveEntry, UInt32(POSIXFileType.directory))
            archive_entry_set_size(archiveEntry, 0)
            try writeHeader(archiveEntry, path: entry.path)

        case let .symbolicLink(target):
            archive_entry_set_filetype(archiveEntry, UInt32(POSIXFileType.symbolicLink))
            target.withCString { archive_entry_set_symlink(archiveEntry, $0) }
            archive_entry_set_size(archiveEntry, 0)
            try writeHeader(archiveEntry, path: entry.path)

        case let .file(sourcePath):
            let descriptor = try Self.openRegularFile(path: sourcePath)
            defer { close(descriptor) }

            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                let errorNumber = errno
                throw LibArchiveWriterFailure(
                    message: "fstat failed for \((sourcePath as NSString).lastPathComponent)",
                    status: ARCHIVE_FATAL,
                    errorNumber: errorNumber
                )
            }
            guard POSIXFileType.isRegular(info.st_mode) else {
                throw LibArchiveWriterFailure(
                    message: "\((sourcePath as NSString).lastPathComponent) is not a regular file",
                    status: ARCHIVE_FATAL,
                    errorNumber: EINVAL
                )
            }

            // The descriptor's size is authoritative: it is what will actually
            // be read, regardless of what the planning pass saw.
            let size = Int64(info.st_size)
            archive_entry_set_filetype(archiveEntry, UInt32(POSIXFileType.regular))
            archive_entry_set_size(archiveEntry, size)
            try writeHeader(archiveEntry, path: entry.path)
            try stream(descriptor: descriptor, expectedBytes: size, onBytes: onBytes)
        }

        let status = archive_write_finish_entry(handle)
        try Self.check(status, "finish entry \(entry.path)", handle: handle)
    }

    /// Closes the archive, flushing the trailer. Safe to call once.
    func finish() throws {
        guard let handle else { return }
        self.handle = nil
        let status = archive_write_close(handle)
        let errorNumber = archive_errno(handle)
        let message = archive_error_string(handle).map { String(cString: $0) } ?? "unknown libarchive error"
        archive_write_free(handle)

        guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
            throw LibArchiveWriterFailure(message: message, status: status, errorNumber: errorNumber)
        }
    }

    /// Abandons the archive. The partial file is the caller's problem.
    func abort() {
        guard let handle else { return }
        self.handle = nil
        archive_write_free(handle)
    }

    // MARK: Capability probe

    /// Whether this build can write `format`.
    ///
    /// Creating a writer is enough: format selection and adding the filter are
    /// where a missing codec reports itself, and nothing is written to disk.
    static func probe(_ format: ArchiveFormatDescriptor) -> Bool {
        guard let handle = archive_write_new() else { return false }
        defer { archive_write_free(handle) }
        do {
            try configure(handle, format: format, compressionLevel: format.defaultCompressionLevel)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func configure(
        _ handle: OpaquePointer,
        format: ArchiveFormatDescriptor,
        compressionLevel: Int?
    ) throws {
        switch format.container {
        case .zip:
            try check(archive_write_set_format_zip(handle), "select ZIP format", handle: handle)
        case .tar:
            try check(archive_write_set_format_pax_restricted(handle), "select TAR format", handle: handle)
        }

        switch format.filter {
        case .none:
            try check(archive_write_add_filter_none(handle), "add no filter", handle: handle)
        case .gzip:
            try check(archive_write_add_filter_gzip(handle), "add gzip filter", handle: handle)
        case .bzip2:
            try check(archive_write_add_filter_bzip2(handle), "add bzip2 filter", handle: handle)
        case .xz:
            try check(archive_write_add_filter_xz(handle), "add xz filter", handle: handle)
        case .zstd:
            try check(archive_write_add_filter_zstd(handle), "add zstd filter", handle: handle)
        }

        guard let level = compressionLevel else { return }

        switch format.container {
        case .zip:
            // ZIP compresses members itself; level 0 means "store".
            if level <= 0 {
                try check(
                    archive_write_set_format_option(handle, "zip", "compression", "store"),
                    "configure ZIP compression",
                    handle: handle
                )
            } else {
                try check(
                    archive_write_set_format_option(handle, "zip", "compression", "deflate"),
                    "configure ZIP compression",
                    handle: handle
                )
                try check(
                    archive_write_set_format_option(handle, "zip", "compression-level", String(level)),
                    "configure ZIP level",
                    handle: handle
                )
            }
        case .tar:
            if let filterName = format.filter.optionName {
                try check(
                    archive_write_set_filter_option(handle, filterName, "compression-level", String(level)),
                    "configure \(filterName) level",
                    handle: handle
                )
            }
        }
    }

    private func writeHeader(_ entry: OpaquePointer, path: String) throws {
        guard let handle else { throw failure("writer used after close") }
        let status = archive_write_header(handle, entry)
        // ARCHIVE_WARN means "written, but the format could not store something".
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
            let message = archive_error_string(handle).map { String(cString: $0) } ?? "unknown libarchive error"
            throw LibArchiveWriterFailure(message: "header for \(path): \(message)", status: status, errorNumber: archive_errno(handle))
        }
    }

    private func stream(descriptor: Int32, expectedBytes: Int64, onBytes: ((Int) -> Void)?) throws {
        guard let handle else { throw failure("writer used after close") }
        var buffer = [UInt8](repeating: 0, count: Self.blockSize)
        var remaining = expectedBytes

        while remaining > 0 {
            if Task.isCancelled { throw ArchiveError.cancelled }

            let wanted = Int(min(Int64(buffer.count), remaining))
            let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return read(descriptor, base, wanted)
            }

            if readCount < 0 {
                if errno == EINTR { continue }
                throw LibArchiveWriterFailure(
                    message: "reading a source file failed",
                    status: ARCHIVE_FATAL,
                    errorNumber: errno
                )
            }
            if readCount == 0 {
                // The file shrank between planning and writing. Writing a short
                // payload would produce a corrupt archive, so fail loudly.
                throw LibArchiveWriterFailure(
                    message: "a source file became shorter while it was being archived",
                    status: ARCHIVE_FATAL,
                    errorNumber: EIO
                )
            }

            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < readCount {
                    let written = archive_write_data(
                        handle,
                        raw.baseAddress!.advanced(by: offset),
                        readCount - offset
                    )
                    if written < 0 {
                        let message = archive_error_string(handle).map { String(cString: $0) } ?? "unknown libarchive error"
                        throw LibArchiveWriterFailure(
                            message: "writing entry data: \(message)",
                            status: ARCHIVE_FATAL,
                            errorNumber: archive_errno(handle)
                        )
                    }
                    if written == 0 { break }
                    offset += written
                }
                guard offset == readCount else {
                    throw LibArchiveWriterFailure(
                        message: "the archive writer accepted only \(offset) of \(readCount) bytes",
                        status: ARCHIVE_FATAL,
                        errorNumber: EIO
                    )
                }
            }

            remaining -= Int64(readCount)
            onBytes?(readCount)
        }
    }

    private static func openRegularFile(path: String) throws -> Int32 {
        let name = (path as NSString).lastPathComponent
        let descriptor = path.withCString { pointer in
            open(pointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let errorNumber = errno
            throw LibArchiveWriterFailure(
                message: "could not open \(name)",
                status: ARCHIVE_FATAL,
                errorNumber: errorNumber
            )
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let errorNumber = errno
            close(descriptor)
            throw LibArchiveWriterFailure(
                message: "could not inspect \(name)",
                status: ARCHIVE_FATAL,
                errorNumber: errorNumber
            )
        }
        guard POSIXFileType.isRegular(info.st_mode) else {
            close(descriptor)
            throw LibArchiveWriterFailure(
                message: "\(name) is not a regular file",
                status: ARCHIVE_FATAL,
                errorNumber: EINVAL
            )
        }
        return descriptor
    }

    private func failure(_ message: String) -> LibArchiveWriterFailure {
        LibArchiveWriterFailure(message: message, status: ARCHIVE_FATAL, errorNumber: 0)
    }

    private static func check(_ status: Int32, _ context: String, handle: OpaquePointer) throws {
        guard status == ARCHIVE_OK else {
            let message = archive_error_string(handle).map { String(cString: $0) } ?? "unknown libarchive error"
            throw LibArchiveWriterFailure(
                message: "\(context): \(message)",
                status: status,
                errorNumber: archive_errno(handle)
            )
        }
    }
}
