// OWNER: ui-chats — the items of a main window linked to its inspector chat (docs/chats.md › Linked
// items; docs/ui.md › Inspector); the resources a composer adds are in AddedResources.swift.
import Foundation
import HephaestusCore

/// An item open in the centre column of a main window.
struct LinkedItemRef: Hashable {
    enum Kind: String {
        case ticket, bundle, chat, code, doc, webTab, skill
    }

    var kind: Kind
    /// The ticket id, bundle id, chat id, project path, web tab id or skill name.
    var id: String

    /// The `<kind>:<id>` key of `ProjectViewState.unlinkedItems`.
    var key: String {
        "\(kind.rawValue):\(id)"
    }

    /// The `kind` Send passes for the item (docs/chats.md › Linked items).
    var linkedKind: ChatLinkedItemKind {
        switch kind {
        case .ticket: return .ticket
        case .bundle: return .bundle
        case .chat: return .chat
        case .code: return .codeFile
        case .doc: return .docsFile
        case .webTab: return .webTab
        case .skill: return .skill
        }
    }
}

extension ChatLinkedItemKind {
    /// The SF Symbol of the chips of a linked item of this kind: that of the item's sidebar
    /// section, and `folder` for a project, as in the results of the search panel.
    var symbol: String {
        switch self {
        case .ticket: return ProjectSection.tickets.symbol
        case .bundle: return ProjectSection.bundles.symbol
        case .chat: return ProjectSection.chats.symbol
        case .codeFile: return ProjectSection.code.symbol
        case .docsFile: return ProjectSection.docs.symbol
        case .webTab: return ProjectSection.web.symbol
        case .skill: return ProjectSection.skills.symbol
        case .project: return "folder"
        }
    }
}

/// A linked item as its chip shows it and Send names it.
struct LinkedItem: Hashable, Identifiable {
    var ref: LinkedItemRef
    /// The chip's short name.
    var name: String
    /// `<item>` of the line `Open in the app: <item>`, also the chip's tooltip.
    var text: String

    var id: String { ref.key }

    /// The item as Send passes it and the `user` item stores it.
    var chatLinkedItem: ChatLinkedItem {
        ChatLinkedItem(kind: ref.linkedKind, name: name, text: text)
    }

    /// The line Claude receives for the item through the linked items hook.
    var line: String {
        chatLinkedItem.line
    }
}

extension ProjectViewState {
    /// The items open in the centre column while `section` is shown (docs/ui.md › Inspector):
    /// every selected ticket in ticket number order, every selected chat (put in list order by
    /// `LinkedItems.linked`), or the section's selected item; none without section, while the
    /// Global Memories view or the Internal Skills view shows.
    func openItems(in section: ProjectSection?) -> [LinkedItemRef] {
        guard let section else { return [] }
        switch section {
        case .tickets:
            return selectedTicketIDs
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { LinkedItemRef(kind: .ticket, id: $0) }
        case .bundles:
            return selectedBundleID.map { [LinkedItemRef(kind: .bundle, id: $0)] } ?? []
        case .chats:
            return selectedChatIDs.sorted().map { LinkedItemRef(kind: .chat, id: $0) }
        case .code:
            return selectedEditorPath.map { [LinkedItemRef(kind: .code, id: $0)] } ?? []
        case .docs:
            return selectedDocPath.map { [LinkedItemRef(kind: .doc, id: $0)] } ?? []
        case .web:
            return selectedWebTabID.map { [LinkedItemRef(kind: .webTab, id: $0)] } ?? []
        case .skills:
            return selectedSkillName.map { [LinkedItemRef(kind: .skill, id: $0)] } ?? []
        case .dashboard, .builds, .memories, .costs, .apiExplorer, .graph, .settings:
            return []
        }
    }

    /// Drops from `unlinkedItems` the items that are no longer open, so that they are linked again
    /// the next time they are opened.
    mutating func forgetClosedUnlinkedItems(in section: ProjectSection?) {
        let open = Set(openItems(in: section).map(\.key))
        if !unlinkedItems.isSubset(of: open) {
            unlinkedItems.formIntersection(open)
        }
    }
}

enum LinkedItems {
    /// The linked items of a project's view state: its open items that the user did not unlink,
    /// resolved from the workspace's data; a ticket, bundle, chat or web tab it does not hold is
    /// left out. Chats come in the order of the Chats section's list.
    static func linked(state: ProjectViewState, section: ProjectSection?, tickets: [String: Ticket],
                       bundles: [String: TicketBundle], chats: [String: ChatMeta], webTabs: [WebTab]) -> [LinkedItem] {
        let items = state.openItems(in: section)
            .filter { !state.unlinkedItems.contains($0.key) }
            .compactMap { resolve($0, tickets: tickets, bundles: bundles, chats: chats, webTabs: webTabs) }
        guard section == .chats else { return items }
        let order = ChatsSectionView.inListOrder(items.compactMap { chats[$0.ref.id] }).map(\.id.uuidString)
        return items.sorted { (order.firstIndex(of: $0.ref.id) ?? 0) < (order.firstIndex(of: $1.ref.id) ?? 0) }
    }

    /// The chip and line of one open item (docs/chats.md › Linked items).
    static func resolve(_ ref: LinkedItemRef, tickets: [String: Ticket], bundles: [String: TicketBundle],
                        chats: [String: ChatMeta], webTabs: [WebTab]) -> LinkedItem? {
        switch ref.kind {
        case .ticket:
            guard let ticket = tickets[ref.id] else { return nil }
            return LinkedItem(ref: ref, name: ref.id, text: "ticket \(ref.id) “\(ticket.title)”")
        case .bundle:
            guard let bundle = bundles[ref.id] else { return nil }
            return LinkedItem(ref: ref, name: ref.id, text: "bundle \(ref.id) “\(bundle.title)”")
        case .chat:
            guard let chat = chats[ref.id] else { return nil }
            return LinkedItem(ref: ref, name: chat.title, text: "chat “\(chat.title)” (\(ref.id))")
        case .code:
            return LinkedItem(ref: ref, name: fileName(ref.id), text: "code file \(ref.id)")
        case .doc:
            return LinkedItem(ref: ref, name: fileName(ref.id), text: "docs file \(ref.id)")
        case .webTab:
            guard let tab = webTabs.first(where: { $0.id == UUID(uuidString: ref.id) }) else { return nil }
            if tab.title.isEmpty {
                return LinkedItem(ref: ref, name: tab.url, text: "web tab \(tab.url)")
            }
            return LinkedItem(ref: ref, name: tab.title, text: "web tab “\(tab.title)” \(tab.url)")
        case .skill:
            return LinkedItem(ref: ref, name: ref.id, text: "skill \(ref.id)")
        }
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
