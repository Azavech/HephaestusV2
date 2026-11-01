// OWNER: ui-tickets — the actions shared by the ticket list, the ticket detail, the bundle list and
// the bundle detail: status changes, deleting, Implement, Implement All, copying ids, the
// confirmations and the shared formats (docs/tickets.md › Ticket list, › Ticket chats and
// Implement, › Implement All, › Deleting).
import AppKit
import HephaestusCore
import SwiftUI

/// Shared formats of the Tickets and Bundles sections.
enum TicketFormat {
    /// The Created column: abbreviated month and short time, in the user's locale and time zone.
    static func created(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The relative update time of the ticket and bundle details: `just now` less than a minute
    /// after the change (a date in the future included), then for example `5 minutes ago`.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// `You` or `Claude`.
    static func author(_ author: Author) -> String {
        author == .claude ? "Claude" : "You"
    }

    /// The ticket ids of a list in ascending ticket number (`HEPH-9` before `HEPH-10`).
    static func ascending(_ ids: [String]) -> [String] {
        ids.sorted { TicketListState.number(of: $0) < TicketListState.number(of: $1) }
    }
}

/// The status capsule: To Do gray, In Progress blue, In Review orange, Done green.
struct StatusCapsule: View {
    let status: TicketStatus

    /// The width of the widest capsule, for the Status columns: its caption text in medium weight
    /// and 7 pt on each side.
    static let maxWidth: CGFloat = {
        let caption = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        let font = NSFont.systemFont(ofSize: caption, weight: .medium)
        return (TicketStatus.allCases.map { ItemTableText.width($0.label, font: font) }.max() ?? 0) + 14
    }()

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Self.color(of: status)))
            .fixedSize()
    }

    /// The colour of a status, also used by the segments of `BundleProgressBar`.
    static func color(of status: TicketStatus) -> Color {
        switch status {
        case .todo: return .gray
        case .inProgress: return .blue
        case .review: return .orange
        case .done: return .green
        }
    }
}

/// The actions of the Tickets and Bundles sections.
@MainActor
enum TicketActions {
    /// The chat states that make a chat active for the Implement alert.
    static let activeStates: Set<ChatState> = [.starting, .running, .waitingPermission, .waitingAnswers]

    /// The AppKit window of a main window, for alerts and panels.
    static func nsWindow(_ window: WindowState) -> NSWindow? {
        window.app?.windowRegistry.window(forMain: window.id)
    }

