// OWNER: ui-chats — the list where each chat is listed, and the filter of the chat lists that hides
// closed chats (docs/chats.md › Where chats appear).
import HephaestusCore
import SwiftUI

/// The list where a chat is listed (docs/chats.md › Where chats appear).
enum ChatListPlace: Hashable {
    /// The Chats tab of the ticket.
    case ticket(TicketID)
    /// The Chats tab of the bundle.
    case bundle(BundleID)
    /// The Chats section of the chat's project.
    case chatsSection
}

extension DeviceWorkspace {
    /// Whether a chat is closed: its `closed` is true, or its linked ticket (`ticket` of a ticket
    /// chat, of a CI chat or of a linked feedback chat) has the status `done` (docs/chats.md ›
    /// Where chats appear).
    func isClosed(_ meta: ChatMeta) -> Bool {
        if meta.closed { return true }
        guard let ticketID = meta.ticketID, let projectID = Identifiers.projectID(of: ticketID) else { return false }
        return tickets[projectID]?[ticketID]?.status == .done
    }

    /// Where a chat is listed: a ticket chat in its ticket's Chats tab, a bundle chat in its
    /// bundle's, a CI chat in that of its ticket or bundle, while that ticket or bundle exists;
    /// project chats, Auto Setup chats, feedback chats and the chats whose ticket or bundle was deleted in the Chats
    /// section. A ticket or a bundle whose project's tickets or bundles are not loaded yet counts as
    /// existing (docs/chats.md › Where chats appear).
    func listedPlace(of meta: ChatMeta) -> ChatListPlace {
        switch meta.kind {
        case .project, .feedback, .setup:
            return .chatsSection
        case .ticket:
            return ticketPlace(meta.ticketID)
        case .bundle:
            return bundlePlace(meta.bundleID)
        case .ci:
            return meta.ticketID != nil ? ticketPlace(meta.ticketID) : bundlePlace(meta.bundleID)
        }
    }

    private func ticketPlace(_ ticketID: TicketID?) -> ChatListPlace {
        guard let ticketID, let projectID = Identifiers.projectID(of: ticketID) else { return .chatsSection }
        guard let projectTickets = tickets[projectID] else { return .ticket(ticketID) }
        return projectTickets[ticketID] != nil ? .ticket(ticketID) : .chatsSection
    }

    private func bundlePlace(_ bundleID: BundleID?) -> ChatListPlace {
        guard let bundleID, let projectID = Identifiers.projectID(of: bundleID) else { return .chatsSection }
        guard let projectBundles = bundles[projectID] else { return .bundle(bundleID) }
        return projectBundles[bundleID] != nil ? .bundle(bundleID) : .chatsSection
    }
}

/// The filter state shared by the Chats section and the Chats tabs of tickets and bundles of a
/// window and project (`ProjectViewState.hidesClosedChats`).
enum ChatListFilter {
    /// Whether the chat lists of `projectID` hide closed chats in `window`; true by default.
    @MainActor
    static func hidesClosedChats(in window: WindowState, projectID: String) -> Bool {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)]?.hidesClosedChats ?? true
    }

    /// The filter button's action: hides closed chats when they are shown, shows them otherwise,
    /// in every chat list of the window and project.
    @MainActor
    static func toggle(in window: WindowState, projectID: String) {
        let hides = hidesClosedChats(in: window, projectID: projectID)
        window.updateViewState(of: projectID) { $0.hidesClosedChats = !hides }
    }

    /// The button's symbol, filled while closed chats are hidden.
    static func symbol(hidesClosedChats: Bool) -> String {
        hidesClosedChats ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    /// The button's tooltip.
    static func tooltip(hidesClosedChats: Bool) -> String {
        hidesClosedChats ? "Show Closed Chats" : "Hide Closed Chats"
    }

    /// The text of a list whose chats the filter all hides.
    static let noOpenChats = "No open chats"
}

/// The filter button of a chat list's header.
struct ClosedChatsFilterButton: View {
    let window: WindowState
    let projectID: String

    var body: some View {
        let hides = ChatListFilter.hidesClosedChats(in: window, projectID: projectID)
        Button {
            ChatListFilter.toggle(in: window, projectID: projectID)
        } label: {
            Image(systemName: ChatListFilter.symbol(hidesClosedChats: hides))
        }
        .buttonStyle(.borderless)
        .help(ChatListFilter.tooltip(hidesClosedChats: hides))
    }
}
