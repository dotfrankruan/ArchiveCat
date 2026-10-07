//
//  EntryListContainerView.swift
//  ArchiveCat
//
//  Wraps the entry table in its scroll view and turns Cocoa delegate callbacks
//  into the handful of intents the browser model understands.
//
//  The container is deliberately dumb: it renders the rows it is given, reports
//  selection and sort changes, and asks its delegate for file promises and
//  context menus. All decisions live in `BrowserViewModel`.
//

import AppKit
import ArchiveCore

@MainActor
protocol EntryListContainerDelegate: AnyObject {
    /// The user changed the selection.
    func entryList(_ view: EntryListContainerView, didChangeSelectionTo rowIDs: Set<String>)
    /// Double-click or Return on the selected rows.
    func entryListDidActivateSelection(_ view: EntryListContainerView)
    /// Space, via the table's key handling.
    func entryListDidRequestQuickLook(_ view: EntryListContainerView)
    /// A column header was clicked.
    func entryList(_ view: EntryListContainerView, didChangeSortTo spec: EntrySortSpec)
    /// A file promise for one dragged row.
    func entryList(_ view: EntryListContainerView, promiseFor row: EntryRow) -> NSFilePromiseProvider?
    /// The context menu for the current selection.
    func entryList(_ view: EntryListContainerView, menuFor rowIDs: Set<String>) -> NSMenu?
}

final class EntryListContainerView: NSView {

    weak var delegate: EntryListContainerDelegate?

    let tableView = EntryTableView()
    private let scrollView = NSScrollView()

    /// Columns currently shown, in order.
    private(set) var columns: [EntrySortColumn] = []

    var rows: [EntryRow] = [] {
        didSet {
            guard oldValue != rows else { return }
            tableView.reloadData()
            syncSelectionFromModel()
        }
    }

    var selectedRowIDs: Set<String> = [] {
        didSet {
            guard oldValue != selectedRowIDs else { return }
            syncSelectionFromModel()
        }
    }

    var sortSpec: EntrySortSpec = .default {
        didSet {
            guard oldValue != sortSpec else { return }
            syncSortDescriptors()
        }
    }

    /// True while search results are displayed.
    var isShowingSearchResults = false {
        didSet { tableView.showsContextLine = isShowingSearchResults }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EntryListContainerView is created in code only")
    }

    // MARK: - Setup

    private func build() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .fullWidth
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.headerView = NSTableHeaderView()
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.onQuickLook = { [weak self] in
            guard let self else { return }
            self.delegate?.entryListDidRequestQuickLook(self)
        }
        tableView.onActivateSelection = { [weak self] in
            guard let self else { return }
            self.delegate?.entryListDidActivateSelection(self)
        }
        tableView.menuProvider = { [weak self] event in
            guard let self else { return nil }
            return self.contextMenu(for: event)
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Rebuilds the column set; called when technical columns are toggled.
    func setColumns(_ newColumns: [EntrySortColumn]) {
        guard columns != newColumns else { return }
        columns = newColumns

        // Preserve the user's widths and order where possible.
        let existing = Dictionary(uniqueKeysWithValues: tableView.tableColumns.map { ($0.identifier.rawValue, $0) })
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }

        for (index, column) in newColumns.enumerated() {
            let tableColumn: NSTableColumn
            if let previous = existing[column.identifier] {
                tableColumn = previous
            } else {
                tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
                tableColumn.title = column.title
                tableColumn.width = column.defaultWidth
                tableColumn.minWidth = column.minimumWidth
                tableColumn.headerCell.alignment = column.isRightAligned ? .right : .left
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                    key: column.rawValue,
                    ascending: column == .name
                )
                tableColumn.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            }
            tableView.addTableColumn(tableColumn)
            tableView.moveColumn(tableView.tableColumns.count - 1, toColumn: index)
        }

