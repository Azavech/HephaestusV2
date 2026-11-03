// OWNER: ui-tickets — the entries of a ticket's history among its comments (docs/tickets.md ›
// Ticket history).
import HephaestusCore
import SwiftUI

/// The comments and the history entries of a ticket, oldest first: a comment by its `created`
/// date, an entry by its `date`. At equal dates the creation entry comes first, then the
/// comments, then the other entries.
enum TicketTimeline {
    enum Item: Identifiable, Hashable {
        case comment(Comment)
        /// `index` is the entry's position in the ticket's `history`.
        case entry(index: Int, TicketHistoryEntry)

        var id: String {
            switch self {
            case .comment(let comment): return "comment-\(comment.id.uuidString)"
            case .entry(let index, _): return "entry-\(index)"
            }
        }
    }

    static func items(of ticket: Ticket) -> [Item] {
        let entries = ticket.history.enumerated().map { index, entry in
            (date: entry.date, rank: entry.kind == .created ? 0 : 2, sequence: index, item: Item.entry(index: index, entry))
        }
        let comments = ticket.comments.enumerated().map { index, comment in
            (date: comment.created, rank: 1, sequence: index, item: Item.comment(comment))
        }
        return (entries + comments)
            .sorted { ($0.date, $0.rank, $0.sequence) < ($1.date, $1.rank, $1.sequence) }
            .map(\.item)
    }
}

/// The text of a history entry: `<change> · <author> · <date>`.
enum TicketHistoryText {
    /// `Created as To Do`, `In Progress → In Review` or `Renamed “<old>” → “<new>”`.
    static func change(_ entry: TicketHistoryEntry) -> String {
        switch entry.kind {
        case .created:
            return "Created as \(statusLabel(entry.to))"
        case .status:
            return "\(statusLabel(entry.from ?? "")) → \(statusLabel(entry.to))"
        case .title:
            return "Renamed “\(entry.from ?? "")” → “\(entry.to)”"
        }
    }

    /// The author: its text, and the chat its title opens for `Claude in <chat title>`.
    struct Author: Hashable {
        var prefix: String
        var chatTitle: String?
        var chatID: UUID?
    }

    /// `You on <device name>` (`You` without a device), `Claude in <chat title>` while the chat's
    /// metadata is on the device and `Claude` otherwise, `Claude (external)` and `Automatic`.
    static func author(_ entry: TicketHistoryEntry, chats: [String: ChatMeta]) -> Author {
        switch entry.author {
        case .user:
            return Author(prefix: entry.device.map { "You on \($0)" } ?? "You")
        case .automatic:
            return Author(prefix: "Automatic")
        case .claude:
            guard let chat = entry.chat else { return Author(prefix: "Claude") }
            if chat == Actor.externalChatID {
                return Author(prefix: "Claude (external)")
            }
            guard let chatID = UUID(uuidString: chat), let meta = chats[chatID.uuidString] else {
                return Author(prefix: "Claude")
            }
            return Author(prefix: "Claude in ", chatTitle: meta.title, chatID: chatID)
        }
    }

    /// The whole line, the chat title as a link to the chat.
    static func line(_ entry: TicketHistoryEntry, chats: [String: ChatMeta]) -> AttributedString {
        let author = author(entry, chats: chats)
        var text = AttributedString("\(change(entry)) · \(author.prefix)")
        if let title = author.chatTitle, let chatID = author.chatID {
            var link = AttributedString(title)
            link.link = MarkdownLinkURL.url(for: chatID.uuidString)
            text.append(link)
        }
        text.append(AttributedString(" · \(TicketFormat.created(entry.date))"))
        return text
    }

    /// The UI label of a status value; a value that is not a status is shown as written.
    private static func statusLabel(_ value: String) -> String {
        TicketStatus(rawValue: value)?.label ?? value
    }
}

/// One entry of the history: one line of secondary text in the font of the comment headers.
struct TicketHistoryLine: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let entry: TicketHistoryEntry

    var body: some View {
        Text(TicketHistoryText.line(entry, chats: workspace.chats))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .environment(\.openURL, OpenURLAction { url in
                if let destination = MarkdownLinkURL.destination(of: url), let chatID = UUID(uuidString: destination) {
                    Task { await window.navigate(to: .chat(chatID: chatID)) }
                }
                return .handled
            })
    }
}
