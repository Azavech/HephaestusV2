import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Linked items hook, docs/mcp.md › User prompt hook: the linked items of a
/// message stay out of its text, are stored in its `user` item, and reach Claude through the
/// `UserPromptSubmit` hook answered on the MCP server.
@Suite("Linked items hook")
struct LinkedItemsHookTests {
    static let ticket = ChatLinkedItem(kind: .ticket, name: "DEMO-12", text: "ticket DEMO-12 “Fix the login form”")
    static let doc = ChatLinkedItem(kind: .docsFile, name: "chats.md", text: "docs file docs/chats.md")

    // MARK: Records

    @Test("A request takes the first record with its prompt, trimmed, and drops the records before it")
    func records() {
        var records = LinkedItemsHookRecords()
        records.written(prompt: "/cost", lines: ["A"])
        records.written(prompt: "  Hello\n\n", lines: ["B"])
        records.written(prompt: "Hello", lines: [])
        records.written(prompt: "", lines: ["C"])
        // No record matches: nothing changes.
        #expect(records.take(prompt: "Other") == nil)
        #expect(records.records.count == 4)
        // The first `Hello` is taken; the `/cost` record, which the CLI ran without the hook, goes too.
        #expect(records.take(prompt: "Hello") == ["B"])
        #expect(records.records.map(\.prompt) == ["Hello", ""])
        #expect(records.take(prompt: "Hello") == [])
        #expect(records.take(prompt: "") == ["C"])
        #expect(records.records.isEmpty)
    }

    @Test("The answer holds the lines joined with LF, or is {} without lines")
    func answer() throws {
        let lines = [Self.ticket.line, Self.doc.line]
        let value = try JSONDecoder().decode(JSONValue.self, from: LinkedItemsHook.answer(lines: lines))
        #expect(value == .object(["hookSpecificOutput": .object([
            "hookEventName": "UserPromptSubmit",
            "additionalContext": .string("Open in the app: ticket DEMO-12 “Fix the login form”\nOpen in the app: docs file docs/chats.md"),
        ])]))
        #expect(String(decoding: LinkedItemsHook.answer(lines: []), as: UTF8.self) == "{}")
        #expect(LinkedItemsHook.prompt(ofBody: Data(#"{"prompt":"Hi","hook_event_name":"UserPromptSubmit"}"#.utf8)) == "Hi")
        #expect(LinkedItemsHook.prompt(ofBody: Data(#"{"prompt":1}"#.utf8)) == nil)
        #expect(LinkedItemsHook.prompt(ofBody: Data("not json".utf8)) == nil)
    }

    // MARK: Engine and MCP server

    static func hookBody(_ prompt: String) -> Data {
        Data(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":\#(ControlLines.string(prompt))}"#.utf8)
    }

    static func hook(port: Int, token: String?, _ prompt: String) async throws -> HTTPReply {
        try await MCPHTTP.request(port: port, path: LinkedItemsHook.path, token: token, body: hookBody(prompt))
    }

    @Test("Send keeps the items out of the text, stores them, and the hook gives them once to Claude")
    func sendAndHook() async throws {
        try await withChatEngine { bed in
            let port = try #require(await bed.engine.mcpServer.port)
            let chat = try await bed.connection.call(ChatsCreate.self, .init(
                projectID: "DEMO", kind: .project,
                message: ChatMessageInput(text: "Which item do I have open?", linkedItems: [Self.ticket, Self.doc])))
            let process = try #require(await bed.launcher.chatProcess())

            // The command line holds the hook; the token is only in the environment.
            let token = try #require(process.request.environment[LinkedItemsHook.tokenVariable])
            #expect(token.count == 64 && token.allSatisfy(\.isHexDigit))
            let settings = try #require(process.arguments.firstIndex(of: "--settings")).advanced(by: 1)
            #expect(process.arguments[settings] == ClaudeCommandLine.chatSettings(ultracode: false, mcpPort: port))
            #expect(!process.arguments.contains { $0.contains(token) })

            // The text written to Claude and the stored text are the typed text only.
            let line = try #require(await process.line { $0.hasPrefix(#"{"type":"user""#) })
            #expect(FakeClaudeLauncher.text(of: line) == "Which item do I have open?")
            let user = try #require(try await bed.transcript(chat.id).compactMap { item -> UserItem? in
                if case .user(let user) = item { return user }
                return nil
            }.first)
            #expect(user.text == "Which item do I have open?")
            #expect(user.linkedItems == [Self.ticket, Self.doc])

            // The hook answer, then nothing for the same prompt: the record was taken.
            let reply = try await Self.hook(port: port, token: token, "Which item do I have open?")
            #expect(reply.status == 200)
            #expect(reply.header("Content-Type") == "application/json")
            #expect(try reply.json().objectValue?["hookSpecificOutput"]?.objectValue?["additionalContext"]
                == .string("Open in the app: ticket DEMO-12 “Fix the login form”\nOpen in the app: docs file docs/chats.md"))
            #expect(try await Self.hook(port: port, token: token, "Which item do I have open?").text == "{}")

            // A message without linked items adds no context; a slash command's record is dropped.
            try await bed.send(chat.id, "/cost")
            try await bed.send(chat.id, "And now?")
            #expect(await process.line { FakeClaudeLauncher.text(of: $0) == "And now?" } != nil)
            #expect(try await Self.hook(port: port, token: token, "And now?").text == "{}")
            #expect(try await Self.hook(port: port, token: token, "/cost").text == "{}")
        }
    }

    @Test("The hook path takes the hook token only, and the hook token works on no other path")
    func hookAuthentication() async throws {
        try await withChatEngine { bed in
            let port = try #require(await bed.engine.mcpServer.port)
            let chat = try await bed.connection.call(ChatsCreate.self, .init(
                projectID: "DEMO", kind: .project, message: ChatMessageInput(text: "Hi", linkedItems: [Self.ticket])))
            let process = try #require(await bed.launcher.chatProcess())
            let token = try #require(process.request.environment[LinkedItemsHook.tokenVariable])
            let external = await bed.engine.tokens.externalToken
            #expect(try await Self.hook(port: port, token: nil, "Hi").status == 401)
            #expect(try await Self.hook(port: port, token: external, "Hi").status == 401)
            #expect(try await MCPHTTP.post(port: port, token: token, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).status == 401)
            #expect(try await MCPHTTP.request(port: port, path: "/hooks/other", token: token, body: Self.hookBody("Hi")).status == 404)
            #expect(try await MCPHTTP.request(port: port, path: "/hooks/user-prompt-submit", token: "Hi").status == 401)

            // The token is revoked when the process exits.
            process.exit(.exited(0))
            #expect(await bed.waitForState(chat.id, .idle))
            let deadline = ContinuousClock.now + waitLimit
            var status = 0
            while ContinuousClock.now < deadline {
                status = try await Self.hook(port: port, token: token, "Hi").status
                if status == 401 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(status == 401)
        }
    }
}
