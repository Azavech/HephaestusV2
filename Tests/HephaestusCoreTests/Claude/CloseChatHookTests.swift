import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Close chat hook, › API call hook and docs/mcp.md › Pre-tool-use hook: only a
/// `close_chat` call that names no other chats than the calling chat and the chats it orchestrates,
/// and an `api_call` whose method is `GET` or `HEAD`, are approved without the permission mode.
@Suite("Close chat hook")
struct CloseChatHookTests {
    static let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    /// A ticket chat and a CI chat that the chat `chatID` orchestrates, and a chat it does not.
    static let ticketChatID = UUID(uuidString: "9B2D6C1E-0F4A-4E8B-A1C2-3D4E5F607182")!
    static let ciChatID = UUID(uuidString: "1D2C3B4A-5968-4776-A5B4-C3D2E1F0A9B8")!
    static let otherChatID = UUID(uuidString: "B5A4C3D2-E1F0-4A9B-8C7D-6E5F4A3B2C1D")!
    static let allow = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#
    /// The `permission_mode` values of the CLI's hook input, one per permission mode.
    static let permissionModes = ["default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]

    static func body(tool: String = "mcp__hephaestus__close_chat", input: String, permissionMode: String = "default") -> Data {
        Data(#"{"session_id":"s","permission_mode":"\#(permissionMode)","hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":\#(input),"tool_use_id":"t"}"#.utf8)
    }

    static func answer(_ body: Data, orchestrated: Set<ChatID> = []) -> String {
        String(decoding: CloseChatHook.answer(chatID: chatID, orchestrated: orchestrated, body: body), as: UTF8.self)
    }

    /// The `tool_input` of a `close_chat` call naming `chatIDs`.
    static func input(_ chatIDs: [ChatID]) -> String {
        #"{"chatIDs":[\#(chatIDs.map { #""\#($0.uuidString)""# }.joined(separator: ","))]}"#
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

    @Test("A call naming only chats the calling chat orchestrates, with or without its own id, is allowed in every permission mode",
          arguments: CloseChatHookTests.permissionModes)
    func orchestratedChatsAllowed(permissionMode: String) {
        let orchestrated: Set<ChatID> = [Self.ticketChatID, Self.ciChatID]
        for input in [
            Self.input([Self.ticketChatID]),
            Self.input([Self.ticketChatID, Self.ciChatID]),
            Self.input([Self.ciChatID, Self.chatID, Self.ticketChatID]),
            #"{"chatIDs":["9b2d6c1e-0f4a-4e8b-a1c2-3d4e5f607182","1D2C3B4A-5968-4776-A5B4-C3D2E1F0A9B8"]}"#,
        ] {
            #expect(Self.answer(Self.body(input: input, permissionMode: permissionMode), orchestrated: orchestrated) == Self.allow, "\(input)")
        }
    }

    @Test("A call that also names a chat the calling chat does not orchestrate makes no decision, in every permission mode",
          arguments: CloseChatHookTests.permissionModes)
    func otherChatsNoDecision(permissionMode: String) {
        let orchestrated: Set<ChatID> = [Self.ticketChatID, Self.ciChatID]
        for input in [
            Self.input([Self.otherChatID]),
            Self.input([Self.ticketChatID, Self.ciChatID, Self.otherChatID]),
            Self.input([Self.chatID, Self.otherChatID]),
            #"{"chatIDs":["9B2D6C1E-0F4A-4E8B-A1C2-3D4E5F607182","not-a-chat"]}"#,
            #"{"chatIDs":["9B2D6C1E-0F4A-4E8B-A1C2-3D4E5F607182",1]}"#,
        ] {
            #expect(Self.answer(Self.body(input: input, permissionMode: permissionMode), orchestrated: orchestrated) == "{}", "\(input)")
        }
        // Without orchestrated chats, a call naming another chat makes no decision either.
        #expect(Self.answer(Self.body(input: Self.input([Self.ticketChatID]), permissionMode: permissionMode)) == "{}")
    }

    @Test("The engine's answer follows the orchestrator of the named chats: a bundle chat's ticket chats and CI chat, an implement chat's CI chat, and no other chat; also through the hook path")
    func orchestratedChatsOfTheEngine() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            _ = try await ChatWorktreeTests.gitRepository(bed)
            try await CIChatTests.githubPage(bed)
            // The bundle chat of DEMO-B1, its ticket chats of DEMO-1 and DEMO-2 and its CI chat.
            let bundleChat = try await ChatWorktreeTests.orchestrator(bed)
            let claude = Actor.claude(chatID: bundleChat.id.uuidString)
            let first = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: claude)
            let second = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-2"), actor: claude)
            let bundleCI = try await bed.engine.call(ChatsWatchCI.self, .init(commit: CIChatTests.commit), actor: claude)
            // The implement chat of a single ticket with its CI chat, and a project chat.
            try await bed.writeTicket(Ticket(id: "DEMO-3", title: "Three", created: ISODate.now(), description: "Problem"))
            let single = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-3"))
            let singleCI = try await bed.engine.call(ChatsWatchCI.self, .init(commit: CIChatTests.commit),
                                                     actor: .claude(chatID: single.id.uuidString))
            let project = try await bed.createChat()

            func answer(_ caller: ChatMeta, _ named: [ChatMeta]) async -> String {
                String(decoding: await bed.engine.closeChatHookAnswer(chatID: caller.id, body: Self.body(input: Self.input(named.map(\.id)))),
                       as: UTF8.self)
            }
            #expect(await answer(bundleChat, [first, second, bundleCI]) == Self.allow)
            #expect(await answer(bundleChat, [first, second, bundleCI, bundleChat]) == Self.allow)
            #expect(await answer(single, [singleCI]) == Self.allow)
            #expect(await answer(single, [singleCI, single]) == Self.allow)
            for other in [single, singleCI, project] {
                #expect(await answer(bundleChat, [first, second, bundleCI, other]) == "{}")
            }
            #expect(await answer(single, [singleCI, first]) == "{}")
            #expect(await answer(single, [bundleCI]) == "{}")
            // A chat that orchestrates no chat closes only itself without the permission mode.
            #expect(await answer(first, [first]) == Self.allow)
            #expect(await answer(first, [second]) == "{}")
            #expect(await answer(project, [single]) == "{}")

            // Through the MCP server, with the bundle chat's hook token.
            let port = try #require(await bed.engine.mcpServer.port)
            let process = try #require(await ChatWorktreeTests.process(bed, bundleChat.id))
            let hookToken = try #require(process.request.environment[LinkedItemsHook.tokenVariable])
            for mode in Self.permissionModes {
                let own = Self.body(input: Self.input([first.id, second.id, bundleCI.id, bundleChat.id]), permissionMode: mode)
                let reply = try await MCPHTTP.request(port: port, path: CloseChatHook.path, token: hookToken, body: own)
                #expect(reply.status == 200 && reply.text == Self.allow)
                let other = Self.body(input: Self.input([first.id, second.id, bundleCI.id, project.id]), permissionMode: mode)
                let otherReply = try await MCPHTTP.request(port: port, path: CloseChatHook.path, token: hookToken, body: other)
                #expect(otherReply.status == 200 && otherReply.text == "{}")
            }
        }
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

    // MARK: API call hook (docs/chats.md › API call hook)

    @Test("An api_call whose operation's method is GET or HEAD is allowed in every permission mode", arguments: CloseChatHookTests.permissionModes)
    func apiCallReadAllowed(permissionMode: String) {
        for input in [
            #"{"environment":"production","operation":"GET /device"}"#,
            #"{"environment":"staging","operation":"HEAD /pets/{petId}","parameters":{"path:petId":"42"}}"#,
            #"{"operation":"GET /"}"#,
        ] {
            #expect(Self.answer(Self.body(tool: "mcp__hephaestus__api_call", input: input, permissionMode: permissionMode)) == Self.allow,
                    "\(input)")
        }
    }

