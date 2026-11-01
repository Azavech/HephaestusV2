import Darwin
import Foundation
import Testing
@testable import HephaestusCore

/// Permissions, questions, Stop, streaming, implement and feedback chats, the startup scan and
/// the quit (docs/chats.md › Permission prompts, › Questions, › Stopping a turn, › Streaming,
/// › Implement and feedback chats, › Idle termination and quitting).
@Suite("Chat interactions")
struct ChatInteractionTests {
    static let deniedRequestID = "1967e0c0-4eab-4e9a-8c9e-67ec5e2cb4a0"

    /// A chat process that replays `stream-write-denied.jsonl`: lines 1–26 after the user message,
    /// the rest after the answer to the permission request.
    static func writeDeniedChat() throws -> @Sendable (FakeClaudeProcess) -> Void {
        let lines = JSONLines.lines(of: try FakeClaudeLauncher.fixture("stream-write-denied.jsonl")).map { String(decoding: $0, as: UTF8.self) }
        return { process in
            process.onLine = { process, line in
                if line.contains(#""subtype":"initialize""#) {
                    process.emit(FakeClaudeLauncher.initializeAnswer(for: line))
                } else if line.hasPrefix(#"{"type":"user""#) {
                    for text in lines[0..<26] { process.emit(text) }
                } else if line.contains(deniedRequestID) {
                    for text in lines[26...] { process.emit(text) }
                }
            }
            process.onClose = { $0.exit(.exited(0)) }
        }
    }

