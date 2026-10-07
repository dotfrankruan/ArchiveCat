//
//  EntryTableView.swift
//  ArchiveCat
//
//  The file list: a real `NSTableView`.
//
//  Why AppKit here? Because the brief's drag-out requirement — drag several
//  entries into the Finder as normal files, materialised on demand — is exactly
//  what `NSFilePromiseProvider` does, and a promise per dragged row needs an
//  AppKit drag source. A SwiftUI `Table` renders one item provider per drag,
//  which cannot express "three files at once".
//
//  Everything else about the view is standard `NSTableView`: Finder's full-width
//  selection style, alternating row colours, native column headers with sort
//  indicators, native multi-selection and native context menus.
//

import AppKit
import ArchiveCore

/// The table itself. Owns keyboard behaviour that the rest of the app should
/// not have to care about.
final class EntryTableView: NSTableView {

    /// Called for Space (Quick Look) and Return (open).
    var onQuickLook: (() -> Void)?
    var onActivateSelection: (() -> Void)?

    /// Asked for the context menu of a right-click.
    var menuProvider: ((NSEvent) -> NSMenu?)?

    /// Row height depends on whether rows show a second line of context.
    var showsContextLine = false {
        didSet {
            guard oldValue != showsContextLine else { return }
            rowHeight = showsContextLine ? 34 : 24
            reloadData()
        }
    }

    override func keyDown(with event: NSEvent) {
        // Space is Quick Look, exactly like the Finder. Handled here rather
        // than as a menu key equivalent so it never fires while a text field
        // has focus.
        if event.charactersIgnoringModifiers == " " {
            onQuickLook?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return, keypad Enter
            onActivateSelection?()
            return
        }
        super.keyDown(with: event)
    }

    /// The table accepts first responder status so the menu bar's ⌘A/⌘C reach it.
    override var acceptsFirstResponder: Bool { true }

    /// `NSView.menu(for:)` is the supported hook for a per-click context menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event) ?? super.menu(for: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Finder copies dragged files; nothing here can move or link them.
        setDraggingSourceOperationMask(.copy, forLocal: false)
    }
}

/// A name cell: icon, title, and an optional second line showing where the
/// entry lives (used for search results, like Finder).
final class EntryNameCellView: NSTableCellView {

    let iconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let contextField = NSTextField(labelWithString: "")

    private let textStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EntryNameCellView is created in code only")
    }

    private func build() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contextField.translatesAutoresizingMaskIntoConstraints = false
        contextField.lineBreakMode = .byTruncatingMiddle
        contextField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        contextField.textColor = .secondaryLabelColor

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleField)
        textStack.addArrangedSubview(contextField)

        addSubview(iconView)
        addSubview(textStack)
        textField = titleField
        imageView = iconView

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(row: EntryRow, showsContext: Bool, isSelected: Bool) {
        iconView.image = IconProvider.icon(for: row)
        titleField.stringValue = row.name
        titleField.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor

        if showsContext, let context = row.containingPath, !context.isEmpty {
            contextField.isHidden = false
            contextField.stringValue = context
            contextField.textColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        } else if showsContext {
            contextField.isHidden = false
            contextField.stringValue = "Archive root"
        } else {
            contextField.isHidden = true
        }

        toolTip = row.path
    }
}

/// A plain text cell for the metadata columns.
final class EntryTextCellView: NSTableCellView {

    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EntryTextCellView is created in code only")
    }

    func configure(text: String, alignment: NSTextAlignment, isSelected: Bool, secondary: Bool = false) {
        label.stringValue = text
        label.alignment = alignment
        label.textColor = isSelected
            ? .alternateSelectedControlTextColor
            : (secondary ? .secondaryLabelColor : .labelColor)
    }
}
