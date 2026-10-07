//
//  SendableBox.swift
//  ArchiveCat
//
//  A minimal box for handing a non-`Sendable` value to an asynchronous task.
//
//  AppKit still imports a few callbacks without `@Sendable` — the file promise
//  completion handler is the one ArchiveCat actually needs — and passing those
//  into a `Task` is rejected under Swift 6 region isolation even though the
//  system guarantees the handler is safe to call from the queue the promise was
//  written on. The box documents that assumption in exactly one place instead
//  of scattering `@preconcurrency` annotations through the drag code.
//

/// Wraps a value so it can cross an isolation boundary.
///
/// Only use this where the underlying API already documents the safety: the
/// caller takes responsibility for the value being safe to use concurrently.
struct SendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
