import Foundation
import Testing
@testable import HephaestusCore

/// docs/mcp.md › Authentication and › Actor rules: the answer token of a comment answer maps to
/// chatID `answer`, reaches only the tools of a comment answer and changes only its ticket.
@Suite("MCP answer tokens")
struct MCPAnswerTokenTests {
    static let answer = Actor.claude(chatID: Actor.answerChatID)

    @Test("An answer token maps to chatID answer and its ticket until it is revoked")
    func tokens() async throws {
        try await withTestEngine { engine, _, _ in
            let tokens = engine.tokens
            let answerID = UUID()
            let token = await tokens.issueAnswerToken(answerID: answerID, ticketID: "HEPH-12")
            #expect(Identifiers.isExternalToken(token))
            #expect(await tokens.actor(forToken: token) == Self.answer)
            #expect(await tokens.answerTicketID(forToken: token) == "HEPH-12")
            #expect(await tokens.chatID(forHookToken: token) == nil)
            await tokens.revokeAnswerToken(answerID: answerID)
            #expect(await tokens.actor(forToken: token) == nil)
            #expect(await tokens.answerTicketID(forToken: token) == nil)
        }
    }

    @Test("A comment answer uses only the read tools, update_ticket and set_ticket_status, on its ticket only")
    func tools() async throws {
        let engine = RecordedEngine()
        engine.answer("tickets.update", .success("{}"))
        engine.answer("tickets.get", .success(#"{"id":"HEPH-12"}"#))
        let handlers = MCPToolHandlers(engineCall: engine.engineCall, homeDirectory: "/Users/example")
        func call(_ tool: String, _ arguments: String) async throws -> Result<String, MCPToolError> {
            let definition = try #require(MCPToolCatalog.tool(named: tool, debugTools: false))
            return await handlers.call(definition, arguments: try jsonValue(arguments), actor: Self.answer, answerTicketID: "HEPH-12")
        }
        for tool in ["create_ticket", "add_comment", "delete_ticket", "implement_ticket", "ask_questions", "close_chat", "open_in_app"] {
            let result = try await call(tool, "{}")
            #expect(result == .failure(MCPToolError(.forbidden, "\(tool) is not available to a comment answer.")), "\(tool)")
        }
        #expect(try await call("update_ticket", #"{"ticketID":"HEPH-13","title":"X"}"#)
            == .failure(MCPToolError(.forbidden, "A comment answer changes only HEPH-12.")))
        #expect(try await call("set_ticket_status", #"{"ticketID":"HEPH-13","status":"review"}"#)
            == .failure(MCPToolError(.forbidden, "A comment answer changes only HEPH-12.")))
        #expect(engine.calls.isEmpty)
        #expect(try await call("update_ticket", #"{"ticketID":"heph-12","title":"X"}"#) == .success("{}"))
        #expect(engine.calls.last?.actor == Self.answer)
        _ = try await call("list_tickets", #"{"projectID":"HEPH"}"#)
        #expect(engine.calls.last?.method == "tickets.list")
    }
}
