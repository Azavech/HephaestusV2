import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Ticket history: the line of each entry and its place among the comments.
@MainActor
@Suite("Ticket history in the UI")
struct TicketHistoryUITests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Each kind of entry reads as its line, statuses with their labels")
    func changes() {
        #expect(TicketHistoryText.change(TicketHistoryEntry(kind: .created, date: created, to: "todo", author: .user)) == "Created as To Do")
        #expect(TicketHistoryText.change(TicketHistoryEntry(kind: .status, date: created, from: "in_progress", to: "review", author: .claude))
            == "In Progress → In Review")
        #expect(TicketHistoryText.change(TicketHistoryEntry(kind: .title, date: created, from: "Old", to: "New", author: .user))
            == "Renamed “Old” → “New”")
        #expect(TicketHistoryText.change(TicketHistoryEntry(kind: .linkAdded, date: created, to: "related HEPH-20", author: .claude))
            == "Added link Related HEPH-20")
        #expect(TicketHistoryText.change(TicketHistoryEntry(kind: .linkRemoved, date: created, to: "dependsOn HEPH-15", author: .user))
            == "Removed link Depends on HEPH-15")
        #expect(TicketHistoryText.change(TicketHistoryEntry(kind: .description, date: created, to: "", author: .user))
            == "Edited the description")
    }

    @Test("The author: You on the device, Claude in the chat while it is known, Claude (external), Automatic")
    func authors() {
        let chatID = UUID()
        let chats = [chatID.uuidString: ChatMeta(id: chatID, title: "Implement HEPH-12", kind: .ticket, created: created, projectID: "HEPH")]
        func author(_ author: TicketHistoryAuthor, device: String? = nil, chat: String? = nil) -> TicketHistoryText.Author {
            TicketHistoryText.author(TicketHistoryEntry(kind: .status, date: created, from: "todo", to: "review", author: author,
                                                        device: device, chat: chat), chats: chats)
        }
        #expect(author(.user, device: "Studio") == .init(prefix: "You on Studio"))
        #expect(author(.user) == .init(prefix: "You"))
        #expect(author(.claude, chat: chatID.uuidString) == .init(prefix: "Claude in ", chatTitle: "Implement HEPH-12", chatID: chatID))
        #expect(author(.claude, chat: UUID().uuidString) == .init(prefix: "Claude"))
        #expect(author(.claude) == .init(prefix: "Claude"))
        #expect(author(.claude, chat: "external") == .init(prefix: "Claude (external)"))
        #expect(author(.claude, chat: "answer") == .init(prefix: "Claude"))
        #expect(author(.automatic) == .init(prefix: "Automatic"))

        let line = TicketHistoryText.line(TicketHistoryEntry(kind: .status, date: created, from: "in_progress", to: "review",
                                                             author: .claude, chat: chatID.uuidString), chats: chats)
        #expect(String(line.characters) == "In Progress → In Review · Claude in Implement HEPH-12 · \(TicketFormat.created(created))")
        let links = line.runs.compactMap(\.link)
        #expect(links.count == 1 && MarkdownLinkURL.destination(of: links[0]) == chatID.uuidString)
    }

    @Test("Comments and entries are listed by date; at equal dates the creation entry, then the comments, then the other entries")
    func order() {
        let later = created.addingTimeInterval(60)
        let comment = Comment(id: UUID(), author: .claude, created: created, text: "Same second as the creation")
        let lateComment = Comment(id: UUID(), author: .claude, created: later, text: "Done")
        var ticket = Ticket(id: "HEPH-1", title: "T", created: created, comments: [lateComment, comment])
        ticket.history += [
            TicketHistoryEntry(kind: .status, date: later, from: "in_progress", to: "review", author: .claude, chat: "external"),
            TicketHistoryEntry(kind: .status, date: created.addingTimeInterval(30), from: "todo", to: "in_progress", author: .user),
        ]
        let ids = TicketTimeline.items(of: ticket).map(\.id)
        #expect(ids == ["entry-0", "comment-\(comment.id.uuidString)", "entry-2", "comment-\(lateComment.id.uuidString)", "entry-1"])
    }
}
