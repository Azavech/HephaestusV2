import Foundation
import Testing
@testable import HephaestusCore

/// Ticket links through `LocalEngineConnection` (docs/tickets.md › Ticket links, › Link rules,
/// › Deleting; docs/engine-api.md › Tickets; docs/data-model.md › Ticket file, › Reactions).
@Suite("Ticket links")
struct TicketLinksTests {
    static func link(_ kind: TicketLinkKind, _ ticketID: TicketID) -> TicketLink {
        TicketLink(kind: kind, ticketID: ticketID)
    }

    /// The project HEPH with `count` tickets, HEPH-1 to HEPH-<count>.
    static func withTickets(_ count: Int, _ body: (DomainHarness) async throws -> Void) async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            for _ in 0..<count {
                try await h.ticket("HEPH")
            }
            try await body(h)
        }
    }

    static func update(_ h: DomainHarness, _ ticketID: TicketID, _ links: [TicketLink]) async throws -> Ticket {
        try await h.connection.call(TicketsUpdate.self, .init(ticketID: ticketID, links: links))
    }

    static func get(_ h: DomainHarness, _ ticketID: TicketID) async throws -> Ticket {
        try await h.connection.call(TicketsGet.self, .init(ticketID: ticketID))
    }

    static func ticketFile(_ h: DomainHarness, _ ticketID: TicketID) -> URL {
        h.projects.appendingPathComponent("Heph/.hephaestus/ticket/\(ticketID).yml")
    }

    @Test("tickets.update adds and removes Depends on and Related links; the other tickets get the inverse")
    func addAndRemove() async throws {
        try await Self.withTickets(3) { h in
            let events = await DomainEventRecorder.make(h)
            let updated = try await Self.update(h, "HEPH-1", [Self.link(.dependsOn, "heph-2"), Self.link(.related, "HEPH-3")])
            #expect(updated.links == [Self.link(.dependsOn, "HEPH-2"), Self.link(.related, "HEPH-3")])
            #expect(updated.inverseLinks.isEmpty)
            #expect(try await Self.get(h, "HEPH-2").inverseLinks == [TicketInverseLink(kind: .blocks, ticketID: "HEPH-1")])
            #expect(try await Self.get(h, "HEPH-3").inverseLinks == [TicketInverseLink(kind: .related, ticketID: "HEPH-1")])
            await events.wait(for: TicketUpdatedEvent.name, count: 3)
            let payloads = try events.all.map { try $0.payload(TicketUpdatedEvent.self) }
            #expect(payloads.map(\.id) == ["HEPH-1", "HEPH-2", "HEPH-3"])
            #expect(payloads[1].inverseLinks == [TicketInverseLink(kind: .blocks, ticketID: "HEPH-1")])
            #expect(payloads[2].inverseLinks == [TicketInverseLink(kind: .related, ticketID: "HEPH-1")])

            // Removing one link updates its ticket only; the same links again change nothing.
            events.clear()
            _ = try await Self.update(h, "HEPH-1", [Self.link(.related, "HEPH-3")])
            await events.wait(for: TicketUpdatedEvent.name, count: 2)
            #expect(try events.all.map { try $0.payload(TicketUpdatedEvent.self).id } == ["HEPH-1", "HEPH-2"])
            #expect(try await Self.get(h, "HEPH-2").inverseLinks.isEmpty)
            events.clear()
            _ = try await Self.update(h, "HEPH-1", [Self.link(.related, "HEPH-3")])
            #expect(await events.settle().isEmpty)

            // [] removes every link; a call without links leaves them.
            _ = try await Self.update(h, "HEPH-1", [Self.link(.related, "HEPH-3")])
            _ = try await h.connection.call(TicketsUpdate.self, .init(ticketID: "HEPH-1", title: "Renamed"))
            #expect(try await Self.get(h, "HEPH-1").links == [Self.link(.related, "HEPH-3")])
            _ = try await Self.update(h, "HEPH-1", [])
            #expect(try await Self.get(h, "HEPH-1").links.isEmpty)
            #expect(try await Self.get(h, "HEPH-3").inverseLinks.isEmpty)
        }
    }

    @Test("The link rules refuse another project, the ticket itself, a missing ticket, a second link and a cycle")
    func rules() async throws {
        try await Self.withTickets(4) { h in
            try await h.create("Web", name: "Web", identifier: "WEB")
            try await h.ticket("WEB")
            func refused(_ ticketID: TicketID, _ links: [TicketLink]) async -> EngineError? {
                await engineError { try await Self.update(h, ticketID, links) }
            }
            #expect(await refused("HEPH-1", [Self.link(.related, "HEPH2")]) == EngineError(.invalid, "\"HEPH2\" is not a valid ticket id."))
            #expect(await refused("HEPH-1", [Self.link(.dependsOn, "WEB-1")]) == EngineError(.invalid, "WEB-1 does not belong to project HEPH."))
            #expect(await refused("HEPH-1", [Self.link(.related, "heph-1")]) == EngineError(.invalid, "HEPH-1 cannot be linked to itself."))
            #expect(await refused("HEPH-1", [Self.link(.related, "HEPH-2"), Self.link(.dependsOn, "HEPH-2")])
                == EngineError(.invalid, "HEPH-2 is listed more than once."))
            #expect(await refused("HEPH-1", [Self.link(.dependsOn, "HEPH-99")]) == EngineError(.notFound, "Ticket HEPH-99 not found."))

            // One link per pair of tickets, in either direction.
            _ = try await Self.update(h, "HEPH-2", [Self.link(.related, "HEPH-1")])
            #expect(await refused("HEPH-1", [Self.link(.dependsOn, "HEPH-2")]) == EngineError(.invalid, "HEPH-1 is already linked to HEPH-2."))

            // HEPH-3 depends on HEPH-4, which depends on HEPH-1: HEPH-1 cannot depend on HEPH-3.
            _ = try await Self.update(h, "HEPH-3", [Self.link(.dependsOn, "HEPH-4")])
            _ = try await Self.update(h, "HEPH-4", [Self.link(.dependsOn, "HEPH-1")])
            #expect(await refused("HEPH-1", [Self.link(.dependsOn, "HEPH-3")])
                == EngineError(.invalid, "HEPH-1 cannot depend on HEPH-3, which depends on HEPH-1."))
            #expect(await refused("HEPH-1", [Self.link(.dependsOn, "HEPH-4")])
                == EngineError(.invalid, "HEPH-1 is already linked to HEPH-4."))
            // A Related link is no dependency.
            _ = try await Self.update(h, "HEPH-1", [Self.link(.related, "HEPH-3")])
            #expect(try await Self.get(h, "HEPH-1").links == [Self.link(.related, "HEPH-3")])

            // tickets.create checks its links before it uses a number.
            let failed = await engineError {
                try await h.connection.call(TicketsCreate.self, .init(projectID: "HEPH", title: "T", description: "x",
                                                                      links: [Self.link(.dependsOn, "HEPH-98")]))
            }
            #expect(failed == EngineError(.notFound, "Ticket HEPH-98 not found."))
            let project = try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project
            #expect(project.nextTicketNumber == 5)
        }
    }

    @Test("tickets.create stores its links and emits ticket.updated for each linked ticket")
    func create() async throws {
        try await Self.withTickets(2) { h in
            let events = await DomainEventRecorder.make(h)
            let ticket = try await h.connection.call(TicketsCreate.self, .init(
                projectID: "HEPH", title: "Third", description: "x", links: [Self.link(.dependsOn, "HEPH-2"), Self.link(.related, "HEPH-1")]))
            #expect(ticket.links == [Self.link(.dependsOn, "HEPH-2"), Self.link(.related, "HEPH-1")])
            await events.wait(for: TicketUpdatedEvent.name, count: 3)
            #expect(events.names == ["project.updated", "ticket.updated", "projects.changed", "ticket.updated", "ticket.updated"])
            let linked = try events.all.filter { $0.name == TicketUpdatedEvent.name }.dropFirst().map { try $0.payload(TicketUpdatedEvent.self) }
            #expect(linked.map(\.id) == ["HEPH-1", "HEPH-2"])
            #expect(linked[0].inverseLinks == [TicketInverseLink(kind: .related, ticketID: "HEPH-3")])
            #expect(linked[1].inverseLinks == [TicketInverseLink(kind: .blocks, ticketID: "HEPH-3")])
        }
    }

    @Test("A link is stored only in the declaring ticket's file; tickets.list returns the inverse links")
    func storage() async throws {
        try await Self.withTickets(3) { h in
            _ = try await Self.update(h, "HEPH-1", [Self.link(.dependsOn, "HEPH-2")])
            _ = try await Self.update(h, "HEPH-3", [Self.link(.related, "HEPH-2")])
            let declaring = try readFile(Self.ticketFile(h, "HEPH-1"))
            #expect(declaring.contains("links:\n- kind: dependsOn\n  ticket: HEPH-2\n"))
            let other = try readFile(Self.ticketFile(h, "HEPH-2"))
            #expect(other.contains("links: []\n"))
            #expect(!other.contains("inverseLinks") && !declaring.contains("inverseLinks"))
            #expect(try ProjectFileStore.readTicket(at: Self.ticketFile(h, "HEPH-2"), projectID: "HEPH").inverseLinks.isEmpty)
            let list = try await h.connection.call(TicketsList.self, .init(projectID: "HEPH"))
            #expect(list[1].inverseLinks == [TicketInverseLink(kind: .blocks, ticketID: "HEPH-1"),
                                             TicketInverseLink(kind: .related, ticketID: "HEPH-3")])
            #expect(list[0].links == [Self.link(.dependsOn, "HEPH-2")] && list[0].inverseLinks.isEmpty)
        }
    }

    @Test("Unknown ticket keys and unknown link keys are kept; a link whose ticket file is missing is kept")
    func unknownKeysAndMissingTickets() async throws {
        try await withDomainEngine(prepare: { directory, projects in
            let root = projects.appendingPathComponent("Heph")
            try writeFile(projectYAML(id: "HEPH", name: "Hephaestus V2", extra: "nextTicketNumber: 8\n"),
                          to: root.appendingPathComponent(".hephaestus/project.yml"))
            try writeFile(ticketYAML(id: "HEPH-1", title: "One", extra: "estimate: 3\nlinks:\n- kind: dependsOn\n  ticket: HEPH-7\n  note: kept\n"),
                          to: root.appendingPathComponent(".hephaestus/ticket/HEPH-1.yml"))
            try writeFile(ticketYAML(id: "HEPH-2", title: "Two"), to: root.appendingPathComponent(".hephaestus/ticket/HEPH-2.yml"))
            try writeFile(registryYAML([root.path]), to: directory.registryFile)
        }) { h in
            let updated = try await Self.update(h, "HEPH-1", [
                TicketLink(kind: .dependsOn, ticketID: "HEPH-7", unknownKeys: ["note": .string("kept")]), Self.link(.related, "HEPH-2"),
            ])
            #expect(updated.unknownKeys == ["estimate": .int(3)])
            let stored = try ProjectFileStore.readTicket(at: Self.ticketFile(h, "HEPH-1"), projectID: "HEPH")
            #expect(stored.unknownKeys == ["estimate": .int(3)])
            #expect(stored.links == [TicketLink(kind: .dependsOn, ticketID: "HEPH-7", unknownKeys: ["note": .string("kept")]),
                                     Self.link(.related, "HEPH-2")])
            // A new link to a missing ticket is refused.
            #expect(await engineError { try await Self.update(h, "HEPH-2", [Self.link(.dependsOn, "HEPH-6")]) }
                == EngineError(.notFound, "Ticket HEPH-6 not found."))
        }
    }

    @Test("Deleting a ticket removes every link to it and emits ticket.updated for each ticket changed")
    func delete() async throws {
        try await Self.withTickets(4) { h in
            _ = try await Self.update(h, "HEPH-1", [Self.link(.dependsOn, "HEPH-2")])
            _ = try await Self.update(h, "HEPH-3", [Self.link(.related, "HEPH-2"), Self.link(.related, "HEPH-4")])
            _ = try await Self.update(h, "HEPH-2", [Self.link(.dependsOn, "HEPH-4")])
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(TicketsDelete.self, .init(ticketID: "HEPH-2"))
            await events.wait(for: TicketUpdatedEvent.name, count: 3)
            #expect(events.names == ["ticket.updated", "ticket.updated", "ticket.deleted", "projects.changed", "ticket.updated"])
            let updated = try events.all.filter { $0.name == TicketUpdatedEvent.name }.map { try $0.payload(TicketUpdatedEvent.self) }
            #expect(updated.map(\.id) == ["HEPH-1", "HEPH-3", "HEPH-4"])
            #expect(updated[0].links.isEmpty)
            #expect(updated[1].links == [Self.link(.related, "HEPH-4")])
            #expect(updated[2].inverseLinks == [TicketInverseLink(kind: .related, ticketID: "HEPH-3")])
            #expect(try ProjectFileStore.readTicket(at: Self.ticketFile(h, "HEPH-1"), projectID: "HEPH").links.isEmpty)
            #expect(try ProjectFileStore.readTicket(at: Self.ticketFile(h, "HEPH-3"), projectID: "HEPH").links
                == [Self.link(.related, "HEPH-4")])
        }
    }

    @Test("A ticket file whose links changed outside the engine updates the inverse links of the other tickets")
    func externalChanges() async throws {
        try await Self.withTickets(3) { h in
            let events = await DomainEventRecorder.make(h)
            try writeFile(ticketYAML(id: "HEPH-1", title: "Edited", extra: "links:\n- kind: dependsOn\n  ticket: HEPH-3\n"),
                          to: Self.ticketFile(h, "HEPH-1"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/HEPH-1.yml"])
            await events.wait(for: TicketUpdatedEvent.name, count: 2)
            let updated = try events.all.filter { $0.name == TicketUpdatedEvent.name }.map { try $0.payload(TicketUpdatedEvent.self) }
            #expect(updated.map(\.id) == ["HEPH-1", "HEPH-3"])
            #expect(updated[1].inverseLinks == [TicketInverseLink(kind: .blocks, ticketID: "HEPH-1")])
            #expect(events.all.allSatisfy { $0.origin == .system })

            // A removed file updates the tickets it linked to; the links to it stay.
            _ = try await Self.update(h, "HEPH-2", [Self.link(.related, "HEPH-1")])
            _ = await events.settle()
            events.clear()
            try FileManager.default.removeItem(at: Self.ticketFile(h, "HEPH-1"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/HEPH-1.yml"])
            await events.wait(for: TicketUpdatedEvent.name)
            #expect(events.names == ["ticket.deleted", "projects.changed", "ticket.updated"])
            #expect(try events.all[2].payload(TicketUpdatedEvent.self).inverseLinks.isEmpty)
            #expect(try await Self.get(h, "HEPH-2").links == [Self.link(.related, "HEPH-1")])
        }
    }
}