    /// An alert with a confirming button and Cancel (Escape); true when confirmed.
    static func confirm(_ title: String, message: String? = nil, button: String, destructive: Bool = true,
                        in window: WindowState) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        let confirm = alert.addButton(withTitle: button)
        confirm.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return await AlertPresenter.present(alert, on: nsWindow(window)) == .alertFirstButtonReturn
    }

    // MARK: Tickets

    /// Set Status ▸: `tickets.setStatus` for each ticket; the first failure shows
    /// `<item title> failed`.
    static func setStatus(_ status: TicketStatus, of ticketIDs: [String], workspace: DeviceWorkspace,
                          window: WindowState, itemTitle: String = "Set Status") async {
        for ticketID in TicketFormat.ascending(ticketIDs) {
            do {
                _ = try await workspace.call(TicketsSetStatus.self, TicketsSetStatus.Params(ticketID: ticketID, status: status.rawValue))
            } catch {
                window.alert = .failure(itemTitle, error)
                return
            }
        }
    }

    /// Delete…: `Delete <ID>?` or `Delete <n> tickets?` with `Ticket files and attachments move to
    /// the Trash. Chats are kept.`, then `tickets.delete` for each.
    static func deleteTickets(_ ticketIDs: Set<String>, workspace: DeviceWorkspace, window: WindowState) async {
        guard !ticketIDs.isEmpty else { return }
        let ids = TicketFormat.ascending(Array(ticketIDs))
        let title = ids.count == 1 ? "Delete \(ids[0])?" : "Delete \(ids.count) tickets?"
        guard await confirm(title, message: "Ticket files and attachments move to the Trash. Chats are kept.",
                            button: "Delete", in: window)
        else { return }
        for ticketID in ids {
            do {
                _ = try await workspace.call(TicketsDelete.self, TicketsDelete.Params(ticketID: ticketID))
            } catch {
                window.alert = .failure("Delete", error)
                return
            }
        }
    }

    /// Copy ID: the ids, one per line.
    static func copyIDs(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ids.joined(separator: "\n"), forType: .string)
    }

    /// Whether Implement is enabled, and its tooltip while disabled.
    static func implementAvailability(of ticket: Ticket, workspace: DeviceWorkspace) -> (enabled: Bool, help: String?) {
        if ticket.status == .done {
            return (false, "Set the status to To Do or In Progress to implement this ticket.")
        }
        if workspace.claudeStatus?.available != true {
            return (false, "Claude CLI is not available on \(workspace.deviceName).")
        }
        return (true, nil)
    }

    /// Implement: the active-chat alert when a chat of the ticket is active, then
    /// `chats.implementTicket` with no settings; the Chats tab selects the new chat.
    static func implement(ticketID: String, workspace: DeviceWorkspace, window: WindowState) async {
        guard let projectID = Identifiers.projectID(of: ticketID),
              let ticket = workspace.tickets[projectID]?[ticketID]
        else { return }
        if hasActiveChat(ticket.chatIDs, workspace: workspace) {
            guard await confirm("A chat of \(ticketID) is still active. Start another implementation?",
                                button: "Implement", destructive: false, in: window)
            else { return }
        }
        do {
            let meta = try await workspace.call(ChatsImplementTicket.self, ChatsImplementTicket.Params(ticketID: ticketID))
            LinkedChatsView.select(meta.id.uuidString, draft: false, owner: .ticket(ticketID), window: window, projectID: projectID)
        } catch {
            window.alert = .failure("Implement", error)
        }
    }

    /// Implement from the list's context menu: selects the ticket and its Chats tab first.
    static func implementFromList(ticketID: String, workspace: DeviceWorkspace, window: WindowState, projectID: String) {
        window.updateViewState(of: projectID) {
            $0.selectedTicketIDs = [ticketID]
            $0.ticketTab = .chats
        }
        Task {
            await implement(ticketID: ticketID, workspace: workspace, window: window)
        }
    }

    static func hasActiveChat(_ chatIDs: [ChatID], workspace: DeviceWorkspace) -> Bool {
        chatIDs.contains { chatID in
            workspace.chats[chatID.uuidString].map { activeStates.contains($0.state) } ?? false
        }
    }

    // MARK: Bundles

    /// Whether Implement All is enabled, and its tooltip while disabled.
    static func implementAllAvailability(of bundle: TicketBundle, workspace: DeviceWorkspace,
                                         projectID: String) -> (enabled: Bool, help: String?) {
        if bundle.ticketIDs.isEmpty {
            return (false, "This bundle has no tickets.")
        }
        let tickets = workspace.tickets[projectID] ?? [:]
        // An id without a ticket file does not count (docs/tickets.md › Implement All).
        let open = bundle.ticketIDs.contains { tickets[$0].map { $0.status != .done } ?? false }
        if !open {
            return (false, "All tickets of this bundle are done.")
        }
        if workspace.claudeStatus?.available != true {
            return (false, "Claude CLI is not available on \(workspace.deviceName).")
        }
        return (true, nil)
    }

    /// Implement All: the active-chat alert, then `chats.implementBundle`; the bundle's Chats tab
    /// selects the new chat.
    static func implementAll(bundleID: String, workspace: DeviceWorkspace, window: WindowState) async {
        guard let projectID = Identifiers.projectID(of: bundleID),
              let bundle = workspace.bundles[projectID]?[bundleID]
        else { return }
        if hasActiveChat(bundle.chatIDs, workspace: workspace) {
            guard await confirm("A chat of \(bundleID) is still active. Start another implementation?",
                                button: "Implement", destructive: false, in: window)
            else { return }
        }
        do {
            let meta = try await workspace.call(ChatsImplementBundle.self, ChatsImplementBundle.Params(bundleID: bundleID))
            LinkedChatsView.select(meta.id.uuidString, draft: false, owner: .bundle(bundleID), window: window, projectID: projectID)
        } catch {
            window.alert = .failure("Implement All", error)
        }
    }

    /// Implement All from the bundle list's context menu: selects the bundle and its Chats tab
    /// first.
    static func implementAllFromList(bundleID: String, workspace: DeviceWorkspace, window: WindowState, projectID: String) {
        window.updateViewState(of: projectID) {
            $0.selectedBundleID = bundleID
            $0.bundleTab = .chats
        }
        Task {
            await implementAll(bundleID: bundleID, workspace: workspace, window: window)
        }
    }

    /// Delete… of a bundle: `Delete <ID>?` with `Its tickets and chats are kept.`, then
    /// `bundles.delete`.
    static func deleteBundle(_ bundleID: String, workspace: DeviceWorkspace, window: WindowState) async {
        guard await confirm("Delete \(bundleID)?", message: "Its tickets and chats are kept.", button: "Delete", in: window)
        else { return }
        do {
            _ = try await workspace.call(BundlesDelete.self, BundlesDelete.Params(bundleID: bundleID))
        } catch {
            window.alert = .failure("Delete", error)
        }
    }

    /// Waits until the workspace holds what a mutation created: its event may arrive after the
    /// result on a local connection (docs/engine-api.md › Delivery and ordering). Gives up after
    /// 2 seconds.
    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<40 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
