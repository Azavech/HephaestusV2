// OWNER: ui-tickets — the AppKit table behind the ticket list, the bundle list and the Tickets tab of
// a bundle: multi-selection, sortable headers, context menus that select the clicked row first,
// Copy, ⌫ and ⌘⌫, double-click and row reordering (docs/tickets.md › Ticket list, › Bundles
// section, › Keyboard shortcuts).
import AppKit
import SwiftUI

/// How an `ItemTable` column takes its width (docs/tickets.md › Ticket list, column widths).
enum ItemTableColumnSizing {
    /// The width the other columns leave, at least the column's minimum: it truncates first.
    case fill
    /// As wide as its widest cell and its header.
    case content
    /// As wide as its widest cell and its header while the fill column is wider than its minimum;
    /// then it shrinks, down to the column's minimum, and its text truncates.
    case shrinkableContent
}

/// One column of an `ItemTable`.
struct ItemTableColumn<Row> {
    var id: String
    var title: String
    var minWidth: CGFloat
    var sizing: ItemTableColumnSizing
    /// The width of a row's cell content, for the `content` sizings.
    var contentWidth: (Row) -> CGFloat = { _ in 0 }
    var sortable = true
    var cell: (Row) -> AnyView
}

/// Text widths for `ItemTableColumn.contentWidth`, rounded up with a point to spare.
enum ItemTableText {
    static func width(_ text: String, font: NSFont) -> CGFloat {
        ((text as NSString).size(withAttributes: [.font: font]).width + 1).rounded(.up)
    }

    /// The font of `.system(size: 12, design: .monospaced)`, the id columns.
    static let monospaced = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// The font of plain cell text.
    static let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
}

/// The sorted column and direction of an `ItemTable`.
struct ItemTableSort: Equatable {
    var columnID: String
    var ascending: Bool
}

/// An item of a table's context menu.
enum ItemTableMenuItem {
    case action(String, enabled: Bool = true, keyEquivalent: String = "", modifiers: NSEvent.ModifierFlags = [], () -> Void)
    case submenu(String, enabled: Bool = true, [ItemTableMenuItem])
    case separator
}

