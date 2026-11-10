// OWNER: ui-tickets — the actions shared by the ticket list, the ticket detail, the bundle list and
// the bundle detail: status changes, deleting, Implement, Implement All, copying ids, the
// confirmations and the shared formats (docs/tickets.md › Ticket list, › Ticket chats and
// Implement, › Implement sheet, › Implement All, › Deleting).
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

    /// The author of a comment: `You`, `Claude`, or for a comment Claude added from a chat, which
    /// has a model, `Claude (<model> · <effort>)` (docs/tickets.md › Comments).
    static func author(of comment: Comment, models: [ClaudeModel]) -> String {
        guard comment.author == .claude, comment.model != nil else { return author(comment.author) }
        return ChatFormat.claudeName(model: comment.model, effort: comment.effort, models: models)
    }

    /// The ticket ids of a list in ascending ticket number (`HEPH-9` before `HEPH-10`).
    static func ascending(_ ids: [String]) -> [String] {
        ids.sorted { TicketListState.number(of: $0) < TicketListState.number(of: $1) }
    }
}

/// The status capsule: To Do gray, In Progress blue, In Review orange, Done green.
struct StatusCapsule: View {
    let status: TicketStatus

    /// The font of the capsule's text, `.caption` in medium weight.
    static let font: NSFont = {
        let caption = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        return NSFont.systemFont(ofSize: caption, weight: .medium)
    }()

    /// The width of the widest capsule, for the Status columns: its caption text in medium weight
    /// and 7 pt on each side.
    static let maxWidth: CGFloat = {
        (TicketStatus.allCases.map { ItemTableText.width($0.label, font: font) }.max() ?? 0) + 14
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

    /// The capsule of a bundle status, in the colour of the ticket status of the same name
    /// (docs/tickets.md › Bundle status rules).
    init(status: BundleStatus) {
        self.status = status.capsuleStatus
    }

    init(status: TicketStatus) {
        self.status = status
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

/// The project badge of the Project column: the project's name in a capsule drawn like the status
/// capsule, filled with the project's color, or with the gray of To Do when the project has none
/// (docs/tickets.md › Ticket list). The name truncates with an ellipsis inside the capsule.
struct ProjectBadge: View {
    let name: String
    /// The project's color, `#RRGGBB`; nil for none.
    let color: String?

    var body: some View {
        Text(name)
            .font(.caption.weight(.medium))
            .foregroundStyle(Self.textColor(of: color))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Self.fill(of: color)))
    }

    /// The width of a badge that shows the whole name: the name in the capsule's font and 7 pt
    /// on each side.
    static func width(of name: String) -> CGFloat {
        ItemTableText.width(name, font: StatusCapsule.font) + 14
    }

    /// The capsule's fill: the project's color, or the gray of the To Do capsule.
    static func fill(of color: String?) -> Color {
        color.flatMap(ColorSwatches.nsColor).map { Color(nsColor: $0) } ?? StatusCapsule.color(of: .todo)
    }

    /// The text's color: black or white, whichever has the higher contrast with the project's
    /// color; white on the gray of a project without color.
    static func textColor(of color: String?) -> Color {
        color.map(usesBlackText) == true ? .black : .white
    }

    /// Whether black text has a higher contrast ratio than white text with a hex color, from the
    /// color's WCAG 2 relative luminance; false for a text that is not a hex color.
    static func usesBlackText(_ hex: String) -> Bool {
        guard let components = SystemColors.components(ofHex: hex) else { return false }
        func linear(_ value: Int) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(components.red) + 0.7152 * linear(components.green) + 0.0722 * linear(components.blue)
        return (luminance + 0.05) / 0.05 > 1.05 / (luminance + 0.05)
    }
}

/// The blocked mark of the ticket list: a red `hand.raised.fill` with the tooltip `Blocked by
/// HEPH-15, HEPH-16`, shown while a Depends on ticket is not done (docs/tickets.md › Ticket list).
struct BlockedMark: View {
    /// The Depends on tickets that are not done; the mark is hidden without them.
    let blockers: [String]

    /// The width the mark adds to the Status column.
    static let width: CGFloat = 16

    var body: some View {
        if !blockers.isEmpty {
            let help = "Blocked by \(blockers.joined(separator: ", "))"
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.red)
                .help(help)
                .accessibilityLabel(help)
        }
    }
}

/// The actions of the Tickets and Bundles sections.
@MainActor
enum TicketActions {
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

    /// The Depends on tickets of a ticket that exist among `tickets` and are not done, in
    /// ascending ticket number (docs/tickets.md › Ticket links).
    static func unfinishedDependencies(of ticket: Ticket, among tickets: [String: Ticket]) -> [String] {
        let ids = Set(ticket.links.filter { $0.kind == .dependsOn }.map(\.ticketID))
        return TicketFormat.ascending(ids.filter { id in tickets[id].map { $0.status != .done } ?? false })
    }

    /// Implement: while one of the ticket's Depends on tickets is not done, the alert `<ID> depends
    /// on HEPH-15, HEPH-16, which are not done. Implement it anyway?` comes first, and Cancel
    /// starts nothing; then the Implement sheet opens, whatever chats of the ticket are active.
    static func implement(ticketID: String, workspace: DeviceWorkspace, window: WindowState) async {
        if let projectID = Identifiers.projectID(of: ticketID), let ticket = workspace.tickets[projectID]?[ticketID] {
            let blockers = unfinishedDependencies(of: ticket, among: workspace.tickets[projectID] ?? [:])
            if !blockers.isEmpty {
                let which = blockers.count == 1 ? "which is not done" : "which are not done"
                let title = "\(ticketID) depends on \(blockers.joined(separator: ", ")), \(which). Implement it anyway?"
                guard await confirm(title, button: "Implement", destructive: false, in: window) else { return }
            }
        }
        window.sheet = .implementTicket(ticketID: ticketID)
    }

