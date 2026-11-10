import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Linked items hook, docs/mcp.md › User prompt hook: the linked items of a
/// message, open items and added resources, stay out of its text, are stored in its `user` item,
/// and reach Claude through the `UserPromptSubmit` hook answered on the MCP server.
@Suite("Linked items hook")
struct LinkedItemsHookTests {
    static let ticket = ChatLinkedItem(kind: .ticket, name: "DEMO-12", text: "ticket DEMO-12 “Fix the login form”")
    static let doc = ChatLinkedItem(kind: .docsFile, name: "chats.md", text: "docs file docs/chats.md")
    /// Resources added from a composer's paperclip menu (docs/chats.md › Added resources).
    static let addedCode = ChatLinkedItem(kind: .codeFile, name: "main.swift:12",
                                          text: "code file Sources/App/main.swift:12 in project API", added: true)
    static let addedProject = ChatLinkedItem(kind: .project, name: "API", text: "project API “Backend”", added: true)

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

    // MARK: Added resources

    @Test("An open item gives the line Open in the app, an added resource the line Linked by the user")
    func lines() {
        #expect(Self.ticket.line == "Open in the app: ticket DEMO-12 “Fix the login form”")
        #expect(Self.addedCode.line == "Linked by the user: code file Sources/App/main.swift:12 in project API")
        #expect(Self.addedProject.line == "Linked by the user: project API “Backend”")
    }

    @Test("A user item written before the added key reads its linked items as open items, and the key is always written")
    func itemWithoutAdded() throws {
        let line = #"{"type":"user","id":"u","created":"2026-10-31T13:00:00Z","text":"Hi","attachments":[],"sender":"MacBook","#
            + #""linkedItems":[{"kind":"ticket","name":"DEMO-12","text":"ticket DEMO-12 “Fix the login form”"}]}"#
        guard case .user(var user) = try StorageJSON.decoder().decode(ChatItem.self, from: Data(line.utf8)) else {
            Issue.record("not a user item")
            return
        }
        #expect(user.linkedItems == [Self.ticket])
        #expect(user.linkedItems.first?.added == false)

        // Written back with every key.
        user.linkedItems.append(Self.addedProject)
        let data = try StorageJSON.lineEncoder().encode(ChatItem.user(user))
        let written = try JSONDecoder().decode(JSONValue.self, from: data).objectValue?["linkedItems"]
        #expect(written == [
            ["kind": "ticket", "name": "DEMO-12", "text": "ticket DEMO-12 “Fix the login form”", "added": false],
            ["kind": "project", "name": "API", "text": "project API “Backend”", "added": true],
        ])
        guard case .user(let again) = try StorageJSON.decoder().decode(ChatItem.self, from: data) else {
            Issue.record("not a user item")
            return
        }
        #expect(again.linkedItems == [Self.ticket, Self.addedProject])

        // The API takes a linked item without the key too.
        let json = #"{"text":"Hi","linkedItems":[{"kind":"skill","name":"notes","text":"skill notes"},"#
            + #"{"added":true,"kind":"project","name":"API","text":"project API “Backend”"}]}"#
        let input = try EngineJSON.decode(ChatMessageInput.self, from: Data(json.utf8))
        #expect(input.linkedItems == [ChatLinkedItem(kind: .skill, name: "notes", text: "skill notes"), Self.addedProject])
    }

    @Test("Send stores the open items and the added resources, and the hook gives Open in the app, then Linked by the user")
    func addedResources() async throws {
        try await withChatEngine { bed in
            let port = try #require(await bed.engine.mcpServer.port)
            let chat = try await bed.connection.call(ChatsCreate.self, .init(
                projectID: "DEMO", kind: .project,
                message: ChatMessageInput(text: "What did I link?", linkedItems: [Self.ticket, Self.addedCode, Self.addedProject])))
            let process = try #require(await bed.launcher.chatProcess())
            let token = try #require(process.request.environment[LinkedItemsHook.tokenVariable])

            // The typed text only is written to Claude; the `user` item keeps which items were added.
            let line = try #require(await process.line { $0.hasPrefix(#"{"type":"user""#) })
            #expect(FakeClaudeLauncher.text(of: line) == "What did I link?")
            let users = try await bed.transcript(chat.id).compactMap { item -> UserItem? in
                if case .user(let user) = item { return user }
                return nil
            }
            #expect(users.first?.linkedItems == [Self.ticket, Self.addedCode, Self.addedProject])
            #expect(users.first?.linkedItems.map(\.added) == [false, true, true])

            let reply = try await Self.hook(port: port, token: token, "What did I link?")
            #expect(try reply.json().objectValue?["hookSpecificOutput"]?.objectValue?["additionalContext"] == .string(
                "Open in the app: ticket DEMO-12 “Fix the login form”\n"
                    + "Linked by the user: code file Sources/App/main.swift:12 in project API\n"
                    + "Linked by the user: project API “Backend”"))

            // A later message passes the resource again; with nothing else linked, its line alone.
            _ = try await bed.connection.call(ChatsSend.self, .init(
                chatID: chat.id, message: ChatMessageInput(text: "And now?", linkedItems: [Self.addedCode])))
            #expect(await process.line { FakeClaudeLauncher.text(of: $0) == "And now?" } != nil)
            let later = try await Self.hook(port: port, token: token, "And now?")
            #expect(try later.json().objectValue?["hookSpecificOutput"]?.objectValue?["additionalContext"]
                == .string("Linked by the user: code file Sources/App/main.swift:12 in project API"))
        }
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