    @Test("An api_call of another method, or without a string operation, makes no decision", arguments: [
        #"{"environment":"production","operation":"POST /device/{device_id}"}"#,
        #"{"environment":"production","operation":"PUT /device"}"#,
        #"{"environment":"production","operation":"PATCH /device"}"#,
        #"{"environment":"production","operation":"DELETE /device/{device_id}"}"#,
        #"{"environment":"production","operation":"OPTIONS /device"}"#,
        #"{"environment":"production","operation":"get /device"}"#,
        #"{"environment":"production","operation":"GET"}"#,
        #"{"environment":"production","operation":"GETTER /device"}"#,
        #"{"environment":"production","operation":" GET /device"}"#,
        #"{"environment":"production","operation":["GET /device"]}"#,
        #"{"environment":"production"}"#,
        "[]",
    ])
    func apiCallOtherNoDecision(input: String) {
        #expect(Self.answer(Self.body(tool: "mcp__hephaestus__api_call", input: input)) == "{}")
        #expect(Self.answer(Self.body(tool: "mcp__hephaestus__api_call", input: input, permissionMode: "dontAsk")) == "{}")
    }

    @Test("A GET operation of another tool, close_chat included, gets no api_call decision")
    func apiCallOtherTools() {
        #expect(Self.answer(Self.body(tool: "mcp__hephaestus__api_operations", input: #"{"operation":"GET /device"}"#)) == "{}")
        #expect(Self.answer(Self.body(tool: "mcp__hephaestus__k8s_restart", input: #"{"operation":"GET /device"}"#)) == "{}")
        #expect(Self.answer(Self.body(input: #"{"chatIDs":["B5A4C3D2-E1F0-4A9B-8C7D-6E5F4A3B2C1D"],"operation":"GET /device"}"#)) == "{}")
        #expect(CloseChatHook.matcher == "mcp__hephaestus__close_chat|mcp__hephaestus__api_call")
    }
}
