import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › tickets.addComment, docs/data-model.md › Comment: the model and effort of
/// the comments Claude adds from a chat.
@Suite("Comment models")
struct CommentModelTests {
    @Test("A chat's comment takes the model of its add_comment call, else of the latest message, and the chat's effort")
    func fromChat() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let ticket = try await CommentAnswerTests.ticket(bed)
            let chat = try await bed.createChat(settings: ChatSettings(model: "opus", effort: .xhigh), message: "Comment on it.")
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, "Comment on it."))
            process.emit(FakeClaudeLauncher.initLine(model: "claude-opus-5-5"))
            // A sub-agent on a model without effort setting calls add_comment.
            process.emit(#"{"type":"assistant","parent_tool_use_id":"toolu_agent","message":{"model":"claude-haiku-4-5-20251001","id":"msg_A","content":[{"type":"tool_use","id":"toolu_c","name":"mcp__hephaestus__add_comment","input":{"ticketID":"\#(ticket.id.lowercased())","text":"From the agent"}}]}}"#)
            // Then the main conversation's next message, the latest one.
            process.emit(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_M","model":"claude-opus-5-5"}},"parent_tool_use_id":null}"#)
            process.emit(#"{"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-opus-5-5","id":"msg_M","content":[{"type":"text","text":"Adding it."}]}}"#)
            _ = try #require(await bed.waitForItem(chat.id) { $0.id == "msg_M#0" })

            let actor = Actor.claude(chatID: chat.id.uuidString)
            let fromAgent = try await bed.engine.call(TicketsAddComment.self, .init(ticketID: ticket.id, text: "From the agent"), actor: actor)
            #expect(fromAgent.comments.last?.model == "claude-haiku-4-5-20251001")
            #expect(fromAgent.comments.last?.effort == nil)
            // No recorded call: the model of the latest message.
            let fromReply = try await bed.engine.call(TicketsAddComment.self, .init(ticketID: ticket.id, text: "From the reply"), actor: actor)
            let comment = try #require(fromReply.comments.last)
            #expect(comment.model == "claude-opus-5-5")
            #expect(comment.effort == .xhigh)

            // An edit keeps them, and the ticket file stores them.
            let edited = try await bed.connection.call(TicketsUpdateComment.self, .init(ticketID: ticket.id, commentID: comment.id,
                                                                                      text: "Edited"))
            #expect(edited.comments.last?.model == "claude-opus-5-5" && edited.comments.last?.effort == .xhigh)
            let file = try String(contentsOf: bed.folder.ticketFile(ticket.id), encoding: .utf8)
            #expect(file.contains("  model: claude-opus-5-5\n  effort: xhigh\n"))
        }
    }

    @Test("The user, the external token and the answer token add comments without model or effort")
    func otherActors() async throws {
        try await withChatEngine { bed in
            let ticket = try await CommentAnswerTests.ticket(bed)
            for actor in [Actor.claude(chatID: Actor.externalChatID), .claude(chatID: Actor.answerChatID)] {
                let added = try await bed.engine.call(TicketsAddComment.self, .init(ticketID: ticket.id, text: "No model"), actor: actor)
                #expect(added.comments.last?.author == .claude)
                #expect(added.comments.last?.model == nil && added.comments.last?.effort == nil)
            }
            let byUser = try await bed.connection.call(TicketsAddComment.self, .init(ticketID: ticket.id, text: "Mine"))
            #expect(byUser.comments.last?.author == .user)
            #expect(byUser.comments.last?.model == nil && byUser.comments.last?.effort == nil)
        }
    }
}
