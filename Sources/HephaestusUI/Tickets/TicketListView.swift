// OWNER: ui-tickets — the ticket list with its filters, sort and context menu (docs/tickets.md › Ticket list).
import AppKit
import HephaestusCore
import SwiftUI

/// The ticket list; its filters and sort order are `ProjectViewState.ticketList`.
struct TicketListView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    private var key: ProjectKey {
        ProjectKey(deviceID: window.deviceID, projectID: projectID)
    }

    private var listState: TicketListState {
        window.projectStates[key]?.ticketList ?? TicketListState()
    }

    private var selection: Set<String> {
        window.projectStates[key]?.selectedTicketIDs ?? []
    }

    private var allTickets: [Ticket] {
        Array((workspace.tickets[projectID] ?? [:]).values)
    }

    /// The tickets that pass the filters, in the list's sort order.
    private var visibleTickets: [Ticket] {
        let state = listState
        return state.sorted(allTickets.filter(state.matches))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            content
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                statusFilter
                filterField
                    .frame(minWidth: 90)
                bundleButton
                newTicketButton
            }
            VStack(alignment: .leading, spacing: 6) {
                statusFilter
                    .fillingWidth()
                HStack(spacing: 8) {
                    filterField
                    bundleButton
                    newTicketButton
                }
            }
        }
    }

    private var statusFilter: StatusFilterControl {
        StatusFilterControl(selection: Binding(
            get: { listState.statusFilter },
            set: { value in window.updateViewState(of: projectID) { $0.ticketList.statusFilter = value } }
        ))
    }

    private var filterField: some View {
        FilterSearchField(placeholder: "Filter", text: Binding(
            get: { listState.textFilter },
            set: { value in window.updateViewState(of: projectID) { $0.ticketList.textFilter = value } }
        ))
    }

    private var bundleButton: some View {
        Button {
            createBundleFromSelection(selection)
        } label: {
            Image(systemName: "shippingbox")
        }
        .buttonStyle(.borderless)
        .help("Create Bundle from Selection")
        .accessibilityLabel("Create Bundle from Selection")
        .disabled(selection.isEmpty || !window.isConnected)
    }

    private var newTicketButton: some View {
        Button {
            newTicket()
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("New Ticket")
        .accessibilityLabel("New Ticket")
        .disabled(!window.isConnected)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if allTickets.isEmpty {
            VStack(spacing: 8) {
                Text("No Tickets")
                    .font(.title3.weight(.semibold))
                Text("Create a ticket, or ask Claude in the project chat.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("New Ticket") { newTicket() }
                    .disabled(!window.isConnected)
                    .padding(.top, 4)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let tickets = visibleTickets
            if tickets.isEmpty {
                VStack(spacing: 8) {
                    Text("No Matching Tickets")
                        .font(.title3.weight(.semibold))
                    Button("Clear Filters") {
                        window.updateViewState(of: projectID) { $0.ticketList.clearFilters() }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(tickets)
            }
        }
    }

    private func table(_ tickets: [Ticket]) -> some View {
        let state = listState
        return ItemTable(
            rows: tickets,
            columns: Self.columns,
            selection: selection,
            onSelectionChange: { ids in
                window.updateViewState(of: projectID) { $0.selectedTicketIDs = ids }
            },
            sort: ItemTableSort(columnID: state.sortColumn.rawValue, ascending: state.sortAscending),
            onSortChange: { sort in
                guard let column = TicketListState.SortColumn(rawValue: sort.columnID) else { return }
                window.updateViewState(of: projectID) {
                    $0.ticketList.sortColumn = column
                    $0.ticketList.sortAscending = sort.ascending
                }
            },
            menu: { ids in menu(for: ids) },
            onCopy: { ids in TicketActions.copyIDs(ids) },
            onCommandDelete: { ids in
                Task { await TicketActions.deleteTickets(ids, workspace: workspace, window: window) }
            }
        )
    }

    static let columns: [ItemTableColumn<Ticket>] = [
        ItemTableColumn(id: TicketListState.SortColumn.id.rawValue, title: "ID", minWidth: 24, sizing: .content,
                        contentWidth: { ItemTableText.width($0.id, font: ItemTableText.monospaced) }) { ticket in
            AnyView(Text(ticket.id)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading))
        },
        ItemTableColumn(id: TicketListState.SortColumn.title.rawValue, title: "Title", minWidth: 40, sizing: .fill) { ticket in
            AnyView(Text(ticket.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(ticket.title))
        },
        ItemTableColumn(id: TicketListState.SortColumn.status.rawValue, title: "Status", minWidth: 24, sizing: .content,
                        contentWidth: { _ in StatusCapsule.maxWidth }) { ticket in
            AnyView(StatusCapsule(status: ticket.status)
                .frame(maxWidth: .infinity, alignment: .leading))
        },
        ItemTableColumn(id: TicketListState.SortColumn.created.rawValue, title: "Created", minWidth: 40, sizing: .shrinkableContent,
                        contentWidth: { ItemTableText.width(TicketFormat.created($0.created), font: ItemTableText.body) }) { ticket in
            AnyView(Text(TicketFormat.created(ticket.created))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading))
        },
    ]

    // MARK: Menu

    private func menu(for ids: Set<String>) -> [ItemTableMenuItem] {
        let tickets = ids.compactMap { workspace.tickets[projectID]?[$0] }
        let single = ids.count == 1 ? tickets.first : nil
        let canImplement = single.map { TicketActions.implementAvailability(of: $0, workspace: workspace).enabled } ?? false
        let ordered = visibleTickets.map(\.id).filter { ids.contains($0) }
        return [
            .action("Implement", enabled: canImplement) {
                guard let single else { return }
                TicketActions.implementFromList(ticketID: single.id, workspace: workspace, window: window, projectID: projectID)
            },
            .submenu("Set Status", enabled: !ids.isEmpty, TicketStatus.allCases.map { status in
                .action(status.label) {
                    Task { await TicketActions.setStatus(status, of: Array(ids), workspace: workspace, window: window) }
                }
            }),
            .action("Create Bundle from Selection…", enabled: !ids.isEmpty) {
                createBundleFromSelection(ids)
            },
            .separator,
            .action("Copy ID", enabled: !ids.isEmpty, keyEquivalent: "c", modifiers: .command) {
                TicketActions.copyIDs(ordered.isEmpty ? TicketFormat.ascending(Array(ids)) : ordered)
            },
            .separator,
            .action("Delete…", enabled: !ids.isEmpty, keyEquivalent: "\u{8}", modifiers: .command) {
                Task { await TicketActions.deleteTickets(ids, workspace: workspace, window: window) }
            },
        ]
    }

    // MARK: Actions

    private func newTicket() {
        guard window.isConnected else { return }
        window.sheet = .newTicket(projectID: projectID)
    }

    private func createBundleFromSelection(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        window.sheet = .ticketPicker(projectID: projectID, bundleID: nil, checkedTicketIDs: TicketFormat.ascending(Array(ids)))
    }
}

/// The status filter: a small segmented control whose segments are as wide as their titles
/// (211 pt), so that it fits the list at its 240 pt minimum width. SwiftUI's segmented picker
/// gives every segment the width of the widest (318 pt), which made the list's content wider than
/// its column. With `fillsWidth` it takes the width it is offered, never less than its natural
/// width, and its segments share the extra space.
struct StatusFilterControl: NSViewRepresentable {
    @Binding var selection: TicketListState.StatusFilter
    var fillsWidth = false

    private static let filters = TicketListState.StatusFilter.allCases

    /// The same control, taking the full width it is offered.
    func fillingWidth() -> StatusFilterControl {
        var control = self
        control.fillsWidth = true
        return control
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: Self.filters.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        control.setAccessibilityLabel("Status")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.segmentDistribution = fillsWidth ? .fill : .fit
        let index = Self.filters.firstIndex(of: selection) ?? 0
        if control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        guard fillsWidth, let width = proposal.width, width.isFinite else { return natural }
        return CGSize(width: max(width, natural.width), height: natural.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: StatusFilterControl

        init(_ parent: StatusFilterControl) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard StatusFilterControl.filters.indices.contains(sender.selectedSegment) else { return }
            parent.selection = StatusFilterControl.filters[sender.selectedSegment]
        }
    }
}

/// A native search field bound to a string.
struct FilterSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// Return in the field: nil lets the field do nothing.
    var onSubmit: (() -> Void)?
    /// Called when the field gains or loses the keyboard focus.
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusReportingSearchField()
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocusChange?(true) }
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: FilterSearchField

        init(_ parent: FilterSearchField) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSearchField) {
            if parent.text != sender.stringValue {
                parent.text = sender.stringValue
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange?(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit?()
                return true
            }
            return false
        }
    }
}

/// A search field that reports when it takes the keyboard focus.
private final class FocusReportingSearchField: NSSearchField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocus?()
        }
        return result
    }
}
