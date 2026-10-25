//
//  CompressionProgressSheet.swift
//  ArchiveCat
//
//  The small sheet shown while an archive is being created.
//
//  Deliberately plain AppKit: a determinate progress bar, the item and byte
//  counters, the current path, and a Cancel button. It is a sheet on the window
//  the user started from, so the document stays visible and the app cannot look
//  hung.
//

import AppKit
import ArchiveCore

@MainActor
final class CompressionProgressSheet: NSObject {

    private let window: NSWindow
    private weak var parentWindow: NSWindow?
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var isCancelling = false

    /// Called when the user asks to stop.
    var onCancel: (() -> Void)?

    init(title: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 132),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = title
        window.isMovable = false
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 132))

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .regular

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [progressBar, detailLabel, pathLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.addSubview(cancelButton)

        for view in [progressBar, detailLabel, pathLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            progressBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelButton.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 8),
        ])

        window.contentView = content
        detailLabel.stringValue = "Preparing…"
    }

    /// Shows the sheet on `parentWindow`, or as a small floating window when the
    /// caller has no window to attach to.
    func present(on parentWindow: NSWindow?) {
        self.parentWindow = parentWindow
        if let parentWindow, parentWindow.isVisible {
            parentWindow.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func update(_ progress: CompressionProgress) {
        if let fraction = progress.fractionCompleted {
            progressBar.isIndeterminate = false
            progressBar.doubleValue = fraction
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        }

        let items = progress.totalItems > 0
            ? "\(progress.completedItems.formatted()) of \(progress.totalItems.formatted()) items"
            : "\(progress.completedItems.formatted()) items"
        let bytes = progress.totalBytes > 0
            ? "\(ArchiveCatFormat.byteCount(progress.completedBytes)) of \(ArchiveCatFormat.byteCount(progress.totalBytes))"
            : ArchiveCatFormat.byteCount(progress.completedBytes)
        detailLabel.stringValue = isCancelling ? "Cancelling…" : "\(items) • \(bytes)"
        pathLabel.stringValue = isCancelling ? "" : (progress.currentPath ?? "")
    }

    func dismiss() {
        if let parentWindow, parentWindow.isVisible, window.sheetParent != nil {
            parentWindow.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    @objc private func cancelPressed() {
        guard !isCancelling else { return }
        isCancelling = true
        cancelButton.isEnabled = false
        detailLabel.stringValue = "Cancelling…"
        onCancel?()
    }
}
