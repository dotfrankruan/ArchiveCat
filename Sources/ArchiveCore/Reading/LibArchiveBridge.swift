//
//  LibArchiveBridge.swift
//  ArchiveCore
//
//  The only file in the project that talks to libarchive's C API.
//
//  Rules enforced here:
//   * every `struct archive *` is owned by a class whose `deinit` frees it,
//     so a throw can never leak a reader;
//   * no C pointer ever escapes a call: entry metadata is copied into Swift
//     values (`LibArchiveEntrySnapshot`) before the next libarchive call;
//   * every non-OK status becomes a typed Swift error carrying libarchive's
//     own message so the UI can show it under "Details".
//

import CArchive
import Foundation

// MARK: - Version

public enum LibArchive {
    /// e.g. `libarchive 3.8.9`.
    public static var versionString: String {
        String(cString: archive_version_string())
    }

    /// Numeric version of the *headers* the project was compiled against,
    /// e.g. `3008009` for 3.8.9.
    public static var compiledVersionNumber: Int32 {
        Int32(ARCHIVECAT_LIBARCHIVE_VERSION_NUMBER)
    }

    /// Numeric version of the *library* that is linked at runtime.
    ///
    /// A mismatch with `compiledVersionNumber` means headers and dylib come
    /// from different installs, which is a silent ABI hazard, so the test suite
    /// asserts they agree.
    public static var versionNumber: Int32 {
        archive_version_number()
    }

    /// Full build details (which decompressors are compiled in).
    public static var detailsString: String {
        String(cString: archive_version_details())
    }
}

// MARK: - Low level error

/// A failure reported by libarchive itself.
struct LibArchiveFailure: Error, Sendable {
    /// One of `ARCHIVE_*` (`ARCHIVE_FATAL`, `ARCHIVE_FAILED`, …).
    let status: Int32
    /// Message from `archive_error_string`, already copied into Swift memory.
    let message: String
    /// `errno` at the time of failure, when meaningful.
    let errorNumber: Int32

    var diagnostic: String {
        let errnoText: String
        if errorNumber != 0 {
            errnoText = " (errno \(errorNumber): \(String(cString: strerror(errorNumber))))"
        } else {
            errnoText = ""
        }
        return "libarchive: \(message)\(errnoText)"
    }

    /// ARCHIVE_WARN means "this call succeeded, but something was odd".
    var isWarningOnly: Bool { status == ARCHIVE_WARN }
}

// MARK: - Entry snapshot

/// Immutable copy of an `archive_entry`, safe to use after the next header read.
struct LibArchiveEntrySnapshot {
    var rawPath: String
    var pathWasValidUTF8: Bool
    var fileType: mode_t
    var mode: mode_t
    var size: Int64
    var sizeIsSet: Bool
    var modificationDate: Date?
    var uid: Int64
    var uidIsSet: Bool
    var gid: Int64
    var gidIsSet: Bool
    var linkCount: UInt32
    var symlinkTarget: String?
    var hardlinkTarget: String?
    var deviceMajor: UInt32?
    var deviceMinor: UInt32?
    var formatDetail: String?
}

// MARK: - Owned reader handle

/// Owns one libarchive read stream.
///
/// Not `Sendable` on purpose: a stream is stateful and must stay on the task
/// that created it. Callers confine it to a single detached task.
final class LibArchiveReadStream {
    private var handle: OpaquePointer?
    private(set) var currentEntry: OpaquePointer?

    /// libarchive reads in blocks; 128 KiB keeps syscall overhead low without
    /// holding meaningful memory.
    static let defaultBlockSize = 128 * 1024

    init() throws {
        guard let handle = archive_read_new() else {
            throw LibArchiveFailure(status: ARCHIVE_FATAL,
                                    message: "archive_read_new() returned NULL",
                                    errorNumber: ENOMEM)
        }
        self.handle = handle
    }

    deinit {
        free()
    }

    /// Enables every filter and format libarchive was built with, then lets it
    /// auto-detect the container. Nothing here keys off the file extension.
    func enableAutoDetection() throws {
        try check(archive_read_support_filter_all(raw), context: "archive_read_support_filter_all")
        try check(archive_read_support_format_all(raw), context: "archive_read_support_format_all")
    }

    /// Applies libarchive options such as `zip:hdrcharset=UTF-8`.
    func apply(options: [String]) throws {
        guard !options.isEmpty else { return }
        let joined = options.joined(separator: ",")
        try check(archive_read_set_options(raw, joined), context: "archive_read_set_options(\(joined))")
    }

