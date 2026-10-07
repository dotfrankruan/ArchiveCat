// swift-tools-version: 6.0
//
//  Package.swift
//  ArchiveCat
//
//  Build description for the ArchiveCat macOS archive browser.
//
//  Layout
//  ------
//  CArchive        Thin C shim that re-exports libarchive. Nothing above this
//                  target is allowed to import it outside of ArchiveCore's
//                  LibArchiveBridge.
//  ArchiveCore     Platform-neutral archive engine: reading, virtual tree,
//                  extraction, preview materialization, inspection. No SwiftUI.
//  ArchiveCat      The macOS application (AppKit lifecycle + SwiftUI views).
//
//  libarchive discovery
//  --------------------
//  Set LIBARCHIVE_PREFIX to override. Otherwise the usual Homebrew keg paths
//  are probed, then a system-wide installation (/usr/include + /usr/lib).

import Foundation
import PackageDescription

/// Where the libarchive headers and library live on this machine.
struct LibArchiveLocation {
    var prefix: String
    var includeDir: String?
    var libraryDir: String?

    var found: Bool { includeDir != nil }

    static func detect() -> LibArchiveLocation {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        var prefixes: [String] = []
        if let override = environment["LIBARCHIVE_PREFIX"], !override.isEmpty {
            prefixes.append(override)
        }
        prefixes.append(contentsOf: [
            "/opt/homebrew/opt/libarchive",   // Apple Silicon Homebrew
            "/usr/local/opt/libarchive",      // Intel Homebrew
        ])

        for prefix in prefixes {
            if fileManager.fileExists(atPath: prefix + "/include/archive.h") {
                return LibArchiveLocation(prefix: prefix,
                                          includeDir: prefix + "/include",
                                          libraryDir: prefix + "/lib")
            }
        }

        // System-wide (Linux, or a macOS build with libarchive in /usr).
        if fileManager.fileExists(atPath: "/usr/include/archive.h") {
            return LibArchiveLocation(prefix: "/usr", includeDir: nil, libraryDir: nil)
        }

        return LibArchiveLocation(prefix: "/usr", includeDir: nil, libraryDir: nil)
    }
}

let libarchive = LibArchiveLocation.detect()

if !libarchive.found {
    print("""
    [ArchiveCat] libarchive headers were not found in the usual locations.
                 Install it with `brew install libarchive`, or set
                 LIBARCHIVE_PREFIX to a prefix containing include/archive.h.
    """)
}

var libarchiveCSettings: [CSetting] = []
var libarchiveSwiftSettings: [SwiftSetting] = []
var libarchiveLinkerSettings: [LinkerSetting] = [.linkedLibrary("archive")]

if let includeDir = libarchive.includeDir {
    // `CSetting.headerSearchPath` only accepts package-relative paths, so the
    // include directory is passed through explicitly. It has to be given to
    // Swift targets as `-Xcc -I…` because SwiftPM does not forward a C target's
    // custom `cSettings` to a dependent Swift target's Clang importer — without
    // this, building the `CArchive` module fails with "archive.h file not
    // found" even though the headers are present.
    libarchiveCSettings.append(.unsafeFlags(["-I\(includeDir)"]))
    libarchiveSwiftSettings.append(.unsafeFlags(["-Xcc", "-I\(includeDir)"]))
}
if let libraryDir = libarchive.libraryDir {
    libarchiveLinkerSettings.append(.unsafeFlags(["-L\(libraryDir)"]))
}

let package = Package(
    name: "ArchiveCat",
    platforms: [
        // SwiftUI Table, NavigationSplitView and the modern AppKit APIs used by
        // the browser all require macOS 14 or later.
        .macOS(.v14),
    ],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
    ],
    targets: [
        // ---------------------------------------------------------------------
        // C shim over libarchive.
        // ---------------------------------------------------------------------
        .target(
            name: "CArchive",
            path: "Sources/CArchive",
            cSettings: libarchiveCSettings,
            linkerSettings: libarchiveLinkerSettings
        ),

        // ---------------------------------------------------------------------
        // The archive engine.
        // ---------------------------------------------------------------------
        .target(
            name: "ArchiveCore",
            dependencies: ["CArchive"],
            path: "Sources/ArchiveCore",
            cSettings: libarchiveCSettings,
            swiftSettings: libarchiveSwiftSettings
        ),

        // ---------------------------------------------------------------------
        // Tests. The engine is testable without launching the GUI.
        // ---------------------------------------------------------------------
        .testTarget(
            name: "ArchiveCoreTests",
            dependencies: ["ArchiveCore", "CArchive"],
            path: "Tests/ArchiveCoreTests",
            resources: [
                // Reserved for fixtures that are easier to check in than to
                // generate. The suite currently builds every archive it needs
                // with libarchive's write API (see Support/ArchiveFixtureWriter).
                .copy("Fixtures"),
            ],
            cSettings: libarchiveCSettings,
            swiftSettings: libarchiveSwiftSettings
        ),
    ]
)
