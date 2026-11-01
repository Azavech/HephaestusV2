import Darwin
import Foundation
import Testing
@testable import HephaestusCore

/// The chat methods and the chat process through `LocalEngineConnection` with the in-memory
/// launcher (docs/engine-api.md › Chats, docs/chats.md › Chat process).
@Suite("Chat lifecycle")
struct ChatLifecycleTests {
    static func isUserLine(_ line: String) -> Bool { line.hasPrefix(#"{"type":"user""#) }

    @Test("chats.create without a message writes the metadata file and emits chat.updated")
    func createWithoutMessage() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(settings: ChatSettings(model: "opus", effort: .low))
            #expect(chat.title == "New Chat")
            #expect(chat.kind == .project)
            #expect(chat.projectID == "DEMO")
            #expect(chat.state == .idle)
            #expect(!chat.sessionStarted)
            #expect(chat.settings == ChatSettings(model: "opus", effort: .low))
            let file = try ProjectFileStore.readChatMeta(at: bed.folder.chatMetaFile(chat.id), projectID: "DEMO")
            #expect(file.id == chat.id)
            #expect(await bed.events.wait(for: "chat.updated") { $0.chatMeta?.id == chat.id } != nil)
            #expect(try await bed.connection.call(ChatsList.self, .init(projectID: "demo")).map(\.id) == [chat.id])
            #expect(try await bed.transcript(chat.id).isEmpty)
            #expect(bed.launcher.chatProcesses.isEmpty)
            // Without settings, the project's chatDefaults, else the host defaultChatSettings.
            #expect(try await bed.createChat().settings == ChatSettings())
        }
    }