    /// Implement from the list's context menu: selects the ticket in the list of `projectID` and
    /// its Chats tab first. The detail of a sub project's ticket keeps its tab in the view state of
    /// the ticket's project.
    static func implementFromList(ticketID: String, workspace: DeviceWorkspace, window: WindowState, projectID: String) async {
        window.updateViewState(of: projectID) { $0.selectedTicketIDs = [ticketID] }
        window.updateViewState(of: Identifiers.projectID(of: ticketID) ?? projectID) { $0.ticketTab = .chats }
        await implement(ticketID: ticketID, workspace: workspace, window: window)
    }

    /// Start in the Implement sheet: `chats.implementTicket` or `chats.implementBundle` with the
    /// chosen settings; the Chats tab of the ticket or the bundle selects the new chat.
    static func start(_ owner: LinkedChatsOwner, settings: ChatSettings, workspace: DeviceWorkspace,
                      window: WindowState) async throws {
        let meta: ChatMeta
        switch owner {
        case .ticket(let ticketID):
            meta = try await workspace.call(ChatsImplementTicket.self, ChatsImplementTicket.Params(ticketID: ticketID, settings: settings))
        case .bundle(let bundleID):
            meta = try await workspace.call(ChatsImplementBundle.self, ChatsImplementBundle.Params(bundleID: bundleID, settings: settings))
        }
        guard let projectID = Identifiers.projectID(of: owner.id) else { return }
        LinkedChatsView.select(meta.id.uuidString, draft: false, owner: owner, window: window, projectID: projectID)
    }

    // MARK: Bundles

    /// Set Status ▸ of the bundle list and the Status pop-up of the bundle header:
    /// `bundles.setStatus`; a failure shows `<item title> failed`.
    static func setBundleStatus(_ status: BundleStatus, of bundleID: String, workspace: DeviceWorkspace,
                                window: WindowState, itemTitle: String = "Set Status") async {
        do {
            _ = try await workspace.call(BundlesSetStatus.self, BundlesSetStatus.Params(bundleID: bundleID, status: status.rawValue))
        } catch {
            window.alert = .failure(itemTitle, error)
        }
    }

    /// Whether Implement All is enabled, and its tooltip while disabled.
    static func implementAllAvailability(of bundle: TicketBundle, workspace: DeviceWorkspace,
                                         projectID: String) -> (enabled: Bool, help: String?) {
        // A started or finished bundle waits for the user to set it back to To Do
        // (docs/tickets.md › Bundle status rules).
        if bundle.status != .todo {
            return (false, "Set the status to To Do to implement this bundle.")
        }
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

    /// Whether New Bundle is enabled, and its tooltip while it is disabled because no ticket can go
    /// into a new bundle: the project has no tickets, or all of them are done (docs/tickets.md ›
    /// Bundles section). While the window's device is not connected, it is disabled without tooltip.
    static func newBundleAvailability(workspace: DeviceWorkspace, projectID: String,
                                      connected: Bool) -> (enabled: Bool, help: String?) {
        pickerAvailability(of: .newBundle, emptyHelp: "Every ticket of this project is done.",
                           workspace: workspace, projectID: projectID, connected: connected)
    }

    /// Whether Add Tickets… of a bundle is enabled, and its tooltip while it is disabled because no
    /// ticket can be added: the project has no tickets, or all of them are done or already in the
    /// bundle (docs/tickets.md › Bundles section). While the window's device is not connected, it is
    /// disabled without tooltip.
    static func addTicketsAvailability(bundleID: String, workspace: DeviceWorkspace, projectID: String,
                                       connected: Bool) -> (enabled: Bool, help: String?) {
        pickerAvailability(of: .addTickets(bundleID: bundleID),
                           emptyHelp: "Every ticket of this project is done or already in this bundle.",
                           workspace: workspace, projectID: projectID, connected: connected)
    }

    /// A button that opens the ticket picker sheet is enabled when the sheet would list a ticket.
    private static func pickerAvailability(of use: TicketPickerUse, emptyHelp: String, workspace: DeviceWorkspace,
                                           projectID: String, connected: Bool) -> (enabled: Bool, help: String?) {
        guard connected else { return (false, nil) }
        let tickets = workspace.tickets[projectID] ?? [:]
        if tickets.isEmpty {
            return (false, "This project has no tickets.")
        }
        if use.candidates(tickets: tickets, bundles: workspace.bundles[projectID] ?? [:]).isEmpty {
            return (false, emptyHelp)
        }
        return (true, nil)
    }

    /// Implement All: opens the Implement sheet, whatever chats of the bundle are active.
    static func implementAll(bundleID: String, window: WindowState) {
        window.sheet = .implementBundle(bundleID: bundleID)
    }

    /// Implement All from the bundle list's context menu: selects the bundle and its Chats tab
    /// first.
    static func implementAllFromList(bundleID: String, window: WindowState, projectID: String) {
        window.updateViewState(of: projectID) {
            $0.selectedBundleID = bundleID
            $0.bundleTab = .chats
        }
        implementAll(bundleID: bundleID, window: window)
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

extension BundleStatus {
    /// The ticket status whose capsule colour and label a bundle status shares.
    var capsuleStatus: TicketStatus {
        switch self {
        case .todo: return .todo
        case .inProgress: return .inProgress
        case .done: return .done
        }
    }
}
