//
//  ui-probe.swift
//  ArchiveCat (test tooling)
//
//  A tiny window counter used by Scripts/verify-lifecycle.sh.
//
//  GUI automation on this Mac is gated by TCC and unavailable to CI, so the
//  lifecycle smoke test cannot *click* anything. What it can do without any
//  permission is count on-screen windows, which is enough to assert "opening
//  archive A then B gives two document windows" and "the welcome state comes
//  back".
//
//  Two traps the naive version fell into:
//
//   * `CGWindowListCopyWindowInfo` can briefly report windows of a process
//     that has already exited, so every entry is checked against a live PID.
//   * Some AppKit window styles surface companion CGWindows with the same
//     title, so counts are by distinct window number, never by title string.
//
//  Not part of the product; do not import it from app code.
//

import AppKit
import CoreGraphics
import Foundation

let appName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ArchiveCat"

// Live PIDs for the app name, via NSRunningApplication.
let livePIDs: Set<Int> = Set(
    (NSRunningApplication.runningApplications(withBundleIdentifier: "com.frankruan.ArchiveCat")
        .map { Int($0.processIdentifier) })
)

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    fputs("ui-probe: CGWindowListCopyWindowInfo unavailable\n", stderr)
    exit(2)
}

var seen = Set<Int>()
for window in list {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner == appName else { continue }
    guard let pid = window[kCGWindowOwnerPID as String] as? Int, livePIDs.contains(pid) else { continue }
    guard let number = window[kCGWindowNumber as String] as? Int, !seen.contains(number) else { continue }
    seen.insert(number)
    let title = window[kCGWindowName as String] as? String ?? "(untitled)"
    print("\(pid)\t\(title)")
}
