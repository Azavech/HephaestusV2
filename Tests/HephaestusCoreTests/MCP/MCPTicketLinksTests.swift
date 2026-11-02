import Foundation
import Testing
@testable import HephaestusCore

/// The `links` input of create_ticket and update_ticket, and the links that get_ticket and
/// list_tickets return (docs/mcp.md › create_ticket, › update_ticket, › get_ticket, › list_tickets).
@Suite("MCP ticket links")
struct MCPTicketLinksTests {
    static func call(_ handlers: MCPToolHandlers, _ tool: String, _ arguments: JSONValue) async throws -> Result<String, MCPToolError> {
        let definition = try #require(MCPToolCatalog.tool(named: tool, debugTools: false))
        return await handlers.call(definition, arguments: arguments, actor: MCPToolHandlersTests.chat)
    }

    static func ticket(_ result: Result<String, MCPToolError>) throws -> Ticket {
        try EngineJSON.decode(Ticket.self, from: Data(try result.get().utf8))
    }

    static func links(_ pairs: [(String, String)]) -> JSONValue {
        .array(pairs.map { .object(["kind": .string($0.0), "ticket": .string($0.1)]) })
    }

    @Test("create_ticket and update_ticket add and remove links; get_ticket and list_tickets return links and inverseLinks")
    func addRemoveAndRead() async throws {
        try await MCPToolHandlersTests.withEngine(namer: FixedTitleNamer(title: nil)) { handlers, h in
            try await h.ticket("HEPH")
            try await h.ticket("HEPH")
            let created = try Self.ticket(try await Self.call(handlers, "create_ticket", .object([
                "projectID": "HEPH", "description": .string(templateDescription),
                "links": Self.links([("dependsOn", "HEPH-1"), ("related", "heph-2")]),
            ])))
            #expect(created.id == "HEPH-3")
            #expect(created.links == [TicketLink(kind: .dependsOn, ticketID: "HEPH-1"), TicketLink(kind: .related, ticketID: "HEPH-2")])

            let first = try Self.ticket(try await Self.call(handlers, "get_ticket", ["ticketID": "HEPH-1"]))
            #expect(first.inverseLinks == [TicketInverseLink(kind: .blocks, ticketID: "HEPH-3")])
            let text = try await Self.call(handlers, "get_ticket", ["ticketID": "HEPH-3"]).get()
            #expect(text.contains(#""links":[{"kind":"dependsOn","ticket":"HEPH-1"},{"kind":"related","ticket":"HEPH-2"}]"#))
            #expect(text.contains(#""inverseLinks":[]"#))

            // update_ticket replaces the declared links: HEPH-1 loses its inverse link.
            let updated = try Self.ticket(try await Self.call(handlers, "update_ticket", [
                "ticketID": "HEPH-3", "links": Self.links([("related", "HEPH-2")]),
            ]))
            #expect(updated.links == [TicketLink(kind: .related, ticketID: "HEPH-2")])
            let list = try EngineJSON.decode([Ticket].self, from: Data(try await Self.call(handlers, "list_tickets", ["projectID": "HEPH"]).get().utf8))
            #expect(list.map(\.inverseLinks) == [[], [TicketInverseLink(kind: .related, ticketID: "HEPH-3")], []])
            let todo = try EngineJSON.decode([Ticket].self, from: Data(try await Self.call(handlers, "list_tickets", [
                "projectID": "HEPH", "status": "todo",
            ]).get().utf8))
            #expect(todo[1].inverseLinks == [TicketInverseLink(kind: .related, ticketID: "HEPH-3")])
            #expect(todo[2].links == [TicketLink(kind: .related, ticketID: "HEPH-2")])

            let cleared = try Self.ticket(try await Self.call(handlers, "update_ticket", ["ticketID": "HEPH-3", "links": .array([])]))
            #expect(cleared.links.isEmpty)
        }
    }

    @Test("A refused link is the engine's error; an unknown kind fails the input schema")
    func refused() async throws {
        try await MCPToolHandlersTests.withEngine(namer: FixedTitleNamer(title: nil)) { handlers, h in
            try await h.ticket("HEPH")
            let itself = try await Self.call(handlers, "update_ticket", ["ticketID": "HEPH-1", "links": Self.links([("related", "HEPH-1")])])
            #expect(itself == .failure(MCPToolError(code: .invalid, message: "HEPH-1 cannot be linked to itself.")))
            let kind = try await Self.call(handlers, "update_ticket", ["ticketID": "HEPH-1", "links": Self.links([("blocks", "HEPH-1")])])
            #expect(kind == .failure(MCPToolError(code: .invalid, message: "links[0].kind: must be one of dependsOn, related.")))
        }
    }
}
