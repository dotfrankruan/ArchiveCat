//
//  NestedArchiveCache.swift
//  ArchiveCat
//
//  One process-wide nested-archive cache.
//
//  The budget is a property of the app, not of a window: five document windows
//  must not each be allowed the full temporary-storage budget. The store itself
//  is an `ArchiveCore` actor with no AppKit in it; this is only the place the
//  app decides there is exactly one.
//

import ArchiveCore
import Foundation

@MainActor
enum NestedArchiveCache {

    private static var store: NestedArchiveStore?

    /// The shared store, created on first use.
    ///
    /// Returns `nil` when the cache directory cannot be created (for example a
    /// read-only home directory). The browser then reports that nested archives
    /// are unavailable instead of crashing or silently doing nothing.
    static func shared() -> NestedArchiveStore? {
        if let store { return store }
        do {
            let created = try NestedArchiveStore()
            store = created
            return created
        } catch {
            ArchiveCatLog.archive.error("nested archive cache unavailable")
            return nil
        }
    }
}
