import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Close chat hook and docs/mcp.md › Pre-tool-use hook: only a `close_chat` call
/// that names no other chat than the calling chat is approved without the permission mode.
@Suite("Close chat hook")
struct CloseChatHookTests {
    static let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    static let allow = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#

    static func body(tool: String = "mcp__hephaestus__close_chat", input: String) -> Data {
        Data(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":\#(input),"tool_use_id":"t"}"#.utf8)
    }

    static func answer(_ body: Data) -> String {
        String(decoding: CloseChatHook.answer(chatID: chatID, body: body), as: UTF8.self)
    }

    @Test("A close_chat call without chatIDs, or naming only the calling chat, is allowed", arguments: [
        "{}",
        #"{"chatIDs":null}"#,
        #"{"chatIDs":[]}"#,
        #"{"chatIDs":["3F2504E0-4F89-11D3-9A0C-0305E82C3301"]}"#,
        #"{"chatIDs":["3f2504e0-4f89-11d3-9a0c-0305e82c3301","3F2504E0-4F89-11D3-9A0C-0305E82C3301"]}"#,
    ])
    func allowed(input: String) {
        #expect(Self.answer(Self.body(input: input)) == Self.allow)
    }

    @Test("A call naming another chat, another tool or a body that is not a hook input makes no decision", arguments: [
        CloseChatHookTests.body(input: #"{"chatIDs":["9B2D6C1E-0F4A-4E8B-A1C2-3D4E5F607182"]}"#),
        CloseChatHookTests.body(input: #"{"chatIDs":["3F2504E0-4F89-11D3-9A0C-0305E82C3301","9B2D6C1E-0F4A-4E8B-A1C2-3D4E5F607182"]}"#),
        CloseChatHookTests.body(input: #"{"chatIDs":["not-a-chat"]}"#),
        CloseChatHookTests.body(input: #"{"chatIDs":[1]}"#),
        CloseChatHookTests.body(input: #"{"chatIDs":"3F2504E0-4F89-11D3-9A0C-0305E82C3301"}"#),
        CloseChatHookTests.body(input: "[]"),
        CloseChatHookTests.body(tool: "mcp__hephaestus__delete_ticket", input: "{}"),
        Data(#"{"tool_name":"mcp__hephaestus__close_chat"}"#.utf8),
        Data("not json".utf8),
    ])
    func noDecision(body: Data) {
        #expect(Self.answer(body) == "{}")
    }

    @Test("The hook path takes the chat's hook token only and answers for that chat")
    func hookPath() async throws {
        try await withChatEngine { bed in
            let port = try #require(await bed.engine.mcpServer.port)
            let chat = try await bed.createChat(message: "Close this chat")
            let process = try #require(await bed.launcher.chatProcess())
            let hookToken = try #require(process.request.environment[LinkedItemsHook.tokenVariable])
            let config = try String(contentsOf: bed.dataDirectory.mcpConfigFile(chatID: chat.id), encoding: .utf8)
            let chatToken = String(config.split(separator: " ").last!.prefix(64))
            let external = await bed.engine.tokens.externalToken

            let own = Self.body(input: #"{"chatIDs":["\#(chat.id.uuidString)"]}"#)
            let reply = try await MCPHTTP.request(port: port, path: CloseChatHook.path, token: hookToken, body: own)
            #expect(reply.status == 200)
            #expect(reply.header("Content-Type") == "application/json")
            #expect(reply.text == Self.allow)
            let other = Self.body(input: #"{"chatIDs":["\#(UUID().uuidString)"]}"#)
            #expect(try await MCPHTTP.request(port: port, path: CloseChatHook.path, token: hookToken, body: other).text == "{}")

            #expect(try await MCPHTTP.request(port: port, path: CloseChatHook.path, token: nil, body: own).status == 401)
            #expect(try await MCPHTTP.request(port: port, path: CloseChatHook.path, token: chatToken, body: own).status == 401)
            #expect(try await MCPHTTP.request(port: port, path: CloseChatHook.path, token: external, body: own).status == 401)
            #expect(try await MCPHTTP.request(port: port, method: "GET", path: CloseChatHook.path, token: hookToken).status == 405)
        }
    }
}
