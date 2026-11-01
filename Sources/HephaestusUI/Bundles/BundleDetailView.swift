// OWNER: ui-tickets — the bundle detail with its Tickets and Chats tabs (docs/tickets.md › Bundles section, › Implement All).
import AppKit
import HephaestusCore
import SwiftUI

/// A row of a bundle's Tickets tab; a listed id without a ticket file has no status.
struct BundleTicketRow: Identifiable, Hashable {
    var id: String
    var title: String
    var status: TicketStatus?
}

/// The detail of one bundle.
struct BundleDetailView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let bundleID: String

    @State private var ticketSelection: Set<String> = []

    private var bundle: TicketBundle? {
        workspace.bundles[projectID]?[bundleID]
    }

    private var tab: BundleDetailTab {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)]?.bundleTab ?? .tickets
    }

    var body: some View {
        Group {
            if let bundle {
                VStack(spacing: 0) {
                    header(bundle)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    tabPicker(bundle)
                        .padding(.bottom, 8)
                    Divider()
                    switch tab {
                    case .tickets:
                        ticketsTab(bundle)
                    case .chats:
                        LinkedChatsView(window: window, workspace: workspace, projectID: projectID, owner: .bundle(bundle.id),
                                        chatIDs: bundle.chatIDs)
                    }
                }
            } else {
                NotFoundView(kind: "Bundle", id: bundleID)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Header

    /// ID, the inline title field, `Created <date> · Updated <relative time>`, and the progress bar
    /// with `<done> of <total> done`.
    private func header(_ bundle: TicketBundle) -> some View {
        let progress = BundleProgress.of(bundle, tickets: workspace.tickets[projectID] ?? [:])
        return VStack(alignment: .leading, spacing: 6) {
            Text(bundle.id)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            InlineTitleField(stored: bundle.title) { title in
                do {
                    _ = try await workspace.call(BundlesUpdate.self, BundlesUpdate.Params(bundleID: bundle.id, title: title))
                    return true
                } catch {
                    window.alert = .failure("Title", error)
                    return false
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Created \(TicketFormat.created(bundle.created)) · Updated \(TicketFormat.relative(bundle.updated, now: context.date))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
                Text("\(progress.done) of \(progress.total) done")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tabPicker(_ bundle: TicketBundle) -> some View {
        let chatCount = LinkedChatsView.listedChats(bundle.chatIDs, workspace: workspace).count
        return Picker("Tab", selection: Binding(
            get: { tab },
            set: { newTab in
                if newTab == .chats, tab != .chats {
                    LinkedChatsView.selectMostRecent(owner: .bundle(bundle.id), chatIDs: bundle.chatIDs, workspace: workspace,
                                                     window: window, projectID: projectID)
                }
                window.updateViewState(of: projectID) { $0.bundleTab = newTab }
            }
        )) {
            Text("Tickets (\(bundle.ticketIDs.count))").tag(BundleDetailTab.tickets)
            Text("Chats (\(chatCount))").tag(BundleDetailTab.chats)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: Tickets tab

    @ViewBuilder
    private func ticketsTab(_ bundle: TicketBundle) -> some View {
        if bundle.ticketIDs.isEmpty {
            VStack(spacing: 10) {
                Text("No Tickets in This Bundle")
                    .font(.title3.weight(.semibold))
                Button("Add Tickets…") { addTickets() }
                    .disabled(!window.isConnected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Button("Add Tickets…") { addTickets() }
                        .disabled(!window.isConnected)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ItemTable(
                    rows: rows(bundle),
                    columns: Self.columns,
                    selection: ticketSelection,
                    onSelectionChange: { ticketSelection = $0 },
                    menu: { ids in menu(for: ids, bundle: bundle) },
                    onDoubleClick: { ticketID in showTicket(ticketID) },
                    onDelete: { ids in remove(ids, from: bundle) },
                    onMove: { ids, row in move(ids, to: row, in: bundle) }
                )
            }
        }
    }

    /// The rows in bundle order; a missing ticket shows `Ticket not found` and no status.
    private func rows(_ bundle: TicketBundle) -> [BundleTicketRow] {
        let tickets = workspace.tickets[projectID] ?? [:]
        return bundle.ticketIDs.map { id in
            if let ticket = tickets[id] {
                return BundleTicketRow(id: id, title: ticket.title, status: ticket.status)
            }
            return BundleTicketRow(id: id, title: "Ticket not found", status: nil)
        }
    }

    static let columns: [ItemTableColumn<BundleTicketRow>] = [
        ItemTableColumn(id: "id", title: "ID", minWidth: 24, sizing: .content,
                        contentWidth: { ItemTableText.width($0.id, font: ItemTableText.monospaced) }, sortable: false) { row in
            AnyView(Text(row.id)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading))
        },
        ItemTableColumn(id: "title", title: "Title", minWidth: 40, sizing: .fill, sortable: false) { row in
            AnyView(Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(row.status == nil ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.title))
        },
        ItemTableColumn(id: "status", title: "Status", minWidth: 24, sizing: .content,
                        contentWidth: { _ in StatusCapsule.maxWidth }, sortable: false) { row in
            AnyView(Group {
                if let status = row.status {
                    StatusCapsule(status: status)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading))
        },
    ]

    private func menu(for ids: Set<String>, bundle: TicketBundle) -> [ItemTableMenuItem] {
        let tickets = workspace.tickets[projectID] ?? [:]
        let existing = ids.filter { tickets[$0] != nil }
        return [
            .action("Show Ticket", enabled: ids.count == 1) {
                if let id = ids.first { showTicket(id) }
            },
            .submenu("Set Status", enabled: !existing.isEmpty && window.isConnected, TicketStatus.allCases.map { status in
                .action(status.label) {
                    Task { await TicketActions.setStatus(status, of: Array(existing), workspace: workspace, window: window) }
                }
            }),
            .separator,
            .action("Remove from Bundle", enabled: window.isConnected, keyEquivalent: "\u{8}", modifiers: []) {
                remove(ids, from: bundle)
            },
        ]
    }

    // MARK: Actions

    private func addTickets() {
        guard window.isConnected else { return }
        window.sheet = .ticketPicker(projectID: projectID, bundleID: bundleID, checkedTicketIDs: [])
    }

    /// Show Ticket: opens the ticket in the Tickets section.
    private func showTicket(_ ticketID: String) {
        Task { await window.navigate(to: .ticket(ticketID: ticketID)) }
    }

    /// Remove from Bundle: `bundles.update` without the selected rows, without confirmation; the
    /// tickets are not deleted.
    private func remove(_ ids: Set<String>, from bundle: TicketBundle) {
        guard !ids.isEmpty else { return }
        let remaining = bundle.ticketIDs.filter { !ids.contains($0) }
        update(bundle.id, ticketIDs: remaining, itemTitle: "Remove from Bundle")
        ticketSelection.subtract(ids)
    }

    /// Dragging rows reorders the bundle with `bundles.update`.
    private func move(_ ids: [String], to row: Int, in bundle: TicketBundle) {
        let moving = Set(ids)
        var order = bundle.ticketIDs
        let insertion = order.prefix(min(row, order.count)).filter { !moving.contains($0) }.count
        let moved = order.filter { moving.contains($0) }
        order.removeAll { moving.contains($0) }
        order.insert(contentsOf: moved, at: min(insertion, order.count))
        guard order != bundle.ticketIDs else { return }
        // DOC-GAP: docs/tickets.md › Bundles section gives no item title for a failed reordering;
        // its alert is `Reorder failed`.
        update(bundle.id, ticketIDs: order, itemTitle: "Reorder")
    }

    private func update(_ bundleID: String, ticketIDs: [String], itemTitle: String) {
        Task {
            do {
                _ = try await workspace.call(BundlesUpdate.self, BundlesUpdate.Params(bundleID: bundleID, ticketIDs: ticketIDs))
            } catch {
                window.alert = .failure(itemTitle, error)
            }
        }
    }
}
