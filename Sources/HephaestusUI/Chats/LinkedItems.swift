// OWNER: ui-chats — the items of a main window linked to its inspector chat (docs/chats.md › Linked
// items; docs/ui.md › Inspector).
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

    /// The sidebar section of the item, whose SF Symbol the chip shows.
    var section: ProjectSection {
        switch kind {
        case .ticket: return .tickets
        case .bundle: return .bundles
        case .chat: return .chats
        case .code: return .code
        case .doc: return .docs
        case .webTab: return .web
        case .skill: return .skills
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

    var line: String {
        "Open in the app: \(text)"
    }
}

extension ProjectViewState {
    /// The items open in the centre column while `section` is shown (docs/ui.md › Inspector):
    /// every selected ticket in ticket number order, or the section's selected item.
    func openItems(in section: ProjectSection) -> [LinkedItemRef] {
        switch section {
        case .tickets:
            return selectedTicketIDs
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { LinkedItemRef(kind: .ticket, id: $0) }
        case .bundles:
            return selectedBundleID.map { [LinkedItemRef(kind: .bundle, id: $0)] } ?? []
        case .chats:
            return selectedChatID.map { [LinkedItemRef(kind: .chat, id: $0)] } ?? []
        case .code:
            return selectedEditorPath.map { [LinkedItemRef(kind: .code, id: $0)] } ?? []
        case .docs:
            return selectedDocPath.map { [LinkedItemRef(kind: .doc, id: $0)] } ?? []
        case .web:
            return selectedWebTabID.map { [LinkedItemRef(kind: .webTab, id: $0)] } ?? []
        case .skills:
            return selectedSkillName.map { [LinkedItemRef(kind: .skill, id: $0)] } ?? []
        case .costs, .settings:
            return []
        }
    }

    /// Drops from `unlinkedItems` the items that are no longer open, so that they are linked again
    /// the next time they are opened.
    mutating func forgetClosedUnlinkedItems(in section: ProjectSection) {
        let open = Set(openItems(in: section).map(\.key))
        if !unlinkedItems.isSubset(of: open) {
            unlinkedItems.formIntersection(open)
        }
    }
}

enum LinkedItems {
    /// The linked items of a project's view state: its open items that the user did not unlink,
    /// resolved from the workspace's data; a ticket, bundle, chat or web tab it does not hold is
    /// left out.
    static func linked(state: ProjectViewState, section: ProjectSection, tickets: [String: Ticket],
                       bundles: [String: TicketBundle], chats: [String: ChatMeta], webTabs: [WebTab]) -> [LinkedItem] {
        state.openItems(in: section)
            .filter { !state.unlinkedItems.contains($0.key) }
            .compactMap { resolve($0, tickets: tickets, bundles: bundles, chats: chats, webTabs: webTabs) }
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

    /// The message text Send gives: one `Open in the app:` line per linked item, a blank line,
    /// then the typed text; the blank line is left out when the typed text is empty.
    static func messageText(_ text: String, linked: [LinkedItem]) -> String {
        guard !linked.isEmpty else { return text }
        let lines = linked.map(\.line).joined(separator: "\n")
        return text.isEmpty ? lines : lines + "\n\n" + text
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
