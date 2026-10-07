//
//  main.swift
//  ArchiveCat
//
//  Application entry point.
//
//  ArchiveCat is a document-based AppKit application that hosts SwiftUI views.
//  AppKit owns the lifecycle (documents, windows, menu bar, Quick Look panel)
//  because those are the parts SwiftUI still does not model natively on macOS;
//  everything inside a window is SwiftUI.
//
//  NOTE: replaced by the real application shell in the browser milestone.
//

import AppKit
import ArchiveCore

ArchiveCatLog.ui.debug("ArchiveCat starting, \(LibArchive.versionString, privacy: .public)")

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
