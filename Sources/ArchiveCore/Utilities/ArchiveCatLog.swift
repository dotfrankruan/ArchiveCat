//
//  ArchiveCatLog.swift
//  ArchiveCore
//
//  Centralised `os.Logger` categories.
//
//  Rules of engagement:
//   * never log file contents;
//   * log paths at `debug` level only (they can be personal data);
//   * prefer a single meaningful line over a stream of chatter.
//

import Foundation
import os

public enum ArchiveCatLog {
    /// Bundle identifier of the app; falls back to the build-time default when
    /// running inside a test bundle where `Bundle.main` has no identifier.
    public static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.frankruan.ArchiveCat"

    /// Archive detection, header scanning, format identification.
    public static let archive = Logger(subsystem: subsystem, category: "archive")

    /// Extraction, conflict handling, path safety enforcement.
    public static let extraction = Logger(subsystem: subsystem, category: "extraction")

    /// Quick Look materialisation and preview cache maintenance.
    public static let preview = Logger(subsystem: subsystem, category: "preview")

    /// Drag and drop, file promises.
    public static let drag = Logger(subsystem: subsystem, category: "drag")

    /// Search, inspection, metadata interpretation.
    public static let inspection = Logger(subsystem: subsystem, category: "inspection")

    /// SwiftUI / AppKit layer.
    public static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Anything that rejected untrusted input: traversal attempts, malformed
    /// entries, archive bombs.
    public static let security = Logger(subsystem: subsystem, category: "security")
}
