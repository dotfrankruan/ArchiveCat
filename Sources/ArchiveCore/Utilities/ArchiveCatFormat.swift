//
//  ArchiveCatFormat.swift
//  ArchiveCore
//
//  Shared value formatting so the engine, the inspector and the browser all
//  render sizes, dates and ratios the same way — and the way macOS does.
//
//  `ByteCountFormatter` instances are not `Sendable`, so the engine uses the
//  value-type `FormatStyle` API instead of a shared formatter singleton. That
//  keeps every formatting call safe from any isolation domain.
//

import Foundation

public enum ArchiveCatFormat {
    /// "2.31 GB" — decimal units, the same convention Finder uses.
    public static func byteCount(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// "612 KB (26.5% of the original)" style compression summary.
    public static func ratio(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }

    /// Ratio rounded into a compact form, or "—" when unknown.
    public static func ratioOrDash(_ value: Double?) -> String {
        guard let value else { return "—" }
        return ratio(value)
    }

    /// "12 Aug 2024 at 09:31"
    public static func timestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Compact relative form used in the file list ("Yesterday", "12/08/2024").
    public static func listTimestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    /// "—" for a missing optional string, otherwise the value itself.
    public static func dashIfEmpty(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    /// "—" for a missing optional number, otherwise the value.
    public static func number<T: CustomStringConvertible>(_ value: T?) -> String {
        guard let value else { return "—" }
        return value.description
    }

    /// Octal POSIX mode, e.g. "0755".
    public static func octal(_ mode: UInt16?) -> String {
        guard let mode else { return "—" }
        return String(format: "%04o", mode & 0o7777)
    }
}