/// A view-based `NSTableView` whose rows are identified by string ids. Rows come sorted from the
/// caller; header clicks report the new sort through `onSortChange`.
struct ItemTable<Row: Identifiable & Hashable>: NSViewRepresentable where Row.ID == String {
    var rows: [Row]
    var columns: [ItemTableColumn<Row>]
    var selection: Set<String>
    var onSelectionChange: (Set<String>) -> Void
    var allowsMultipleSelection = true
    var sort: ItemTableSort?
    var onSortChange: ((ItemTableSort) -> Void)?
    /// The context menu of the selected rows; the clicked row is selected first.
    var menu: ((Set<String>) -> [ItemTableMenuItem])?
    var onDoubleClick: ((String) -> Void)?
    /// Edit ▸ Copy (⌘C) with the selected rows, in row order.
    var onCopy: (([String]) -> Void)?
    /// ⌫ with the selected rows.
    var onDelete: ((Set<String>) -> Void)?
    /// ⌘⌫ with the selected rows.
    var onCommandDelete: ((Set<String>) -> Void)?
    /// Drag reordering: the moved row ids, in row order, and the row index they go before.
    var onMove: (([String], Int) -> Void)?
    var rowHeight: CGFloat = 24

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ItemNSTableView()
        table.coordinator = context.coordinator
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        // The coordinator sets every column's width from the visible width (`layoutColumns`).
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([ItemNSTableView.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.minWidth = column.minWidth
            tableColumn.width = column.minWidth
            tableColumn.resizingMask = []
            if column.sortable, onSortChange != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            }
            table.addTableColumn(tableColumn)
        }
        let scrollView = ItemScrollView()
        scrollView.onTile = { [weak coordinator = context.coordinator] in coordinator?.layoutColumns() }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.table = table
        context.coordinator.apply(self, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(self, force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ItemTable
        weak var table: ItemNSTableView?
        private var shownRows: [Row] = []
        private var isApplying = false

        init(_ parent: ItemTable) {
            self.parent = parent
        }

        /// Applies the SwiftUI values: rows, sort indicator and selection.
        func apply(_ parent: ItemTable, force: Bool) {
            self.parent = parent
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }
            table.allowsMultipleSelection = parent.allowsMultipleSelection
            table.rowHeight = parent.rowHeight
            if force || shownRows != parent.rows {
                shownRows = parent.rows
                table.reloadData()
                measureColumns()
                layoutColumns()
            }
            let descriptors = parent.sort.map { [NSSortDescriptor(key: $0.columnID, ascending: $0.ascending)] } ?? []
            if parent.onSortChange != nil, table.sortDescriptors != descriptors {
                table.sortDescriptors = descriptors
            }
            let wanted = IndexSet(shownRows.indices.filter { parent.selection.contains(shownRows[$0].id) })
            if table.selectedRowIndexes != wanted {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                // A selection made elsewhere (navigation, a new ticket) is scrolled into view.
                if let first = wanted.first {
                    table.scrollRowToVisible(first)
                }
            }
        }

        // MARK: Column widths (docs/tickets.md › Ticket list, column widths)

        /// The widest cell of each `content` column, by column id.
        private var contentWidths: [String: CGFloat] = [:]
        private var isLayingOut = false

        private func measureColumns() {
            for column in parent.columns where column.sizing != .fill {
                contentWidths[column.id] = shownRows.map(column.contentWidth).max() ?? 0
            }
        }

        /// Content columns as wide as their widest cell and header; the fill column takes the rest,
        /// down to its minimum; then the shrinkable columns shrink, the last first, down to theirs.
        func layoutColumns() {
            guard !isLayingOut, let table, let clip = table.enclosingScrollView?.contentView else { return }
            let available = clip.bounds.width
            guard available > 0 else { return }
            isLayingOut = true
            defer { isLayingOut = false }
            let columns = parent.columns
            let tableColumns = columns.map { table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier($0.id)) }
            var widths = zip(columns, tableColumns).map { column, tableColumn -> CGFloat in
                guard column.sizing != .fill else { return column.minWidth }
                // The header's title, with room for the sort indicator.
                let header = (tableColumn?.headerCell.cellSize.width ?? 0) + (column.sortable && parent.onSortChange != nil ? 16 : 4)
                return max(column.minWidth, contentWidths[column.id] ?? 0, header.rounded(.up))
            }
            var extra = available - widths.reduce(0, +) - table.intercellSpacing.width * CGFloat(columns.count)
            if extra > 0 {
                let fill = columns.firstIndex { $0.sizing == .fill } ?? columns.count - 1
                if widths.indices.contains(fill) {
                    widths[fill] += extra.rounded(.down)
                }
            } else {
                for index in columns.indices.reversed() where columns[index].sizing == .shrinkableContent && extra < 0 {
                    let cut = min(widths[index] - columns[index].minWidth, -extra)
                    widths[index] -= cut
                    extra += cut
                }
            }
            for (tableColumn, width) in zip(tableColumns, widths) {
                if let tableColumn, abs(tableColumn.width - width) >= 0.5 {
                    tableColumn.width = width
                }
            }
        }

