import Foundation
import Testing
@testable import HephaestusCore

/// The history of a ticket (docs/tickets.md › Ticket history, docs/data-model.md › Ticket history
/// entry): the creation entry, an entry per status change and per rename with the actor of the
/// call, and none for a call that changes nothing.
@Suite("Ticket history")
struct TicketHistoryTests {
    private func file(_ h: DomainHarness, _ id: TicketID) -> URL {
        h.projects.appendingPathComponent("Heph/.hephaestus/ticket/\(id).yml")
    }

    @Test("tickets.create writes a creation entry whose author is the actor")
    func creation() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let deviceName = await h.engine.deviceInfo.name
            let byUser = try await h.ticket("HEPH")
            #expect(byUser.history == [TicketHistoryEntry(kind: .created, date: byUser.created, to: "todo", author: .user,
                                                          device: deviceName)])

            let chatID = UUID()
            await h.engine.testUpsertChat(ChatMeta(id: chatID, title: "Plan", kind: .project, created: ISODate.now(), projectID: "HEPH"))
            let byChat = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription),
                                          as: .claude(chatID: chatID.uuidString.lowercased()))
            #expect(byChat.history.count == 1)
            #expect(byChat.history[0].kind == .created && byChat.history[0].to == "todo")
            #expect(byChat.history[0].author == .claude && byChat.history[0].chat == chatID.uuidString && byChat.history[0].device == nil)

            let external = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: h.claude)
            #expect(external.history.map(\.chat) == ["external"])
            #expect(try ProjectFileStore.readTicket(at: file(h, external.id), projectID: "HEPH").history == external.history)
        }
    }

    @Test("Each status change adds one entry with the previous and the new status and the author")
    func statusChanges() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let deviceName = await h.engine.deviceInfo.name
            let ticket = try await h.ticket("HEPH")
            let chatID = UUID()
            let remoteDevice = UUID().uuidString

            _ = try await h.connection.call(TicketsSetStatus.self, .init(ticketID: ticket.id, status: "in_progress"))
            _ = try await h.call(TicketsSetStatus.self, .init(ticketID: ticket.id, status: "review"), as: .claude(chatID: chatID.uuidString))
            _ = try await h.call(TicketsSetStatus.self, .init(ticketID: ticket.id, status: "in_progress"), as: h.claude)
            let last = try await h.call(TicketsSetStatus.self, .init(ticketID: ticket.id, status: "done"), as: .user(deviceID: remoteDevice))

            let changes = Array(last.history.dropFirst())
            #expect(changes.map(\.kind) == [.status, .status, .status, .status])
            #expect(changes.map(\.from) == ["todo", "in_progress", "review", "in_progress"])
            #expect(changes.map(\.to) == ["in_progress", "review", "in_progress", "done"])
            #expect(changes.map(\.author) == [.user, .claude, .claude, .user])
            // A device that has not authenticated since launch is named by its id
            // (docs/remote.md › Request handling).
            #expect(changes.map(\.device) == [deviceName, nil, nil, remoteDevice])
            #expect(changes.map(\.chat) == [nil, chatID.uuidString, "external", nil])
            #expect(changes.last?.date == last.updated)
            #expect(try ProjectFileStore.readTicket(at: file(h, ticket.id), projectID: "HEPH").history == last.history)
        }
    }

    @Test("Setting the current status again adds no entry")
    func sameStatus() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let ticket = try await h.ticket("HEPH")
            let same = try await h.connection.call(TicketsSetStatus.self, .init(ticketID: ticket.id, status: "todo"))
            #expect(same.history.count == 1)
            _ = try await h.call(TicketsSetStatus.self, .init(ticketID: ticket.id, status: "review"), as: h.claude)
            let again = try await h.call(TicketsSetStatus.self, .init(ticketID: ticket.id, status: "review"), as: h.claude)
            #expect(again.history.count == 2)
        }
    }

    @Test("Each rename adds one entry with the previous and the new title and the author")
    func renames() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let deviceName = await h.engine.deviceInfo.name
            let ticket = try await h.ticket("HEPH", "First")
            let chatID = UUID()
            _ = try await h.connection.call(TicketsUpdate.self, .init(ticketID: ticket.id, title: " Second "))
            _ = try await h.call(TicketsUpdate.self, .init(ticketID: ticket.id, title: "Third"), as: .claude(chatID: chatID.uuidString))
            let last = try await h.call(TicketsUpdate.self, .init(ticketID: ticket.id, title: "Fourth", description: templateDescription),
                                        as: h.claude)
            let renames = Array(last.history.dropFirst())
            #expect(renames.map(\.kind) == [.title, .title, .title])
            #expect(renames.map(\.from) == ["First", "Second", "Third"])
            #expect(renames.map(\.to) == ["Second", "Third", "Fourth"])
            #expect(renames.map(\.author) == [.user, .claude, .claude])
            #expect(renames.map(\.device) == [deviceName, nil, nil])
            #expect(renames.map(\.chat) == [nil, chatID.uuidString, "external"])
        }
    }

    @Test("Saving the current title, or changing only the description or the links, adds no entry")
    func sameTitle() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let ticket = try await h.ticket("HEPH", "Same")
            try await h.ticket("HEPH")
            let same = try await h.connection.call(TicketsUpdate.self, .init(ticketID: ticket.id, title: "  Same "))
            #expect(same.history.count == 1)
            let described = try await h.connection.call(TicketsUpdate.self, .init(ticketID: ticket.id, title: "Same", description: "Other"))
            #expect(described.description == "Other" && described.history.count == 1)
            let linked = try await h.connection.call(TicketsUpdate.self, .init(
                ticketID: ticket.id, links: [TicketLink(kind: .related, ticketID: "HEPH-2")]))
            #expect(linked.history.count == 1)
        }
    }

    @Test("Haiku's naming adds a rename entry from the provisional title with the author automatic")
    func naming() async throws {
        try await withDomainEngine(titleNamer: FixedTitleNamer(title: "Keep locked web tabs open")) { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let ticket = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: h.claude)
            #expect(ticket.title == "Keep locked web tabs open")
            #expect(ticket.history.count == 2)
            let naming = ticket.history[1]
            #expect(naming.kind == .title && naming.author == .automatic)
            #expect(naming.from == "Locked tabs close with Command-W." && naming.to == "Keep locked web tabs open")
            #expect(naming.device == nil && naming.chat == nil)
            #expect(try ProjectFileStore.readTicket(at: file(h, ticket.id), projectID: "HEPH").history == ticket.history)
        }
    }

    @Test("A naming that fails, or that a title set meanwhile overtakes, adds no automatic entry")
    func namingWithoutEntry() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let failed = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: h.claude)
            #expect(failed.history.map(\.kind) == [.created])

            let overtaken = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: h.claude)
            let naming = await h.engine.startTicketNaming(overtaken.id, provisional: overtaken.title, description: overtaken.description,
                                                          namer: FixedTitleNamer(title: "Too late", delay: .milliseconds(200)))
            _ = try await h.connection.call(TicketsUpdate.self, .init(ticketID: overtaken.id, title: "Mine"))
            await naming.value
            let stored = try await h.connection.call(TicketsGet.self, .init(ticketID: overtaken.id))
            #expect(stored.history.map(\.author) == [.claude, .user])
            #expect(stored.history.last?.to == "Mine")
        }
    }

    @Test("A ticket file without a history reads with a creation entry; the next write stores it")
    func fileWithoutHistory() async throws {
        try await withDomainEngine(prepare: { directory, projects in
            let root = projects.appendingPathComponent("Heph")
            try writeFile(projectYAML(id: "HEPH", name: "Hephaestus V2"), to: root.appendingPathComponent(".hephaestus/project.yml"))
            try writeFile(ticketYAML(id: "HEPH-1", title: "Old", status: "review", extra: "createdBy: claude\n"),
                          to: root.appendingPathComponent(".hephaestus/ticket/HEPH-1.yml"))
            try writeFile(ticketYAML(id: "HEPH-2", title: "Older", extra: "history: []\n"),
                          to: root.appendingPathComponent(".hephaestus/ticket/HEPH-2.yml"))
            try writeFile(registryYAML([root.path]), to: directory.registryFile)
        }) { h in
            let created = try #require(ISODate.date(from: "2026-10-30T15:00:00Z"))
            let old = try await h.connection.call(TicketsGet.self, .init(ticketID: "HEPH-1"))
            #expect(old.history == [TicketHistoryEntry(kind: .created, date: created, to: "todo", author: .claude)])
            let older = try await h.connection.call(TicketsGet.self, .init(ticketID: "HEPH-2"))
            #expect(older.history == [TicketHistoryEntry(kind: .created, date: created, to: "todo", author: .user)])

            let changed = try await h.connection.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "done"))
            #expect(changed.history.count == 2 && changed.history[1].from == "review" && changed.history[1].to == "done")
            let text = try String(contentsOf: file(h, "HEPH-1"), encoding: .utf8)
            #expect(text.contains("\nhistory:\n- kind: created\n"))
            #expect(try ProjectFileStore.readTicket(at: file(h, "HEPH-1"), projectID: "HEPH").history == changed.history)
        }
    }

    @Test("History entries decode with the rules of their kind and keep unknown keys")
    func decoding() throws {
        let yaml = """
            schema: 1
            id: HEPH-3
            title: Renamed
            created: 2026-10-30T15:00:00Z
            history:
            - kind: created
              date: 2026-10-30T15:00:00Z
              to: todo
              author: user
              device: Studio
            - kind: title
              date: 2026-10-30T15:01:00Z
              from: First
              to: Renamed
              author: automatic
              note: kept
            """
        let ticket = try YAMLCoding.decode(Ticket.self, from: yaml)
        #expect(ticket.history.count == 2)
        #expect(ticket.history[0].device == "Studio" && ticket.history[0].from == nil)
        #expect(ticket.history[1].unknownKeys == ["note": .string("kept")])
        let encoded = try YAMLCoding.encode(ticket)
        #expect(try YAMLCoding.decode(Ticket.self, from: encoded) == ticket)
        #expect(encoded.contains("  note: kept\n"))

        let invalid = [
            "- kind: status\n  date: 2026-10-30T15:00:00Z\n  to: done\n  author: user\n",
            "- kind: status\n  date: 2026-10-30T15:00:00Z\n  from: todo\n  to: finished\n  author: user\n",
            "- kind: created\n  date: 2026-10-30T15:00:00Z\n  to: started\n  author: user\n",
            "- kind: title\n  date: 2026-10-30T15:00:00Z\n  to: New\n  author: claude\n",
            "- kind: title\n  date: 2026-10-30T15:00:00Z\n  from: Old\n  to: New\n  author: haiku\n",
        ]
        for entry in invalid {
            let text = "schema: 1\nid: HEPH-4\ntitle: X\ncreated: 2026-10-30T15:00:00Z\nhistory:\n" + entry
            #expect(throws: (any Error).self, "\(entry)") { try YAMLCoding.decode(Ticket.self, from: text) }
        }
    }
}