    @Test("chats.create checks its params")
    func createErrors() async throws {
        try await withChatEngine { bed in
            func create(_ params: ChatsCreate.Params) async -> EngineError? {
                await engineError { try await bed.connection.call(ChatsCreate.self, params) }
            }
            #expect(await create(.init(projectID: "DEMO", kind: .feedback))
                == EngineError(.invalid, "kind: feedback chats are created by chats.createFeedback."))
            #expect(await create(.init(projectID: "DEMO", kind: .ticket))?.code == .invalid)
            #expect(await create(.init(projectID: "DEMO", kind: .project, ticketID: "DEMO-1"))?.code == .invalid)
            #expect(await create(.init(projectID: "DEMO", kind: .ticket, ticketID: "OTHER-1"))
                == EngineError(.invalid, "OTHER-1 does not belong to project DEMO."))
            #expect(await create(.init(projectID: "DEMO", kind: .ticket, ticketID: "DEMO-9")) == EngineError(.notFound, "Ticket DEMO-9 not found."))
            #expect(await create(.init(projectID: "DEMO", kind: .project, settings: ChatSettings(model: "my model")))?.code == .invalid)
            #expect(await create(.init(projectID: "NOPE", kind: .project)) == EngineError(.notFound, "Project NOPE not found."))
            #expect(await create(.init(projectID: "1", kind: .project))?.code == .invalid)
            #expect(await create(.init(projectID: "DEMO", kind: .project, message: ChatMessageInput(text: "  ")))?.code == .invalid)
        }
    }

    @Test("A message launches Claude with the command line of docs/chats.md and the turn ends idle")
    func firstMessage() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan the next sprint")
            #expect(chat.state == .starting)
            let process = try #require(await bed.launcher.chatProcess())
            let argv = [process.request.executable] + process.request.arguments
            let configPath = bed.dataDirectory.mcpConfigFile(chatID: chat.id).path
            #expect(Array(argv.prefix(26)) == [
                "/fake/bin/claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--session-id", chat.id.uuidString, "--model", "default", "--effort", "high",
                "--permission-mode", "manual", "--allow-dangerously-skip-permissions", "--permission-prompt-tool", "stdio",
                "--mcp-config", configPath, "--allowedTools", ClaudeCommandLine.preApprovedTools, "--disallowedTools", "AskUserQuestion",
                "--append-system-prompt",
            ])
            let prompt = argv[26]
            #expect(prompt.contains("chat of the project Demo (identifier DEMO)"))
            #expect(prompt.contains("The project's root folder is \(bed.root.path) on the device"))
            #expect(prompt.contains("- build: make build"))
            #expect(prompt.contains("\n\n# This chat\n\nThis is a project chat of Demo (DEMO)."))
            // initialize first, then the user message, without waiting.
            #expect(await process.line { Self.isUserLine($0) } != nil)
            #expect(process.writtenLines.prefix(2) == [
                #"{"type":"control_request","request_id":"hephaestus-1","request":{"subtype":"initialize"}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Plan the next sprint"}]}}"#,
            ])
            #expect(await bed.waitForItem(chat.id) { if case .result = $0 { return true } else { return false } } != nil)
            #expect(await bed.waitForState(chat.id, .idle))
            let items = try await bed.transcript(chat.id)
            guard case .user(let user) = items.first else {
                Issue.record("the first item is not the user item")
                return
            }
            #expect(user.text == "Plan the next sprint")
            #expect(user.sender == bed.connection.deviceInfo?.name)
            let texts = try await bed.systemTexts(chat.id)
            #expect(texts.contains("Session started · Haiku 5.5 · effort high · Ask every time"))
            #expect(items.contains { if case .assistant(let item) = $0 { return item.text == "ok" && item.id == "msg_1#0" } else { return false } })
            // The session started; Haiku named the chat.
            let named = await bed.events.wait(for: "chat.updated") { $0.chatMeta?.title == "Plan the sprint" }
            #expect(named?.origin == .system)
            let meta = try await bed.connection.call(ChatsGet.self, .init(chatID: chat.id)).meta
            #expect(meta.sessionStarted)
            #expect(meta.title == "Plan the sprint")
            // The MCP configuration file holds the chat token, mode 0600.
            let config = try String(contentsOf: bed.dataDirectory.mcpConfigFile(chatID: chat.id), encoding: .utf8)
            let port = try #require(await bed.engine.mcpServer.port)
            #expect(config.hasPrefix(#"{"mcpServers":{"hephaestus":{"type":"http","url":"http://127.0.0.1:\#(port)/mcp","headers":{"Authorization":"Bearer "#))
            let attributes = try FileManager.default.attributesOfItem(atPath: configPath)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let actor = await bed.engine.tokens.actor(forToken: String(config.split(separator: " ").last!.prefix(64)))
            #expect(actor == .claude(chatID: chat.id.uuidString))
            // The log holds the launch line with the length of the system prompt.
            let log = try String(contentsOf: bed.dataDirectory.claudeLogFile(chatID: chat.id), encoding: .utf8)
            #expect(log.contains("launch: /fake/bin/claude -p "))
            #expect(log.contains("--append-system-prompt <\(prompt.count) characters>"))
            #expect(!log.contains("You are Claude"))
        }
    }

    @Test("Messages go to the live process; after an exit the next message resumes the session")
    func secondMessageAndResume() async throws {
        var timings = testChatTimings()
        timings.idleTimeout = .milliseconds(300)
        try await withChatEngine(chatTimings: timings) { bed in
            let chat = try await bed.createChat(message: "One")
            let first = try #require(await bed.launcher.chatProcess())
            #expect(await bed.waitForState(chat.id, .idle))
            try await bed.send(chat.id, "Two")
            #expect(await first.line { $0.contains(#""text":"Two""#) } != nil)
            #expect(bed.launcher.chatProcesses.count == 1)
            // Idle termination: standard input closed; the fake exits.
            _ = await first.waitForExit()
            #expect(first.isInputClosed)
            try await Task.sleep(for: .milliseconds(200))
            #expect(!FileManager.default.fileExists(atPath: bed.dataDirectory.mcpConfigFile(chatID: chat.id).path))
            try await bed.send(chat.id, "Three")
            let second = try #require(await bed.launcher.chatProcess(1))
            #expect(Array(second.request.arguments[7...8]) == ["--resume", chat.id.uuidString])
            #expect(await second.line { $0.contains(#""text":"Three""#) } != nil)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await bed.systemTexts(chat.id).filter { $0.hasPrefix("Claude exited") }.isEmpty)
        }
    }

    @Test("chats.updateSettings stores the settings and sends one control request per changed field")
    func liveSettings() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Hello")
            let process = try #require(await bed.launcher.chatProcess())
            #expect(await bed.waitForState(chat.id, .idle))
            let new = ChatSettings(model: "opus", effort: .max, permissionMode: .manual, ultracode: true)
            let updated = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: new))
            #expect(updated.settings == new)
            #expect(await process.line { $0.contains("set_model") } == #"{"type":"control_request","request_id":"hephaestus-2","request":{"subtype":"set_model","model":"opus"}}"#)
            #expect(await process.line { $0.contains("effortLevel") }?.contains(#""settings":{"effortLevel":"max"}"#) == true)
            #expect(await process.line { $0.contains(#""ultracode":true"#) } != nil)
            #expect(!process.writtenLines.contains { $0.contains("set_permission_mode") })
            // An unchanged call writes nothing and sends nothing.
            let written = process.writtenLines.count
            let unchanged = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: new))
            #expect(unchanged.settings == new)
            #expect(process.writtenLines.count == written)
            // A refused setting adds the warning item.
            process.onLine = { process, line in
                guard line.contains("set_permission_mode"), let id = FakeClaudeLauncher.requestID(of: line) else { return }
                process.emit(#"{"type":"control_response","response":{"subtype":"error","request_id":"\#(id)","error":"Mode unavailable."}}"#)
            }
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: ChatSettings(
                model: "opus", effort: .max, permissionMode: .plan, ultracode: true)))
            let warning = await bed.waitForItem(chat.id) {
                if case .system(let item) = $0 { return item.text.hasPrefix("Claude did not accept") } else { return false }
            }
            guard case .system(let item)? = warning else {
                Issue.record("no warning")
                return
            }
            #expect(item.text == "Claude did not accept the new permission mode setting now: Mode unavailable. It applies the next time Claude starts.")
            #expect(await engineError {
                try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: ChatSettings(model: "")))
            }?.code == .invalid)
        }
    }

    @Test("chats.rename trims the title; an invalid title and an unknown chat fail")
    func rename() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat()
            let renamed = try await bed.connection.call(ChatsRename.self, .init(chatID: chat.id, title: "  Sprint plan "))
            #expect(renamed.title == "Sprint plan")
            #expect(await engineError { try await bed.connection.call(ChatsRename.self, .init(chatID: chat.id, title: "a\nb")) }?.code == .invalid)
            #expect(await engineError { try await bed.connection.call(ChatsRename.self, .init(chatID: UUID(), title: "x")) }?.code == .notFound)
            // Claude may rename its chat.
            let byClaude = try await bed.engine.call(ChatsRename.self, .init(chatID: chat.id, title: "By Claude"),
                                                     actor: .claude(chatID: chat.id.uuidString))
            #expect(byClaude.title == "By Claude")
        }
    }

    @Test("A spawn failure gives the error state; the next message clears it")
    func spawnFailure() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.spawnFailure = "cannot start /fake/bin/claude: Exec format error"
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Hello")
            #expect(await bed.waitForState(chat.id, .error))
            #expect(try await bed.systemTexts(chat.id).contains("Claude failed to start: cannot start /fake/bin/claude: Exec format error"))
            launcher.spawnFailure = nil
            try await bed.send(chat.id, "Again")
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(launcher.chatProcesses.count == 1)
        }
    }

    @Test("A non-zero exit during a turn adds the error item with the last stderr line")
    func crash() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = { process in
            process.onLine = { process, line in
                guard ChatLifecycleTests.isUserLine(line) else { return }
                process.emit(FakeClaudeLauncher.initLine())
                process.emitStderr("warming up\nFatal: out of memory\n\n")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { process.exit(.exited(2)) }
            }
        }
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Hello")
            #expect(await bed.waitForState(chat.id, .error))
            #expect(try await bed.systemTexts(chat.id).contains("Claude exited with code 2: Fatal: out of memory"))
            let log = try String(contentsOf: bed.dataDirectory.claudeLogFile(chatID: chat.id), encoding: .utf8)
            #expect(log.contains("Fatal: out of memory"))
            #expect(Engine.exitText(.signaled(9), lastLine: "x") == "Claude was terminated by signal 9.")
            #expect(Engine.exitText(.exited(1), lastLine: nil) == "Claude exited with code 1.")
        }
    }

    @Test("Without system/init in time the process is terminated and the chat is in error")
    func startTimeout() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        var timings = testChatTimings()
        timings.startTimeout = .milliseconds(300)
        try await withChatEngine(launcher: launcher, chatTimings: timings) { bed in
            let chat = try await bed.createChat(message: "Hello")
            let process = try #require(await launcher.chatProcess())
            #expect(await bed.waitForState(chat.id, .error))
            _ = await process.waitForExit()
            #expect(process.receivedSignals.first == SIGTERM)
            try await Task.sleep(for: .milliseconds(200))
            let texts = try await bed.systemTexts(chat.id)
            #expect(texts.contains("Claude did not start within 60 seconds."))
            #expect(!texts.contains { $0.hasPrefix("Claude was terminated") })
            #expect(await bed.state(chat.id) == .error)
        }
    }

    @Test("A resumed session that is not found starts a new session with the same message")
    func missingSession() async throws {
        let launcher = FakeClaudeLauncher()
        let chatID = UUID()
        launcher.chatScript = { process in
            if process.arguments.contains("--resume") {
                process.onLine = { process, line in
                    guard ChatLifecycleTests.isUserLine(line) else { return }
                    process.emitStderr("No conversation found with session ID: \(chatID.uuidString)\n")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { process.exit(.exited(1)) }
                }
            } else {
                FakeClaudeLauncher.replyingChat()(process)
            }
        }
        try await withChatEngine(launcher: launcher, prepare: { folder, _ in
            let meta = ChatMeta(id: chatID, kind: .project, created: ISODate.now(), sessionStarted: true)
            try ProjectFileStore.write(meta, to: folder)
        }) { bed in
            try await bed.send(chatID, "Remember me?")
            let second = try #require(await launcher.chatProcess(1))
            #expect(second.request.arguments.contains("--session-id"))
            #expect(await second.line { $0.contains("Remember me?") } != nil)
            #expect(await bed.waitForState(chatID, .idle))
            let texts = try await bed.systemTexts(chatID)
            #expect(texts.contains("Claude's session for this chat was not found. A new session started; Claude does not remember the earlier messages of this chat."))
            #expect(!texts.contains { $0.hasPrefix("Claude exited") })
            #expect(try await bed.connection.call(ChatsGet.self, .init(chatID: chatID)).meta.sessionStarted)
        }
    }

    @Test("chats.delete terminates the process, unlinks the ticket and moves the files to the Trash")
    func delete() async throws {
        try await withChatEngine { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "First", created: ISODate.now(), description: "Problem"))
            let chat = try await bed.createChat(kind: .ticket, ticketID: "DEMO-1", message: "Hello")
            #expect(try ProjectFileStore.readTicket(at: bed.folder.ticketFile("DEMO-1"), projectID: "DEMO").chatIDs == [chat.id])
            let process = try #require(await bed.launcher.chatProcess())
            #expect(await bed.waitForState(chat.id, .idle))
            _ = try await bed.connection.call(ChatsDelete.self, .init(chatID: chat.id))
            #expect(process.receivedSignals.first == SIGTERM)
            #expect(!FileManager.default.fileExists(atPath: bed.folder.chatMetaFile(chat.id).path))
            #expect(!FileManager.default.fileExists(atPath: bed.folder.transcriptFile(chat.id).path))
            #expect(try ProjectFileStore.readTicket(at: bed.folder.ticketFile("DEMO-1"), projectID: "DEMO").chatIDs.isEmpty)
            let deleted = await bed.events.wait(for: "chat.deleted")
            #expect(try deleted?.payload(ChatDeletedEvent.self) == .init(projectID: "DEMO", chatID: chat.id))
            #expect(await engineError { try await bed.connection.call(ChatsGet.self, .init(chatID: chat.id)) }
                == EngineError(.notFound, "Chat \(chat.id.uuidString) not found."))
        }
    }

    @Test("Attachments: images up to 5,000,000 bytes become image blocks, other files are listed")
    func attachments() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat()
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            try await bed.send(chat.id, "Why does the build fail?", attachments: [
                AttachmentUpload(name: "build.txt", contentType: "", dataBase64: Data("log".utf8).base64EncodedString()),
                AttachmentUpload(name: "shot.png", contentType: "image/png", dataBase64: png.base64EncodedString()),
            ])
            let process = try #require(await bed.launcher.chatProcess())
            let line = try #require(await process.line { Self.isUserLine($0) })
            let items = try await bed.transcript(chat.id)
            guard case .user(let user) = items.first else {
                Issue.record("no user item")
                return
            }
            #expect(user.text == "Why does the build fail?")
            #expect(user.attachments.map(\.name) == ["build.txt", "shot.png"])
            #expect(user.attachments[0].contentType == "text/plain")
            let logPath = bed.folder.attachmentFile(path: user.attachments[0].path).path
            #expect(FileManager.default.contents(atPath: logPath) == Data("log".utf8))
            let expected = ControlLines.userMessage(
                text: "Why does the build fail?\n\nAttached files:\n- \(logPath)",
                images: [ControlLines.Image(mediaType: "image/png", base64: png.base64EncodedString())])
            #expect(line + "\n" == String(decoding: expected, as: UTF8.self))
            // A message of attachments only, and the limits.
            #expect(await engineError {
                try await bed.send(chat.id, "", attachments: [AttachmentUpload(name: "x", contentType: "", dataBase64: "@@@")])
            }?.code == .invalid)
            #expect(await engineError {
                try await bed.send(chat.id, "", attachments: [AttachmentUpload(name: "x", contentType: "", sourcePath: "/etc/hosts")])
            } == EngineError(.forbidden, "sourcePath is accepted from Claude only."))
        }
    }
}
