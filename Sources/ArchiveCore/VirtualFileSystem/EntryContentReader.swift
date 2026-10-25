//
//  EntryContentReader.swift
//  ArchiveCore
//
//  Bounded, on-demand reads of a single member.
//
//  This is the content half of the virtual filesystem: the browser sometimes
//  needs bytes rather than a file on disk — to identify a nested archive before
//  offering to open it, or to fill a small inspector preview. It must never turn
//  into "read the archive into memory".
//
//  Cost model, stated honestly
//  ---------------------------
//  libarchive has no per-member index we can seek with; `archive_read_next_header`
//  walks the stream. So reading entry number N is a **linear pass** to N, which
//  for a seekable container is mostly seeking and for a gzip stream is real
//  decompression. That is why:
//
//   * the cap is enforced while streaming (no unbounded growth),
//   * the read stops as soon as the cap is reached (a 2 GB member costs one
//     block, not 2 GB),
//   * callers cache what they learn (preview cache, nested-archive materialisation).
//
//  Nothing here writes to disk.
//

import Foundation

/// Reads the first bytes of one member, with a hard cap.
enum EntryContentReader {

    /// Thrown internally to stop the stream as soon as enough bytes were read.
    private struct StopReading: Error {}

    /// Reads at most `maxBytes` bytes of the entry with the given ordinal.
    ///
    /// - Parameters:
    ///   - archiveURL: the archive to read.
    ///   - ordinal: position of the entry in the archive stream.
    ///   - maxBytes: hard cap; must be positive.
    /// - Returns: up to `maxBytes` bytes, possibly fewer when the member is
    ///   smaller. Zero bytes for a member that legitimately has no payload.
    static func readData(archiveURL: URL, ordinal: Int, maxBytes: Int) throws -> Data {
        precondition(maxBytes > 0, "readData requires a positive cap")

        let stream = try LibArchiveReadStream()
        defer { stream.free() }
        try stream.enableAutoDetection()
        try stream.open(path: archiveURL.path(percentEncoded: false))

        var index = 0
        while try stream.nextHeader() {
            guard index == ordinal else {
                try stream.skipCurrentEntryData()
                index += 1
                continue
            }

            var collected = Data()
            collected.reserveCapacity(min(maxBytes, 64 * 1024))

            do {
                try stream.readCurrentEntryData { block in
                    if Task.isCancelled { throw CancellationError() }

                    let remaining = maxBytes - collected.count
                    guard remaining > 0 else { throw StopReading() }

                    let take = min(remaining, block.count)
                    collected.append(contentsOf: UnsafeRawBufferPointer(rebasing: block.prefix(take)))

                    // Enough bytes; stop the pass rather than draining a huge
                    // member we already have the answer from.
                    if collected.count >= maxBytes { throw StopReading() }
                }
            } catch is StopReading {
                // Expected early exit.
            }

            return collected
        }

        throw ArchiveError.corrupted(
            url: archiveURL,
            entryPath: nil,
            technicalDetails: "The archive ended before entry #\(ordinal) was reached."
        )
    }

    /// Streams one member to an already-open file descriptor, enforcing a byte
    /// cap and honouring cancellation per block.
    ///
    /// - Returns: number of bytes written.
    @discardableResult
    static func copy(
        archiveURL: URL,
        ordinal: Int,
        to descriptor: Int32,
        maximumBytes: Int64
    ) throws -> Int64 {
        let stream = try LibArchiveReadStream()
        defer { stream.free() }
        try stream.enableAutoDetection()
        try stream.open(path: archiveURL.path(percentEncoded: false))

        var index = 0
        while try stream.nextHeader() {
            guard index == ordinal else {
                try stream.skipCurrentEntryData()
                index += 1
                continue
            }

            var written: Int64 = 0
            do {
                try stream.readCurrentEntryData { block in
                    if Task.isCancelled { throw CancellationError() }
                    guard written + Int64(block.count) <= maximumBytes else {
                        throw ArchiveError.limitExceeded(
                            kind: .singleEntryBytes,
                            limit: maximumBytes,
                            observed: written + Int64(block.count)
                        )
                    }
                    var offset = 0
                    while offset < block.count {
                        let wrote = block.baseAddress!
                            .advanced(by: offset)
                            .withMemoryRebound(to: UInt8.self, capacity: block.count - offset) { pointer in
                                write(descriptor, pointer, block.count - offset)
                            }
                        guard wrote > 0 else {
                            throw ArchiveError.underlying(
                                reason: "The extracted data could not be written.",
                                technicalDetails: "write(2) returned \(wrote) with errno \(errno)."
                            )
                        }
                        offset += wrote
                        written += Int64(wrote)
                    }
                }
            }
            return written
        }

        throw ArchiveError.corrupted(
            url: archiveURL,
            entryPath: nil,
            technicalDetails: "The archive ended before entry #\(ordinal) was reached."
        )
    }
}
