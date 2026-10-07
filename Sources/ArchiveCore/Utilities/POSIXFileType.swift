//
//  POSIXFileType.swift
//  ArchiveCore
//
//  The portable POSIX file-type bits, expressed in Swift.
//
//  libarchive's `AE_IF*` macros expand to `((__LA_MODE_T)0170000)`, a cast
//  expression Clang's Swift importer cannot turn into a Swift constant, so the
//  values are mirrored here. They are the same values as `S_IF*` in
//  `sys/stat.h`, and the test suite asserts that.
//

import Darwin
import Foundation

enum POSIXFileType {
    static let mask: mode_t = 0o170000
    static let regular: mode_t = 0o100000
    static let directory: mode_t = 0o040000
    static let symbolicLink: mode_t = 0o120000
    static let fifo: mode_t = 0o010000
    static let socket: mode_t = 0o140000
    static let characterDevice: mode_t = 0o020000
    static let blockDevice: mode_t = 0o060000

    /// Type bits of a `stat` structure.
    static func of(stat status: stat) -> mode_t {
        status.st_mode & mask
    }

    /// Type bits of a full mode value.
    static func of(mode: mode_t) -> mode_t {
        mode & mask
    }
}