        syncSortDescriptors()
        tableView.reloadData()
    }

    private func syncSortDescriptors() {
        let descriptors = sortSpec.sortDescriptors
        if tableView.sortDescriptors != descriptors {
            tableView.sortDescriptors = descriptors
        }
    }

    private func syncSelectionFromModel() {
        let indexes = IndexSet(rows.enumerated().compactMap { selectedRowIDs.contains($0.element.id) ? $0.offset : nil })
        guard tableView.selectedRowIndexes != indexes else { return }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)

        // Keep the focused row visible, like Finder does after a search.
        if let first = indexes.first {
            tableView.scrollRowToVisible(first)
        }
    }

    // MARK: - Actions

    @objc private func handleDoubleClick() {
        delegate?.entryListDidActivateSelection(self)
    }

    /// The rows behind the current selection.
    var selectedRows: [EntryRow] {
        tableView.selectedRowIndexes.compactMap { index in
            index < rows.count ? rows[index] : nil
        }
    }
}

// MARK: - Data source

extension EntryListContainerView: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count else { return nil }
        return delegate?.entryList(self, promiseFor: rows[row])
    }
}

// MARK: - Delegate

extension EntryListContainerView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let tableColumn else { return nil }
        let entryRow = rows[row]
        let isSelected = tableView.selectedRowIndexes.contains(row)
        let column = columns.first { $0.identifier == tableColumn.identifier.rawValue }

        switch column {
        case .name:
            let identifier = NSUserInterfaceItemIdentifier("ArchiveCat.nameCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? EntryNameCellView ?? {
                let created = EntryNameCellView()
                created.identifier = identifier
                return created
            }()
            cell.configure(row: entryRow, showsContext: isShowingSearchResults, isSelected: isSelected)
            return cell

        default:
            guard let column else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("ArchiveCat.textCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? EntryTextCellView ?? {
                let created = EntryTextCellView()
                created.identifier = identifier
                return created
            }()
            let detail = EntryListContainerView.detailText(for: entryRow, column: column)
            cell.configure(
                text: detail.text,
                alignment: column.isRightAligned ? .right : .left,
                isSelected: isSelected,
                secondary: detail.isSecondary
            )
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let ids = Set(tableView.selectedRowIndexes.compactMap { index in
            index < rows.count ? rows[index].id : nil
        })
        delegate?.entryList(self, didChangeSelectionTo: ids)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = EntrySortColumn(rawValue: key) else { return }
        delegate?.entryList(self, didChangeSortTo: EntrySortSpec(column: column, ascending: descriptor.ascending))
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    // MARK: Menu

    /// Builds the context menu for a right-click, moving the selection first if
    /// the click landed outside it — exactly what the Finder does.
    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let clickedRow = tableView.row(at: point)

        // Right-clicking outside the selection moves the selection, exactly
        // like the Finder.
        if clickedRow >= 0, !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let ids = Set(tableView.selectedRowIndexes.compactMap { index in
            index < rows.count ? rows[index].id : nil
        })
        return delegate?.entryList(self, menuFor: ids)
    }

    // MARK: Cell text

    private static func detailText(for row: EntryRow, column: EntrySortColumn) -> (text: String, isSecondary: Bool) {
        switch column {
        case .name:
            return ("", false)

        case .size:
            guard let size = row.uncompressedSize else {
                return (row.isDirectory ? "—" : "—", true)
            }
            return (ArchiveCatFormat.byteCount(size), false)

        case .compressedSize:
            guard let size = row.compressedSize else { return ("—", true) }
            let prefix = row.compressedSizeIsEstimated ? "≈ " : ""
            return (prefix + ArchiveCatFormat.byteCount(size), true)

        case .compressionRatio:
            guard let ratio = row.compressionRatio else { return ("—", true) }
            return (ArchiveCatFormat.ratio(ratio), true)

        case .modified:
            guard let date = row.modificationDate else { return ("—", true) }
            return (ArchiveCatFormat.listTimestamp(date), false)

        case .kind:
            return (row.kindName, false)

        case .permissions:
            guard let permissions = row.permissionString else { return ("—", true) }
            let octal = row.octalPermissions.map { " (\($0))" } ?? ""
            return (permissions + octal, true)

        case .uid:
            guard let uid = row.uid else { return ("—", true) }
            return (String(uid), true)

        case .gid:
            guard let gid = row.gid else { return ("—", true) }
            return (String(gid), true)

        case .linkTarget:
            if let target = row.hardlinkTarget {
                return ("→ \(target) (hard link)", true)
            }
            guard let target = row.symlinkTarget else { return ("—", true) }
            return ("→ \(target)", true)
        }
    }
}
