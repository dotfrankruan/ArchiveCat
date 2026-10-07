//
//  EntrySortSpec.swift
//  ArchiveCat
//
//  Sorting the file list.
//
//  Kept as a small value type rather than `[KeyPathComparator]` because the
//  list is rendered by a real `NSTableView` (multi-file drag promises need an
//  AppKit drag source), and because folders-first is a browser convention that
//  `KeyPathComparator` cannot express.
//
//  Sorting never mutates the archive: it produces a new presentation array.
//

import Foundation

/// A column the list can be sorted by.
enum EntrySortColumn: String, CaseIterable, Sendable {
    case name
    case size
    case compressedSize
    case compressionRatio
    case modified
    case kind
    case permissions
    case uid
    case gid
    case linkTarget

    /// Title shown in the column header.
    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .compressedSize: return "Compressed"
        case .compressionRatio: return "Compression"
        case .modified: return "Date Modified"
        case .kind: return "Kind"
        case .permissions: return "Permissions"
        case .uid: return "UID"
        case .gid: return "GID"
        case .linkTarget: return "Link Target"
        }
    }

    /// Identifier used for the `NSTableColumn`.
    var identifier: String { "ArchiveCat.column.\(rawValue)" }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 280
        case .size, .compressedSize: return 90
        case .compressionRatio: return 100
        case .modified: return 160
        case .kind: return 140
        case .permissions: return 110
        case .uid, .gid: return 60
        case .linkTarget: return 180
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .name: return 160
        case .modified: return 120
        case .kind: return 80
        default: return 50
        }
    }

    var isRightAligned: Bool {
        switch self {
        case .size, .compressedSize, .compressionRatio, .uid, .gid: return true
        default: return false
        }
    }

    var isNumeric: Bool { isRightAligned }

    /// Columns that only show up when "Show Technical Columns" is on.
    var isTechnical: Bool {
        switch self {
        case .permissions, .uid, .gid, .linkTarget: return true
        default: return false
        }
    }
}

/// Column plus direction.
struct EntrySortSpec: Equatable, Sendable {
    var column: EntrySortColumn
    var ascending: Bool

    static let `default` = EntrySortSpec(column: .name, ascending: true)

    /// Sort descriptors for `NSTableView`, so the header indicators match.
    var sortDescriptors: [NSSortDescriptor] {
        [NSSortDescriptor(key: column.rawValue, ascending: ascending, selector: #selector(NSString.compare(_:)))]
    }

    // MARK: Sorting

    /// Sorts rows for presentation.
    ///
    /// Folders stay on top for name sorting — the behaviour every Mac user
    /// expects from Finder — and equal keys fall back to the path so the order
    /// is stable and reproducible.
    static func sorted(_ rows: [EntryRow], by spec: EntrySortSpec) -> [EntryRow] {
        rows.sorted { lhs, rhs in
            if spec.column == .name, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let comparison = compare(lhs, rhs, column: spec.column)
            if comparison == .orderedSame {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            return spec.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func compare(_ lhs: EntryRow, _ rhs: EntryRow, column: EntrySortColumn) -> ComparisonResult {
        switch column {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            return compareNumbers(lhs.sortSize, rhs.sortSize)
        case .compressedSize:
            return compareNumbers(lhs.sortCompressed, rhs.sortCompressed)
        case .compressionRatio:
            return compareDoubles(lhs.sortRatio, rhs.sortRatio)
        case .modified:
            return lhs.sortModified.compare(rhs.sortModified)
        case .kind:
            return lhs.kindName.localizedStandardCompare(rhs.kindName)
        case .permissions:
            return compareNumbers(Int64(lhs.sortPermissions), Int64(rhs.sortPermissions))
        case .uid:
            return compareNumbers(lhs.sortUID, rhs.sortUID)
        case .gid:
            return compareNumbers(lhs.sortGID, rhs.sortGID)
        case .linkTarget:
            return lhs.sortSymlink.localizedStandardCompare(rhs.sortSymlink)
        }
    }

    private static func compareNumbers<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func compareDoubles(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}