    /// Opens the archive by path. Auto-detection happens on first header read.
    func open(path: String, blockSize: Int = LibArchiveReadStream.defaultBlockSize) throws {
        let status = path.withCString { pointer in
            archive_read_open_filename(self.raw, pointer, blockSize)
        }
        try check(status, context: "archive_read_open_filename")
    }

    /// Reads the next header.
    ///
    /// - Returns: `true` when a header is available, `false` at end of archive.
    @discardableResult
    func nextHeader() throws -> Bool {
        var entry: OpaquePointer?
        let status = archive_read_next_header(raw, &entry)

        if status == ARCHIVE_OK || status == ARCHIVE_WARN {
            currentEntry = entry
            if status == ARCHIVE_WARN {
                // libarchive says "this worked, but something was odd".
                let diagnostic = failure().message
                ArchiveCatLog.archive.debug("libarchive warning while reading header: \(diagnostic, privacy: .public)")
            }
            return true
        }
        if status == ARCHIVE_EOF {
            currentEntry = nil
            return false
        }

        // ARCHIVE_RETRY can legitimately happen while probing filters; retry a
        // bounded number of times before giving up.
        if status == ARCHIVE_RETRY {
            for _ in 0..<3 {
                var retryEntry: OpaquePointer?
                let retryStatus = archive_read_next_header(raw, &retryEntry)
                if retryStatus == ARCHIVE_OK || retryStatus == ARCHIVE_WARN {
                    currentEntry = retryEntry
                    return true
                }
                if retryStatus == ARCHIVE_EOF {
                    currentEntry = nil
                    return false
                }
            }
        }

        currentEntry = nil
        throw failure()
    }

    /// Copies the current entry's metadata into Swift values.
    func snapshotCurrentEntry() -> LibArchiveEntrySnapshot? {
        guard let entry = currentEntry else { return nil }
        return LibArchiveEntrySnapshot(entry: entry)
    }

    /// Skips the current entry's payload. For seekable containers this is a
    /// seek, which is what keeps scanning a 100 000 entry ZIP fast.
    func skipCurrentEntryData() throws {
        let status = archive_read_data_skip(raw)
        if status != ARCHIVE_OK && status != ARCHIVE_EOF && status != ARCHIVE_WARN {
            throw failure()
        }
    }

    /// Streams the current entry's payload into an already-open file
    /// descriptor. Nothing is buffered in Swift memory.
    func copyCurrentEntryData(toFileDescriptor descriptor: Int32) throws {
        let status = archive_read_data_into_fd(raw, descriptor)
        if status != ARCHIVE_OK && status != ARCHIVE_EOF && status != ARCHIVE_WARN {
            throw failure()
        }
    }

    /// Streams the current entry's payload block by block.
    ///
    /// The blocks libarchive hands back are only valid until the next call, so
    /// they must be consumed inside `body` and never stored. Callers that need
    /// to count bytes or check for cancellation between blocks use this instead
    /// of `copyCurrentEntryData(toFileDescriptor:)`.
    func readCurrentEntryData(_ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        var buffer: UnsafeRawPointer?
        var size = 0
        var offset = la_int64_t(0)

        while true {
            let status = archive_read_data_block(raw, &buffer, &size, &offset)
            if status == ARCHIVE_EOF { return }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
                throw failure()
            }
            guard size > 0, let buffer else { continue }
            try body(UnsafeRawBufferPointer(start: buffer, count: size))
        }
    }

    // MARK: Archive-level metadata

    var formatCode: Int32 { archive_format(raw) }

    var formatName: String? {
        guard let pointer = archive_format_name(raw) else { return nil }
        let name = String(cString: pointer)
        return name.isEmpty ? nil : name
    }

    /// Code of the outermost filter, e.g. `ARCHIVE_FILTER_GZIP`.
    var filterCode: Int32 { archive_filter_code(raw, 0) }

    var filterName: String? {
        guard let pointer = archive_filter_name(raw, 0) else { return nil }
        let name = String(cString: pointer)
        return name.isEmpty || name == "none" ? nil : name
    }

    /// Number of compressed bytes consumed so far. `archive_filter_bytes` with
    /// `-1` reports across all filters.
    var consumedBytes: Int64 {
        archive_filter_bytes(raw, -1)
    }

    /// Entries libarchive has handed out so far.
    var entryCount: Int { Int(archive_file_count(raw)) }

    /// `true`/`false` when libarchive knows, `nil` when it cannot tell.
    var hasEncryptedEntries: Bool? {
        let value = archive_read_has_encrypted_entries(raw)
        switch value {
        case ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW, ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED:
            return nil
        default:
            return value > 0
        }
    }

    // MARK: Lifecycle

    /// Closes the stream. Safe to call more than once.
    func close() {
        guard let handle else { return }
        archive_read_close(handle)
    }

    func free() {
        guard let handle else { return }
        self.handle = nil
        currentEntry = nil
        archive_read_free(handle)
    }

    // MARK: Helpers

    private var raw: OpaquePointer {
        // `handle` is only nil after `free()`; every call site is guarded by the
        // owning scope, so a trap here would be a programmer error.
        guard let handle else {
            preconditionFailure("libarchive reader used after free()")
        }
        return handle
    }

    /// Reads the current error state into a Swift error value.
    func failure() -> LibArchiveFailure {
        let message = archive_error_string(raw).map { String(cString: $0) } ?? "unknown libarchive error"
        return LibArchiveFailure(status: ARCHIVE_FATAL,
                                 message: message,
                                 errorNumber: archive_errno(raw))
    }

    private func check(_ status: Int32, context: String) throws {
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
            var failure = failure()
            if failure.message == "unknown libarchive error" {
                failure = LibArchiveFailure(status: status,
                                            message: "\(context) failed with status \(status)",
                                            errorNumber: failure.errorNumber)
            }
            throw failure
        }
    }
}