    @Test("stream-write-denied.jsonl with a deny answer: the line of docs/chats.md, the states and the conflict")
    func permissionDenied() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = try Self.writeDeniedChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(settings: ChatSettings(model: "haiku", effort: .low), message: "Write a note")
            #expect(await bed.waitForState(chat.id, .waitingPermission))
            let pending = try await bed.transcript(chat.id).contains {
                if case .permissionRequest(let request) = $0 { return request.decision == nil } else { return false }
            }
            #expect(pending)
            _ = try await bed.connection.call(ChatsAnswerPermission.self, .init(chatID: chat.id, requestID: Self.deniedRequestID,
                                                                               decision: .deny, message: " User denied in probe "))
            let process = try #require(await launcher.chatProcess())
            #expect(await process.line { $0.contains(#""behavior":"deny""#) }
                == #"{"type":"control_response","response":{"subtype":"success","request_id":"1967e0c0-4eab-4e9a-8c9e-67ec5e2cb4a0","response":{"behavior":"deny","message":"User denied in probe"}}}"#)
            #expect(await bed.waitForState(chat.id, .idle))
            let items = try await bed.transcript(chat.id)
            let request = items.compactMap { item -> PermissionRequestItem? in
                if case .permissionRequest(let request) = item { return request }
                return nil
            }.first
            #expect(request?.decision == .deny)
            #expect(request?.decidedBy == bed.connection.deviceInfo?.name)
            #expect(request?.reason == "Path is outside allowed working directories")
            #expect(items.contains { if case .toolResult(let result) = $0 { return result.isError && result.text == "User denied in probe" } else { return false } })
            #expect(items.contains { if case .assistant(let item) = $0 { return item.id == "msg_011CgbNBQVp7hM3Fkm45qGrN#1" } else { return false } })
            let second = await engineError {
                try await bed.connection.call(ChatsAnswerPermission.self, .init(chatID: chat.id, requestID: Self.deniedRequestID, decision: .allow))
            }
            #expect(second == EngineError(.conflict, "This permission request was already answered."))
            #expect(await engineError {
                try await bed.connection.call(ChatsAnswerPermission.self, .init(chatID: chat.id, requestID: "nope", decision: .allow))
            }?.code == .notFound)
            // The session start item names the model with the cached models.
            #expect(try await bed.systemTexts(chat.id).contains("Session started · Haiku 5.5 · effort low · Ask every time"))
        }
    }

    @Test("Always Allow with a setMode suggestion stores the mode; a cancelled request is denied by nobody")
    func allowAlwaysAndCancel() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = { process in
            FakeClaudeLauncher.silentChat()(process)
            let previous = process.onLine
            process.onLine = { process, line in
                previous?(process, line)
                guard line.hasPrefix(#"{"type":"user""#) else { return }
                process.emit(FakeClaudeLauncher.initLine())
                process.emit(#"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Edit","input":{"file_path":"a"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}}"#)
                process.emit(#"{"type":"control_request","request_id":"p2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#)
            }
        }
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Edit")
            #expect(await bed.waitForItem(chat.id) { $0.id == "perm-p2" } != nil)
            #expect(await bed.state(chat.id) == .waitingPermission)
            _ = try await bed.connection.call(ChatsAnswerPermission.self, .init(chatID: chat.id, requestID: "p1", decision: .allowAlways))
            let process = try #require(await launcher.chatProcess())
            #expect(await process.line { $0.contains(#""request_id":"p1""#) }?.contains(#""updatedPermissions":[{"#) == true)
            #expect(await bed.events.wait(for: "chat.updated") { $0.chatMeta?.settings.permissionMode == .acceptEdits } != nil)
            // Still one pending request.
            #expect(await bed.state(chat.id) == .waitingPermission)
            process.emit(#"{"type":"control_cancel_request","request_id":"p2"}"#)
            let cancelled = await bed.waitForItem(chat.id) {
                if case .permissionRequest(let item) = $0 { return item.requestID == "p2" && item.decision == .deny } else { return false }
            }
            guard case .permissionRequest(let item)? = cancelled else {
                Issue.record("not cancelled")
                return
            }
            #expect(item.decidedBy == nil)
            #expect(await bed.waitForState(chat.id, .running))
            // A system/status line with permissionMode updates the stored mode.
            process.emit(#"{"type":"system","subtype":"status","permissionMode":"default"}"#)
            #expect(await bed.events.wait(for: "chat.updated") { $0.chatMeta?.settings.permissionMode == .manual } != nil)
            // An unsupported control request gets an error answer.
            process.emit(#"{"type":"control_request","request_id":"u1","request":{"subtype":"hook_callback"}}"#)
            #expect(await process.line { $0.contains(#""request_id":"u1""#) }
                == #"{"type":"control_response","response":{"subtype":"error","request_id":"u1","error":"Unsupported control request: hook_callback"}}"#)
        }
    }

    @Test("Stop: pending requests denied, the Stopped by item, interrupt, then SIGINT while the turn goes on")
    func stop() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = { process in
            FakeClaudeLauncher.silentChat()(process)
            let previous = process.onLine
            process.onLine = { process, line in
                previous?(process, line)
                guard line.hasPrefix(#"{"type":"user""#) else { return }
                process.emit(FakeClaudeLauncher.initLine())
                process.emit(#"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"}}}"#)
            }
        }
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Clean")
            #expect(await bed.waitForState(chat.id, .waitingPermission))
            _ = try await bed.connection.call(ChatsInterrupt.self, .init(chatID: chat.id))
            let process = try #require(await launcher.chatProcess())
            let name = try #require(bed.connection.deviceInfo?.name)
            #expect(await process.line { $0.contains(#""request_id":"p1""#) }?.contains(#""message":"The user stopped Claude.""#) == true)
            #expect(await process.line { $0.contains(#""subtype":"interrupt""#) } != nil)
            #expect(try await bed.systemTexts(chat.id).contains("Stopped by \(name)."))
            // The fake ignores the interrupt: SIGINT 300 ms later ends it, and no error item follows.
            _ = await process.waitForExit()
            #expect(process.receivedSignals == [SIGINT])
            #expect(await bed.waitForState(chat.id, .idle))
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await bed.systemTexts(chat.id).allSatisfy { !$0.hasPrefix("Claude was terminated") })
            let request = try await bed.transcript(chat.id).compactMap { item -> PermissionRequestItem? in
                if case .permissionRequest(let request) = item { return request }
                return nil
            }.first
            #expect(request?.decision == .deny)
            #expect(request?.decidedBy == name)
            // Stop does nothing while idle.
            _ = try await bed.connection.call(ChatsInterrupt.self, .init(chatID: chat.id))
            #expect(try await bed.systemTexts(chat.id).filter { $0.hasPrefix("Stopped by") }.count == 1)
        }
    }

    @Test("Questions: the rules, one set at a time, answers in any order and replaced, then the Answers message")
    func questions() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let claude = Actor.claude(chatID: chat.id.uuidString)
            func question(_ label: String) -> Question {
                Question(label: label, question: "Which \(label)?", options: [QuestionOption(label: " Yes ", description: "Do it."),
                                                                            QuestionOption(label: "No")], recommended: " Yes ")
            }
            let bad = await engineError {
                try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question("B")]), actor: claude)
            }
            #expect(bad == EngineError(.invalid, "Question 1 must have the label \"A\"."))
            #expect(await engineError {
                try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question("A")]),
                                          actor: .claude(chatID: UUID().uuidString))
            } == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question("A"), question("B"), question("C")]),
                                                actor: claude)
            #expect(set.questions[0].options[0].label == "Yes")
            #expect(set.answers.isEmpty && !set.completed)
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            #expect(await engineError {
                try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question("A")]), actor: claude)
            } == EngineError(.conflict, "Questions are already waiting for answers in this chat."))
            func answer(_ label: String, _ text: String) async throws {
                _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: set.questionSetID,
                                                                                 label: label, answer: text))
            }
            #expect(await engineError { try await answer("D", "No") } == EngineError(.invalid, "label: no question of the set has this label."))
            #expect(await engineError { try await answer("A", "   ") }?.code == .invalid)
            try await answer("C", "Skipped")
            try await answer("B", "No")
            try await answer("B", "Only on Mondays\nand Fridays")
            #expect(await bed.state(chat.id) == .waitingAnswers)
            try await answer("A", " Yes ")
            let process = try #require(await bed.launcher.chatProcess())
            let line = await process.line { $0.contains("Answers:") }
            #expect(line?.contains(#""text":"Answers:\nA: Yes\nB: Only on Mondays\nand Fridays\nC: Skipped""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            let items = try await bed.transcript(chat.id)
            let stored = items.compactMap { item -> QuestionsItem? in
                if case .questions(let questions) = item { return questions }
                return nil
            }.first
            #expect(stored?.completed == true)
            #expect(stored?.answers == ["A": "Yes", "B": "Only on Mondays\nand Fridays", "C": "Skipped"])
            #expect(await engineError { try await answer("B", "x") } == EngineError(.conflict, "These questions were already answered."))
            #expect(await engineError {
                try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: UUID(), label: "A", answer: "x"))
            }?.code == .notFound)
        }
    }

    @Test("Questions: the recommended option is stored and returned first, the others in their order")
    func recommendedFirst() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let question = Question(label: "A", question: "Which language?",
                                    options: [QuestionOption(label: "Java"), QuestionOption(label: "Go"),
                                              QuestionOption(label: "Rust", description: "Entry API."), QuestionOption(label: "None")],
                                    recommended: "Rust")
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]),
                                                actor: .claude(chatID: chat.id.uuidString))
            let expected = [QuestionOption(label: "Rust", description: "Entry API."), QuestionOption(label: "Java"),
                            QuestionOption(label: "Go"), QuestionOption(label: "None")]
            #expect(set.questions[0].options == expected)
            #expect(set.questions[0].recommended == "Rust")
            let stored = try await bed.transcript(chat.id).compactMap { item -> QuestionsItem? in
                if case .questions(let questions) = item { return questions }
                return nil
            }.first
            #expect(stored?.questions[0].options == expected)
        }
    }

    @Test("Text deltas are coalesced to one chat.delta per 50 ms and dropped by the final item")
    func deltas() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Stream")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            let reply = FakeClaudeLauncher.textReply(messageID: "msg_S", text: "unused")
            process.emit(reply[0])
            process.emit(reply[1])
            let start = ContinuousClock.now
            for index in 0..<20 {
                process.emit(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(index),"}},"parent_tool_use_id":null,"api_message_id":"msg_S"}"#)
            }
            let text = (0..<20).map { "\($0)," }.joined()
            @Sendable func deltas() async -> [ChatDeltaEvent.Payload] {
                await bed.events.named("chat.delta").compactMap { try? $0.payload(ChatDeltaEvent.self) }
            }
            #expect(await eventually(timeout: waitLimit) { await deltas().map(\.append).joined() == text })
            // The first delta goes out at once and each later one at least 50 ms after the one
            // before: at most one more than the 50 ms periods since the first line was written.
            let periods = Int((ContinuousClock.now - start) / .milliseconds(50))
            let streamed = await deltas()
            #expect(streamed.count >= 2 && streamed.count <= 1 + periods)
            #expect(streamed.allSatisfy { $0.itemID == "msg_S#0" && $0.kind == .text && $0.chatID == chat.id })
            #expect(streamed.map(\.append).joined() == text)
            // A delta followed at once by the final item is not sent.
            process.emit(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"end"}},"parent_tool_use_id":null,"api_message_id":"msg_S"}"#)
            process.emit(#"{"type":"assistant","message":{"id":"msg_S","content":[{"type":"text","text":"done"}]},"parent_tool_use_id":null}"#)
            #expect(await bed.waitForItem(chat.id) { $0.id == "msg_S#0" } != nil)
            try await Task.sleep(for: .milliseconds(150))
            let after = await bed.events.named("chat.delta").count
            #expect(after <= streamed.count + 1)
        }
    }

    @Test("Tool result images are stored as image-<n>.<extension>")
    func toolResultImages() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Screenshot")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            let png = Data([1, 2, 3]).base64EncodedString()
            process.emit(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_9","content":[{"type":"text","text":"shot"},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"\#(png)"}}]}]}}"#)
            let item = await bed.waitForItem(chat.id) { $0.id == "toolu_9#result" }
            guard case .toolResult(let result)? = item else {
                Issue.record("no tool result")
                return
            }
            #expect(result.text == "shot")
            #expect(result.images.map(\.name) == ["image-1.jpg"])
            #expect(result.images.first?.contentType == "image/jpeg")
            #expect(FileManager.default.contents(atPath: bed.folder.attachmentFile(path: result.images[0].path).path) == Data([1, 2, 3]))
        }
    }

    @Test("Implement: the ticket chat, its first message and its system prompt; a done ticket is refused")
    func implementTicket() async throws {
        try await withChatEngine { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "Fix the build", status: .todo, created: ISODate.now(), description: "Problem\nIt fails."))
            try await bed.writeTicket(Ticket(id: "DEMO-2", title: "Done one", status: .done, created: ISODate.now(), description: "Problem"))
            #expect(await engineError { try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "demo-2")) }
                == EngineError(.conflict, "DEMO-2 is done; set it to To Do or In Progress to implement it."))
            #expect(await engineError { try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-7")) }?.code == .notFound)
            let chat = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "demo-1"))
            #expect(chat.kind == .ticket)
            #expect(chat.ticketID == "DEMO-1")
            #expect(try ProjectFileStore.readTicket(at: bed.folder.ticketFile("DEMO-1"), projectID: "DEMO").chatIDs == [chat.id])
            let process = try #require(await bed.launcher.chatProcess())
            let prompt = try #require(process.request.arguments.firstIndex(of: "--append-system-prompt").map { process.request.arguments[$0 + 1] })
            #expect(prompt.contains("This is the chat of ticket DEMO-1 of the project Demo (DEMO)."))
            #expect(prompt.contains("<ticket>\nID: DEMO-1\nTitle: Fix the build\nStatus: todo\n"))
            #expect(prompt.contains("<description>\nProblem\nIt fails.\n</description>\nAttachments: none\nComments: none\nChats: none\n</ticket>"))
            #expect(await bed.waitForState(chat.id, .idle))
            guard case .user(let user)? = try await bed.transcript(chat.id).first else {
                Issue.record("no user item")
                return
            }
            #expect(user.text.hasPrefix("Implement ticket DEMO-1: Fix the build\n\nFollow \"Implementing a ticket\""))
            #expect(user.text.contains(#"of the form "<type>: <summary> (DEMO-1)""#))
            // Called by Claude, the first message's sender is Claude.
            let byClaude = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: .claude(chatID: chat.id.uuidString))
            #expect(await bed.waitForState(byClaude.id, .idle))
            guard case .user(let first)? = try await bed.transcript(byClaude.id).first else {
                Issue.record("no user item")
                return
            }
            #expect(first.sender == "Claude")
        }
    }

    @Test("Implement All: the bundle chat and its message; a bundle without a ticket left is refused")
    func implementBundle() async throws {
        try await withChatEngine { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            try await bed.writeTicket(Ticket(id: "DEMO-2", title: "Two", status: .done, created: ISODate.now(), description: "Problem"))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B1", title: "Polish", created: ISODate.now(), ticketIDs: ["DEMO-1", "DEMO-2"]))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B2", title: "Finished", created: ISODate.now(), ticketIDs: ["DEMO-2"]))
            #expect(await engineError { try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B2")) }
                == EngineError(.conflict, "DEMO-B2 has no ticket left to implement."))
            let chat = try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1"))
            #expect(chat.bundleID == "DEMO-B1")
            #expect(try ProjectFileStore.readBundle(at: bed.folder.bundleFile("DEMO-B1"), projectID: "DEMO").chatIDs == [chat.id])
            let process = try #require(await bed.launcher.chatProcess())
            let prompt = try #require(process.request.arguments.firstIndex(of: "--append-system-prompt").map { process.request.arguments[$0 + 1] })
            #expect(prompt.contains("<bundle>\nID: DEMO-B1\nTitle: Polish\nTickets: DEMO-1, DEMO-2\n\nTicket 1 of 2:\nID: DEMO-1\n"))
            #expect(await process.line { $0.contains("Implement bundle DEMO-B1: Polish") }?.contains("Its tickets, in this order: DEMO-1, DEMO-2.") == true)
        }
    }

    @Test("Feedback: the message of docs/chats.md › Feedback message with the screenshot as its image")
    func feedback() async throws {
        try await withChatEngine { bed in
            let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
            let context = FeedbackContext(appVersion: "0.4.0", build: 57, deviceName: "MacBook", mainDeviceName: "Studio", projectID: "DEMO",
                                          section: .web, item: "https://github.com/")
            #expect(await engineError {
                try await bed.connection.call(ChatsCreateFeedback.self, .init(projectID: "DEMO", comment: "x",
                                                                             screenshot: AttachmentUpload(name: "s.jpg", contentType: "image/jpeg", dataBase64: png),
                                                                             context: context))
            }?.code == .invalid)
            let chat = try await bed.connection.call(ChatsCreateFeedback.self, .init(
                projectID: "DEMO", comment: "The lock icon disappears.", screenshot: AttachmentUpload(name: "window.png", contentType: "image/png", dataBase64: png),
                context: context))
            #expect(chat.kind == .feedback)
            #expect(chat.ticketID == nil)
            let process = try #require(await bed.launcher.chatProcess())
            let line = try #require(await process.line { $0.hasPrefix(#"{"type":"user""#) })
            #expect(line.contains(#"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}"#))
            #expect(await bed.waitForState(chat.id, .idle))
            guard case .user(let user)? = try await bed.transcript(chat.id).first else {
                Issue.record("no user item")
                return
            }
            let screenshot = try #require(user.attachments.first)
            #expect(screenshot.name == "screenshot.png")
            let path = bed.folder.attachmentFile(path: screenshot.path).path
            #expect(user.text == """
            The lock icon disappears.

            Feedback context:
            - App: HephaestusV2 v0.4.0(57)
            - Device: MacBook, connected to Studio
            - Project: Demo (DEMO)
            - Section: web
            - Item: https://github.com/
            - Screenshot: \(path)
            """)
            let prompt = try #require(process.request.arguments.firstIndex(of: "--append-system-prompt").map { process.request.arguments[$0 + 1] })
            #expect(prompt.contains("<feedback>\n- App: HephaestusV2 v0.4.0(57)\n"))
            #expect(prompt.contains("attachments [\"\(path)\"]"))
        }
    }

    @Test("At startup a waiting question set gives waitingAnswers and pending requests are cancelled")
    func startupScan() async throws {
        let chatID = UUID()
        let setID = UUID()
        try await withChatEngine(prepare: { folder, _ in
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), sessionStarted: true), to: folder)
            let questions = QuestionsItem(id: setID.uuidString, created: ISODate.now(), questionSetID: setID, questions: [
                Question(label: "A", question: "?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")], recommended: "x"),
            ])
            let request = PermissionRequestItem(id: "perm-r", created: ISODate.now(), requestID: "r", toolName: "Bash")
            let writer = JSONLinesWriter()
            try writer.append(TranscriptLine(op: .add, item: .questions(questions)), to: folder.transcriptFile(chatID))
            try writer.append(TranscriptLine(op: .add, item: .permissionRequest(request)), to: folder.transcriptFile(chatID))
        }) { bed in
            #expect(await bed.waitForState(chatID, .waitingAnswers))
            let text = try String(contentsOf: bed.folder.transcriptFile(chatID), encoding: .utf8)
            #expect(text.components(separatedBy: "\n").filter { $0.contains(#""op":"update""#) && $0.contains(#""decision":"deny""#) }.count == 1)
            let listed = try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO"))
            #expect(listed.first?.state == .waitingAnswers)
        }
    }

    @Test("Quit: a turn in progress gets the quit item and every process ends")
    func quit() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Long work")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(chat.id, .running))
            await bed.engine.shutdown()
            #expect(process.hasExited)
            #expect(process.receivedSignals.first == SIGTERM)
            let text = try String(contentsOf: bed.folder.transcriptFile(chat.id), encoding: .utf8)
            #expect(text.contains("Stopped because HephaestusV2 quit."))
            #expect(!FileManager.default.fileExists(atPath: bed.dataDirectory.mcpConfigFile(chatID: chat.id).path))
        }
    }

    @Test("An mcpPort change ends idle processes at once and busy ones when their turn ends")
    func mcpPortChange() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let busy = try await bed.createChat(message: "Busy")
            let busyProcess = try #require(await launcher.chatProcess())
            busyProcess.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(busy.id, .running))
            await bed.engine.pretendMCPPortChanged()
            try await Task.sleep(for: .milliseconds(100))
            #expect(!busyProcess.hasExited)
            busyProcess.emit(FakeClaudeLauncher.resultLine())
            _ = await busyProcess.waitForExit()
            #expect(busyProcess.receivedSignals.first == SIGTERM)
            #expect(await bed.waitForState(busy.id, .idle))
        }
    }

    @Test("chats.get cancels the pending requests of a chat without a live process; the debug capture holds stdout")
    func getCancelsAndCapture() async throws {
        let chatID = UUID()
        try await withChatEngine(debugTools: true, prepare: { folder, _ in
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now()), to: folder)
        }) { bed in
            // Written after the startup scan: only chats.get finds it.
            try await Task.sleep(for: .milliseconds(100))
            let request = PermissionRequestItem(id: "perm-q", created: ISODate.now(), requestID: "q", toolName: "Bash")
            try JSONLinesWriter().append(TranscriptLine(op: .add, item: .permissionRequest(request)), to: bed.folder.transcriptFile(chatID))
            let items = try await bed.transcript(chatID)
            guard case .permissionRequest(let item)? = items.first else {
                Issue.record("no request")
                return
            }
            #expect(item.decision == .deny && item.decidedBy == nil)
            try await bed.send(chatID, "Hello")
            #expect(await bed.waitForState(chatID, .idle))
            let capture = try String(contentsOf: bed.dataDirectory.claudeStdoutCaptureFile(chatID: chatID), encoding: .utf8)
            #expect(capture.contains(#""subtype":"init""#))
            let log = try String(contentsOf: bed.dataDirectory.claudeLogFile(chatID: chatID), encoding: .utf8)
            #expect(log.contains("--- "))
        }
    }
}

extension Engine {
    /// As if `settings.update` had moved the MCP server: the processes were launched with another port.
    func pretendMCPPortChanged() async {
        for runtime in chats.runtimes.values {
            runtime.process?.mcpPort = -1
        }
        await mcpPortDidChange()
    }
}
