// OWNER: ui-code-docs — the outline view of the file tree and the docs tree: rows, disclosure,
// selection, clicks, Return, ⌫ and context menus (docs/code-editor.md › File tree;
// docs/documentation-viewer.md › Docs tree).
import AppKit
import SwiftUI

/// One row of an outline tree.
struct OutlineRow: Equatable {
    enum Kind: Equatable {
        case folder
        case item
        /// A line such as `Empty`, in secondary color, not selectable.
        case message
    }

    var id: String
    var title: String
    var symbol: String?
    var kind: Kind
    /// Drawn with 45 % opacity.
    var isDimmed = false
    /// A small spinner while the folder is listed.
    var isLoading = false
    var tooltip: String?
    /// The rows of an expanded folder.
    var children: [OutlineRow] = []
}

/// An item of a tree's context menu.
struct OutlineMenuItem {
    var title: String
    var action: () -> Void
    var isSeparator = false

    static var separator: OutlineMenuItem {
        OutlineMenuItem(title: "", action: {}, isSeparator: true)
    }
}

/// An `NSOutlineView` showing `rows`, with its expansion and selection kept by the caller.
struct OutlineTreeView: NSViewRepresentable {
    var rows: [OutlineRow]
    var expanded: Set<String>
    var selection: String?
    /// The selected row changed by a click or the arrow keys.
    var onSelect: (String?) -> Void
    /// A row was clicked (not on its disclosure triangle).
    var onClick: (OutlineRow) -> Void = { _ in }
    var onDoubleClick: (OutlineRow) -> Void = { _ in }
    /// Return on the selected row.
    var onReturn: (OutlineRow) -> Void = { _ in }
    var onExpand: (String) -> Void
    var onCollapse: (String) -> Void
    /// ⌫ or ⌘⌫ on the selected row.
    var onDelete: (OutlineRow) -> Void = { _ in }
    /// The context menu of a row, or of the empty area (nil).
    var menu: (OutlineRow?) -> [OutlineMenuItem] = { _ in [] }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyedOutlineView()
        outline.headerView = nil
        outline.style = .inset
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.action = #selector(Coordinator.clicked(_:))
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.keyHandler = coordinator
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outline: NSOutlineView?
        private var parent: OutlineTreeView?
        private var rows: [OutlineRow] = []
        private var items: [String: Item] = [:]
        private var rootItems: [Item] = []
        private var isSyncing = false
        private var lastSelection: String?

        /// An outline item: the same object for the same id across reloads.
        final class Item: NSObject {
            let id: String
            var row: OutlineRow
            var children: [Item] = []

            init(row: OutlineRow) {
                self.id = row.id
                self.row = row
            }
        }

        func update(_ view: OutlineTreeView) {
            parent = view
            guard let outline else { return }
            isSyncing = true
            defer { isSyncing = false }
            if view.rows != rows {
                rows = view.rows
                var seen: [String: Item] = [:]
                rootItems = view.rows.map { build($0, seen: &seen) }
                items = seen
                outline.reloadData()
            }
            syncExpansion(rootItems, expanded: view.expanded)
            syncSelection(view.selection)
        }

        private func build(_ row: OutlineRow, seen: inout [String: Item]) -> Item {
            let item = items[row.id] ?? Item(row: row)
            item.row = row
            item.children = row.children.map { build($0, seen: &seen) }
            seen[row.id] = item
            return item
        }

        private func syncExpansion(_ level: [Item], expanded: Set<String>) {
            guard let outline else { return }
            for item in level where item.row.kind == .folder {
                let shouldExpand = expanded.contains(item.id)
                if shouldExpand {
                    if !outline.isItemExpanded(item) {
                        outline.expandItem(item)
                    }
                    syncExpansion(item.children, expanded: expanded)
                } else if outline.isItemExpanded(item) {
                    outline.collapseItem(item)
                }
            }
        }

        private func syncSelection(_ selection: String?) {
            guard let outline else { return }
            let row = selection.flatMap { items[$0] }.map { outline.row(forItem: $0) } ?? -1
            if row >= 0 {
                if outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                if selection != lastSelection {
                    outline.scrollRowToVisible(row)
                }
            } else if outline.selectedRow >= 0 {
                outline.deselectAll(nil)
            }
            lastSelection = selection
        }

        private func row(at index: Int) -> OutlineRow? {
            guard index >= 0, let item = outline?.item(atRow: index) as? Item else { return nil }
            return item.row
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? Item else { return rootItems.count }
            return item.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item = item as? Item else { return rootItems[index] }
            return item.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Item)?.row.kind == .folder
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("OutlineCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? OutlineCellView) ?? OutlineCellView()
            cell.identifier = identifier
            cell.configure(item.row)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Item)?.row.kind != .message
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let outline else { return }
            let id = row(at: outline.selectedRow)?.id
            lastSelection = id
            parent?.onSelect(id)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncing, let item = notification.userInfo?["NSObject"] as? Item else { return }
            parent?.onExpand(item.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncing, let item = notification.userInfo?["NSObject"] as? Item else { return }
            parent?.onCollapse(item.id)
        }

        // MARK: Mouse and keys

        @objc func clicked(_ sender: Any?) {
            guard let outline, let row = row(at: outline.clickedRow), row.kind != .message else { return }
            if let event = NSApp.currentEvent {
                let point = outline.convert(event.locationInWindow, from: nil)
                if outline.frameOfOutlineCell(atRow: outline.clickedRow).contains(point) { return }
            }
            parent?.onClick(row)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, let row = row(at: outline.clickedRow), row.kind != .message else { return }
            parent?.onDoubleClick(row)
        }

        func returnPressed() {
            guard let outline, let row = row(at: outline.selectedRow) else { return }
            parent?.onReturn(row)
        }

        func deletePressed() {
            guard let outline, let row = row(at: outline.selectedRow) else { return }
            parent?.onDelete(row)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, let parent else { return }
            let clicked = row(at: outline.clickedRow)
            if clicked?.kind == .message { return }
            for entry in parent.menu(clicked) {
                if entry.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: entry.title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ActionBox(entry.action)
                menu.addItem(item)
            }
        }

        @objc private func menuItemChosen(_ sender: NSMenuItem) {
            (sender.representedObject as? ActionBox)?.action()
        }
    }

    /// A menu item's action.
    final class ActionBox: NSObject {
        let action: () -> Void

        init(_ action: @escaping () -> Void) {
            self.action = action
        }
    }
}

/// The outline view with Return, ⌫ and ⌘⌫.
final class KeyedOutlineView: NSOutlineView {
    weak var keyHandler: OutlineTreeView.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            keyHandler?.returnPressed()
        case 51 where event.modifierFlags.intersection([.shift, .option, .control]).isEmpty:
            keyHandler?.deletePressed()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.keyCode == 51,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
            keyHandler?.deletePressed()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A row: icon, title and spinner.
final class OutlineCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(icon)
        addSubview(label)
        addSubview(spinner)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ row: OutlineRow) {
        label.stringValue = row.title
        if let symbol = row.symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.isHidden = false
        } else {
            icon.image = nil
            icon.isHidden = true
        }
        label.textColor = row.kind == .message ? .secondaryLabelColor : .labelColor
        alphaValue = row.isDimmed ? 0.45 : 1
        toolTip = row.tooltip
        if row.isLoading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}