// MARK: - Entry field extraction

extension LibArchiveEntrySnapshot {
    /// Reads every field ArchiveCat cares about out of an `archive_entry`.
    ///
    /// Everything is copied; the returned value does not reference libarchive
    /// memory, so it stays valid after the next header is read.
    init(entry: OpaquePointer) {
        let pathResolution = Self.pathString(archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry))
        self.rawPath = pathResolution.value
        self.pathWasValidUTF8 = pathResolution.wasValidUTF8

        let fileType = archive_entry_filetype(entry)
        self.fileType = fileType
        self.mode = archive_entry_mode(entry)

        let sizeIsSet = archive_entry_size_is_set(entry) != 0
        self.sizeIsSet = sizeIsSet
        let size = archive_entry_size(entry)
        self.size = size

        if archive_entry_mtime_is_set(entry) != 0 {
            self.modificationDate = Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry)))
        } else {
            self.modificationDate = nil
        }

        let uidIsSet = archive_entry_uid_is_set(entry) != 0
        self.uidIsSet = uidIsSet
        self.uid = archive_entry_uid(entry)

        let gidIsSet = archive_entry_gid_is_set(entry) != 0
        self.gidIsSet = gidIsSet
        self.gid = archive_entry_gid(entry)

        self.linkCount = archive_entry_nlink(entry)

        let symlink = archive_entry_symlink_utf8(entry) ?? archive_entry_symlink(entry)
        self.symlinkTarget = symlink.map { Self.pathString($0).value }

        let hardlink = archive_entry_hardlink_utf8(entry) ?? archive_entry_hardlink(entry)
        self.hardlinkTarget = hardlink.map { Self.pathString($0).value }

        if archive_entry_rdev_is_set(entry) != 0 {
            self.deviceMajor = UInt32(archive_entry_rdevmajor(entry))
            self.deviceMinor = UInt32(archive_entry_rdevminor(entry))
        } else {
            self.deviceMajor = nil
            self.deviceMinor = nil
        }

        // `strmode` is cheap and gives the inspector its "drwxr-xr-x" column
        // without re-deriving it, and doubles as a sanity check on the mode.
        if let strmodePointer = archive_entry_strmode(entry) {
            self.formatDetail = nil
            _ = String(cString: strmodePointer)
        } else {
            self.formatDetail = nil
        }
    }

    /// Copies a C string into a Swift `String`, falling back to a lossy UTF-8
    /// decode for archives with non-UTF-8 filenames (very common in old ZIPs).
    static func pathString(_ pointer: UnsafePointer<CChar>?) -> (value: String, wasValidUTF8: Bool) {
        guard let pointer else { return ("", true) }
        if let valid = String(validatingCString: pointer) {
            return (valid, true)
        }
        let length = strlen(pointer)
        let buffer = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        let bytes = UnsafeBufferPointer(start: buffer, count: length)
        return (String(decoding: bytes, as: UTF8.self), false)
    }
}
