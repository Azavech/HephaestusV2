import Foundation
import Testing
@testable import HephaestusCore

/// The tickets of sub projects in their ancestors: `tickets.list` with `includeSubprojects` and the
/// `ticketCounts` and `ownTicketCounts` of ProjectSummary (docs/engine-api.md › tickets.list,
/// › ProjectSummary, › TicketCounts; docs/tickets.md › Tickets section).
@Suite("Sub project tickets")
struct SubprojectTicketsTests {
    /// PAR, with the sub projects SUB, whose sub project is DEEP, and OTH, created after SUB:
    /// `projects.list` order PAR, SUB, DEEP, OTH.
    static func makeTree(_ h: DomainHarness) async throws {
        try await h.create("Parent", name: "Parent", identifier: "PAR")
        try await h.create("Parent/sub", name: "Sub", identifier: "SUB", parentID: "PAR")
        try await h.create("Parent/sub/deep", name: "Deep", identifier: "DEEP", parentID: "SUB")
        try await h.create("Parent/other", name: "Other", identifier: "OTH", parentID: "PAR")
    }

    static func ids(_ h: DomainHarness, _ projectID: ProjectID, includeSubprojects: Bool?) async throws -> [String] {
        try await h.connection.call(TicketsList.self, .init(projectID: projectID, includeSubprojects: includeSubprojects)).map(\.id)
    }

    @Test("tickets.list: the project's own tickets without includeSubprojects; with it, each descendant's after, in projects.list order")
    func list() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            // Created out of tree order, so that the result's order is not the creation order.
            for projectID in ["OTH", "DEEP", "PAR", "SUB", "DEEP", "PAR"] {
                try await h.ticket(projectID)
            }
            #expect(try await Self.ids(h, "PAR", includeSubprojects: nil) == ["PAR-1", "PAR-2"])
            #expect(try await Self.ids(h, "PAR", includeSubprojects: false) == ["PAR-1", "PAR-2"])
            #expect(try await Self.ids(h, "par", includeSubprojects: true) == ["PAR-1", "PAR-2", "SUB-1", "DEEP-1", "DEEP-2", "OTH-1"])
            #expect(try await Self.ids(h, "SUB", includeSubprojects: true) == ["SUB-1", "DEEP-1", "DEEP-2"])
            #expect(try await Self.ids(h, "DEEP", includeSubprojects: true) == ["DEEP-1", "DEEP-2"])

            // The JSON form of the params leaves the key out when it is not given.
            let params = String(decoding: try EngineJSON.encode(TicketsList.Params(projectID: "PAR")), as: UTF8.self)
            #expect(params == #"{"projectID":"PAR"}"#)

            await #expect(throws: EngineError(.notFound, "Project NOPE not found.")) {
                try await Self.ids(h, "NOPE", includeSubprojects: true)
            }
        }
    }

    @Test("ticketCounts counts the project and its descendants, ownTicketCounts its own tickets; a descendant's change emits projects.changed")
    func counts() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            try await h.ticket("PAR")
            try await h.ticket("SUB")
            try await h.ticket("DEEP")
            try await h.ticket("DEEP")
            try await h.ticket("OTH")
            _ = try await h.connection.call(TicketsSetStatus.self, .init(ticketID: "DEEP-2", status: "review"))
            _ = try await h.connection.call(TicketsSetStatus.self, .init(ticketID: "OTH-1", status: "done"))

            let summaries = Dictionary(uniqueKeysWithValues: try await h.connection.call(ProjectsList.self).map { ($0.id, $0) })
            #expect(summaries["PAR"]?.ownTicketCounts == TicketCounts(todo: 1))
            #expect(summaries["PAR"]?.ticketCounts == TicketCounts(todo: 3, review: 1, done: 1))
            #expect(summaries["SUB"]?.ownTicketCounts == TicketCounts(todo: 1))
            #expect(summaries["SUB"]?.ticketCounts == TicketCounts(todo: 2, review: 1))
            #expect(summaries["DEEP"]?.ownTicketCounts == TicketCounts(todo: 1, review: 1))
            #expect(summaries["DEEP"]?.ticketCounts == TicketCounts(todo: 1, review: 1))
            #expect(summaries["OTH"]?.ownTicketCounts == TicketCounts(done: 1))
            #expect(summaries["OTH"]?.ticketCounts == TicketCounts(done: 1))

            // A ticket created in DEEP changes the counts of DEEP, SUB and PAR in one projects.changed.
            let events = await DomainEventRecorder.make(h)
            try await h.ticket("DEEP")
            _ = await events.wait(for: ProjectsChangedEvent.name)
            let changed = try #require(events.all.last { $0.name == ProjectsChangedEvent.name })
            let list = Dictionary(uniqueKeysWithValues: try changed.payload(ProjectsChangedEvent.self).map { ($0.id, $0) })
            #expect(list["PAR"]?.ticketCounts == TicketCounts(todo: 4, review: 1, done: 1))
            #expect(list["PAR"]?.ownTicketCounts == TicketCounts(todo: 1))
            #expect(list["SUB"]?.ticketCounts == TicketCounts(todo: 3, review: 1))
            #expect(list["DEEP"]?.ownTicketCounts == TicketCounts(todo: 2, review: 1))

            // Removing a sub project takes its tickets out of its ancestors' counts.
            _ = try await h.connection.call(ProjectsRemove.self, .init(projectID: "SUB"))
            let after = Dictionary(uniqueKeysWithValues: try await h.connection.call(ProjectsList.self).map { ($0.id, $0) })
            #expect(after["PAR"]?.ticketCounts == TicketCounts(todo: 1, done: 1))
            #expect(try await Self.ids(h, "PAR", includeSubprojects: true) == ["PAR-1", "OTH-1"])
        }
    }
}