        var selectedIDs: [String] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < shownRows.count ? shownRows[$0].id : nil }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            shownRows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < shownRows.count,
                  let column = parent.columns.first(where: { $0.id == tableColumn.identifier.rawValue })
            else { return nil }
            let content = column.cell(shownRows[row])
            if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? ItemCellView {
                reused.hosting.rootView = content
                return reused
            }
            let cell = ItemCellView(content: content)
            cell.identifier = tableColumn.identifier
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying else { return }
            let ids = Set(selectedIDs)
            // Selected ids hidden from the table (for example by a filter) stay out of reach of
            // the table; only a change made in the table is reported.
            parent.onSelectionChange(ids)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying, let first = tableView.sortDescriptors.first, let key = first.key else { return }
            parent.onSortChange?(ItemTableSort(columnID: key, ascending: first.ascending))
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedRow < shownRows.count else { return }
            parent.onDoubleClick?(shownRows[table.clickedRow].id)
        }

        // MARK: Reordering

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard parent.onMove != nil, row < shownRows.count else { return nil }
            let item = NSPasteboardItem()
            item.setString(shownRows[row].id, forType: ItemNSTableView.rowType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.onMove != nil, (info.draggingSource as? NSTableView) === tableView else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let onMove = parent.onMove else { return false }
            let ids = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: ItemNSTableView.rowType) }
            guard !ids.isEmpty else { return false }
            let moved = shownRows.map(\.id).filter { ids.contains($0) }
            onMove(moved, row)
            return true
        }

        // MARK: Menu and keys

        func menu(forSelection ids: Set<String>) -> NSMenu? {
            guard let builder = parent.menu, !ids.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in builder(ids) {
                menu.addItem(Self.menuItem(item))
            }
            return menu
        }

        private static func menuItem(_ item: ItemTableMenuItem) -> NSMenuItem {
            switch item {
            case .separator:
                return .separator()
            case .action(let title, let enabled, let key, let modifiers, let handler):
                let menuItem = ClosureMenuItem(title: title, handler: handler)
                menuItem.isEnabled = enabled
                menuItem.keyEquivalent = key
                menuItem.keyEquivalentModifierMask = modifiers
                return menuItem
            case .submenu(let title, let enabled, let items):
                let parentItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                for item in items {
                    submenu.addItem(Self.menuItem(item))
                }
                parentItem.submenu = submenu
                parentItem.isEnabled = enabled
                return parentItem
            }
        }

        func copySelection() -> Bool {
            let ids = selectedIDs
            guard let onCopy = parent.onCopy, !ids.isEmpty else { return false }
            onCopy(ids)
            return true
        }

        var canCopy: Bool {
            parent.onCopy != nil && !selectedIDs.isEmpty
        }

        func delete(command: Bool) -> Bool {
            let ids = Set(selectedIDs)
            guard !ids.isEmpty else { return false }
            if command, let onCommandDelete = parent.onCommandDelete {
                onCommandDelete(ids)
                return true
            }
            if !command, let onDelete = parent.onDelete {
                onDelete(ids)
                return true
            }
            return false
        }
    }
}

/// The table view of `ItemTable`: the context menu selects the clicked row first, Copy and the
/// delete keys go to the coordinator.
final class ItemNSTableView: NSTableView, NSMenuItemValidation {
    static let rowType = NSPasteboard.PasteboardType("ca.azavech.hephaestusv2.item-row")

    /// Type-erased access to the coordinator of `ItemTable`.
    var coordinator: AnyObject?

    private var tableCoordinator: ItemTableCoordinating? {
        coordinator as? ItemTableCoordinating
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return tableCoordinator?.contextMenu()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌫ (51) and forward delete (117).
        if event.keyCode == 51 || event.keyCode == 117 {
            let command = flags.contains(.command)
            if flags.subtracting([.command, .function, .numericPad]).isEmpty, tableCoordinator?.deleteKey(command: command) == true {
                return
            }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, event.keyCode == 51, flags.subtracting([.function, .numericPad]) == .command {
            if tableCoordinator?.deleteKey(command: true) == true {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        if tableCoordinator?.copyRows() != true {
            NSSound.beep()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return tableCoordinator?.canCopyRows ?? false
        }
        if menuItem.action == #selector(selectAll(_:)) {
            return allowsMultipleSelection && numberOfRows > 0
        }
        return true
    }
}

/// What `ItemNSTableView` asks its coordinator, whatever the row type.
@MainActor
protocol ItemTableCoordinating: AnyObject {
    func contextMenu() -> NSMenu?
    func copyRows() -> Bool
    var canCopyRows: Bool { get }
    func deleteKey(command: Bool) -> Bool
}

extension ItemTable.Coordinator: ItemTableCoordinating {
    func contextMenu() -> NSMenu? {
        menu(forSelection: Set(selectedIDs))
    }

    func copyRows() -> Bool {
        copySelection()
    }

    var canCopyRows: Bool {
        canCopy
    }

    func deleteKey(command: Bool) -> Bool {
        delete(command: command)
    }
}

/// The scroll view of `ItemTable`: each new layout of its visible area sets the column widths.
final class ItemScrollView: NSScrollView {
    var onTile: (() -> Void)?

    override func tile() {
        super.tile()
        onTile?()
    }
}

/// A table cell hosting a SwiftUI view.
final class ItemCellView: NSTableCellView {
    let hosting: NSHostingView<AnyView>

    init(content: AnyView) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        handler()
    }
}
