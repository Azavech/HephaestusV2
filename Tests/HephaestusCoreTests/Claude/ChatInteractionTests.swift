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

    /// A chat process that sends the given `can_use_tool` requests after the user message and
    /// answers `set_permission_mode` with success, or with `error` when it is set.
    static func pendingPermissionsChat(_ requests: [String], error: String? = nil) -> @Sendable (FakeClaudeProcess) -> Void {
        { process in
            process.onLine = { process, line in
                if line.contains(#""subtype":"initialize""#) {
                    process.emit(FakeClaudeLauncher.initializeAnswer(for: line))
                } else if line.hasPrefix(#"{"type":"user""#) {
                    process.emit(FakeClaudeLauncher.initLine())
                    for request in requests { process.emit(request) }
                } else if line.contains("set_permission_mode"), let id = FakeClaudeLauncher.requestID(of: line) {
                    if let error {
                        process.emit(#"{"type":"control_response","response":{"subtype":"error","request_id":"\#(id)","error":"\#(error)"}}"#)
                    } else {
                        process.emit(FakeClaudeLauncher.controlSuccess(id))
                    }
                }
            }
        }
    }

    static func canUseTool(_ requestID: String, _ tool: String, _ input: String) -> String {
        #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"can_use_tool","tool_name":"\#(tool)","input":\#(input)}}"#
    }

    static func permissionItems(_ items: [ChatItem]) -> [String: PermissionRequestItem] {
        var result: [String: PermissionRequestItem] = [:]
        for item in items {
            if case .permissionRequest(let request) = item { result[request.requestID] = request }
        }
        return result
    }

    @Test("A switch to Allow All during a turn approves every pending request once the CLI accepts it")
    func allowAllApprovesPending() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.pendingPermissionsChat([
            Self.canUseTool("p1", "Bash", #"{"command":"touch a.txt"}"#),
            Self.canUseTool("p2", "mcp__hephaestus__delete_ticket", #"{"ticketID":"DEMO-1"}"#),
        ])
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Work")
            #expect(await bed.waitForItem(chat.id) { $0.id == "perm-p2" } != nil)
            #expect(await bed.state(chat.id) == .waitingPermission)
            var settings = chat.settings
            settings.permissionMode = .bypassPermissions
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: settings))
            let process = try #require(await launcher.chatProcess())
            #expect(await process.line { $0.contains(#""request_id":"p1""#) }
                == #"{"type":"control_response","response":{"subtype":"success","request_id":"p1","response":{"behavior":"allow","updatedInput":{"command":"touch a.txt"}}}}"#)
            #expect(await process.line { $0.contains(#""request_id":"p2""#) }?.contains(#""behavior":"allow""#) == true)
            // The mode request comes first, the approvals after its success answer.
            let lines = process.writtenLines
            let modeIndex = try #require(lines.firstIndex { $0.contains(#""set_permission_mode","mode":"bypassPermissions""#) })
            let approvalIndex = try #require(lines.firstIndex { $0.contains(#""request_id":"p1""#) })
            #expect(modeIndex < approvalIndex)
            #expect(await bed.waitForState(chat.id, .running))
            let requests = Self.permissionItems(try await bed.transcript(chat.id))
            let name = bed.connection.deviceInfo?.name
            #expect(requests["p1"]?.decision == .allow && requests["p1"]?.decidedBy == name)
            #expect(requests["p2"]?.decision == .allow && requests["p2"]?.decidedBy == name)
            // An approved request can no longer be answered.
            #expect(await engineError {
                try await bed.connection.call(ChatsAnswerPermission.self, .init(chatID: chat.id, requestID: "p1", decision: .deny))
            }?.code == .conflict)
        }
    }

    @Test("A switch to Accept Edits approves only the pending file edits inside the project root")
    func acceptEditsApprovesFileEdits() async throws {
        try await withChatEngine { bed in
            // The requests name the project root with its symbolic links resolved, as the CLI does.
            let root = Engine.resolvedPath(bed.folder.root)
            bed.launcher.chatScript = Self.pendingPermissionsChat([
                Self.canUseTool("edit", "Edit", #"{"file_path":"\#(root)/Sources/a.swift","old_string":"a","new_string":"b"}"#),
                Self.canUseTool("write", "Write", #"{"file_path":"notes/new.md","content":"x"}"#),
                Self.canUseTool("notebook", "NotebookEdit", #"{"notebook_path":"\#(root)/n.ipynb","new_source":"x"}"#),
                Self.canUseTool("outside", "Write", #"{"file_path":"\#(root)/../elsewhere.txt","content":"x"}"#),
                Self.canUseTool("bash", "Bash", #"{"command":"git init"}"#),
            ])
            let chat = try await bed.createChat(message: "Edit")
            #expect(await bed.waitForItem(chat.id) { $0.id == "perm-bash" } != nil)
            var settings = chat.settings
            settings.permissionMode = .acceptEdits
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: settings))
            let process = try #require(await bed.launcher.chatProcess())
            #expect(await process.line { $0.contains(#""request_id":"notebook""#) }?.contains(#""behavior":"allow""#) == true)
            #expect(await process.line { $0.contains(#""request_id":"edit""#) } != nil)
            #expect(await process.line { $0.contains(#""request_id":"write""#) } != nil)
            #expect(!process.writtenLines.contains { $0.contains(#""request_id":"outside""#) || $0.contains(#""request_id":"bash""#) })
            let requests = Self.permissionItems(try await bed.transcript(chat.id))
            #expect(requests["edit"]?.decision == .allow)
            #expect(requests["write"]?.decision == .allow)
            #expect(requests["notebook"]?.decision == .allow)
            #expect(requests["outside"]?.decision == nil)
            #expect(requests["bash"]?.decision == nil)
            #expect(await bed.state(chat.id) == .waitingPermission)
            // Another mode approves nothing.
            settings.permissionMode = .auto
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: settings))
            #expect(await process.line { $0.contains(#""set_permission_mode","mode":"auto""#) } != nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(!process.writtenLines.contains { $0.contains(#""request_id":"outside""#) || $0.contains(#""request_id":"bash""#) })
            #expect(await bed.state(chat.id) == .waitingPermission)
        }
    }

    @Test("A refused mode, or a mode changed again before the CLI's answer, approves nothing")
    func refusedModeApprovesNothing() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.pendingPermissionsChat([Self.canUseTool("p1", "Bash", #"{"command":"touch a.txt"}"#)],
                                                          error: "Mode unavailable.")
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Work")
            #expect(await bed.waitForItem(chat.id) { $0.id == "perm-p1" } != nil)
            var settings = chat.settings
            settings.permissionMode = .bypassPermissions
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: settings))
            #expect(await bed.waitForItem(chat.id) {
                if case .system(let item) = $0 { return item.text.hasPrefix("Claude did not accept the new permission mode") } else { return false }
            } != nil)
            let process = try #require(await launcher.chatProcess())
            #expect(!process.writtenLines.contains { $0.contains(#""request_id":"p1""#) })
            #expect(await bed.state(chat.id) == .waitingPermission)
            // The chat goes to Ask Every Time (refused too), to Allow All, then back to Ask Every
            // Time before the CLI answers: the success for Allow All arrives when it is no longer
            // the chat's mode, and approves nothing.
            settings.permissionMode = .manual
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: settings))
            #expect(await process.line { $0.contains(#""set_permission_mode","mode":"default""#) } != nil)
            process.onLine = { process, line in
                guard line.contains(#""set_permission_mode","mode":"default""#), let id = FakeClaudeLauncher.requestID(of: line),
                      let number = Int(id.dropFirst("hephaestus-".count)) else { return }
                process.emit(FakeClaudeLauncher.controlSuccess(ControlLines.requestID(number - 1)))
                process.emit(FakeClaudeLauncher.controlSuccess(id))
            }
            settings.permissionMode = .bypassPermissions
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: settings))
            settings.permissionMode = .manual
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: settings))
            // Allow All again, answered at once: the request is approved after this last mode
            // request only, so the late success above approved nothing.
            process.onLine = { process, line in
                guard line.contains("set_permission_mode"), let id = FakeClaudeLauncher.requestID(of: line) else { return }
                process.emit(FakeClaudeLauncher.controlSuccess(id))
            }
            settings.permissionMode = .bypassPermissions
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: chat.id, settings: settings))
            #expect(await process.line { $0.contains(#""request_id":"p1""#) }?.contains(#""behavior":"allow""#) == true)
            let lines = process.writtenLines
            let lastMode = try #require(lines.lastIndex { $0.contains(#""set_permission_mode","mode":"bypassPermissions""#) })
            #expect(lines.filter { $0.contains("set_permission_mode") }.count == 5)
            #expect(lines.firstIndex { $0.contains(#""request_id":"p1""#) }.map { $0 > lastMode } == true)
            #expect(await bed.waitForState(chat.id, .running))
        }
    }

    @Test("Accept Edits counts a file inside the project root through symbolic links, and nothing outside")
    func acceptEditsPaths() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let link = temporary.appendingPathComponent("Link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            func edit(_ tool: String, _ field: String, _ path: String) -> PermissionRequestItem {
                PermissionRequestItem(id: "perm-x", created: Date(), requestID: "x", toolName: tool, input: .object([field: .string(path)]))
            }
            func allows(_ item: PermissionRequestItem) -> Bool {
                Engine.permissionMode(.acceptEdits, allows: item, projectRoot: root)
            }
            #expect(allows(edit("Edit", "file_path", root.path + "/a/b.swift")))
            #expect(allows(edit("Write", "file_path", link.path + "/new/c.txt")))
            #expect(allows(edit("Write", "file_path", Engine.resolvedPath(root) + "/d.txt")))
            #expect(allows(edit("Write", "file_path", "relative.txt")))
            #expect(allows(edit("NotebookEdit", "notebook_path", root.path + "/n.ipynb")))
            #expect(!allows(edit("NotebookEdit", "file_path", root.path + "/n.ipynb")))
            #expect(!allows(edit("Write", "file_path", root.path + "/../outside.txt")))
            #expect(!allows(edit("Write", "file_path", root.path + "Sibling/x.txt")))
            #expect(!allows(edit("Bash", "file_path", root.path + "/a.txt")))
            #expect(!Engine.permissionMode(.acceptEdits, allows: edit("Edit", "file_path", root.path + "/a"), projectRoot: nil))
            #expect(Engine.permissionMode(.bypassPermissions, allows: edit("Bash", "command", "rm -rf build"), projectRoot: nil))
            for mode in [PermissionMode.manual, .plan, .auto, .dontAsk] {
                #expect(!Engine.permissionMode(mode, allows: edit("Edit", "file_path", root.path + "/a"), projectRoot: root))
            }
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

    @Test("Multiple-choice questions: recommended options first, answers checked against the bounds, then the Answers message")
    func multipleChoiceQuestions() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let multiple = Question(label: "A", question: "Where should the build number appear?", kind: .multiple,
                                    options: [QuestionOption(label: "Status bar"), QuestionOption(label: "About window"),
                                              QuestionOption(label: "Window title")],
                                    recommended: ["Window title", "Status bar"], maxChoices: 3)
            let single = Question(label: "B", question: "Which format?", options: [QuestionOption(label: "v0.4.0(57)"),
                                                                                    QuestionOption(label: "57")],
                                  recommended: "57")
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [multiple, single]),
                                                actor: .claude(chatID: chat.id.uuidString))
            #expect(set.questions[0].options.map(\.label) == ["Status bar", "Window title", "About window"])
            #expect(set.questions[0].recommended == ["Status bar", "Window title"])
            #expect(set.questions[0].kind == .multiple && set.questions[0].maxChoices == 3)
            #expect(set.questions[1].kind == .single && set.questions[1].options.map(\.label) == ["57", "v0.4.0(57)"])
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            func answer(_ label: String, _ text: String) async throws {
                _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: set.questionSetID,
                                                                                 label: label, answer: text))
            }
            #expect(await engineError { try await answer("A", "Status bar") }
                == EngineError(.invalid, "answer: write one line \"- <choice>\" per choice, or Skipped."))
            #expect(await engineError { try await answer("A", "- Status bar\n- About window\n- Window title\n- Dock") }
                == EngineError(.invalid, "answer: the number of choices must be between minChoices and maxChoices."))
            try await answer("A", "Skipped")
            try await answer("A", "- Status bar\n- Window title\n- In the menu bar too")
            try await answer("B", "v0.4.0(57)")
            let process = try #require(await bed.launcher.chatProcess())
            let line = await process.line { $0.contains("Answers:") }
            #expect(line?.contains(#""text":"Answers:\nA:\n- Status bar\n- Window title\n- In the menu bar too\nB: v0.4.0(57)""#) == true)
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
            #expect(set.questions[0].recommended == ["Rust"])
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
            // The first message calls the internal skill implement-ticket (docs/chats.md › Implement and feedback chats).
            #expect(user.text == "/hephaestus-skills:implement-ticket DEMO-1")
            // Called by Claude, the first message's sender is Claude.
            let byClaude = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: .claude(chatID: chat.id.uuidString))
            #expect(await bed.waitForState(byClaude.id, .idle))
            guard case .user(let first)? = try await bed.transcript(byClaude.id).first else {
                Issue.record("no user item")
                return
            }
            #expect(first.sender == "Claude")

            // A review ticket counts as not done.
            try await bed.writeTicket(Ticket(id: "DEMO-3", title: "In review", status: .review, created: ISODate.now(), description: "Problem"))
            #expect(try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-3")).ticketID == "DEMO-3")
        }
    }

    @Test("The system prompt gives the project's type and the Go service rules, for a project of type None and of type Go service")
    func projectTypeInSystemPrompt() async throws {
        try await withChatEngine { bed in
            func systemPrompt(_ chat: ChatMeta, _ index: Int) async throws -> String {
                let process = try #require(await bed.launcher.chatProcess(index))
                #expect(process.request.arguments.contains(chat.id.uuidString))
                return try #require(process.request.arguments.firstIndex(of: "--append-system-prompt").map { process.request.arguments[$0 + 1] })
            }
            let none = try await bed.createChat(message: "Plan")
            let nonePrompt = try await systemPrompt(none, 0)
            #expect(nonePrompt.contains(" of the project. The project's type is None.\n\nThese rules apply in every chat. "))
            #expect(nonePrompt.contains("\n\n# Environments of a Go service\n\nWhen the project's type is Go service, its environments"))

            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", type: .goService))
            let go = try await bed.createChat(message: "Plan")
            let goPrompt = try await systemPrompt(go, 1)
            #expect(goPrompt.contains(" of the project. The project's type is Go service.\n\nThe project's environments, where the Go service runs; "
                + "the Kubernetes, Argo CD and API tools take an environment's name:\n- none: the user adds them in Project Settings\n\n"
                + "These rules apply in every chat. "))
            #expect(goPrompt.contains("\n\n# Environments of a Go service\n\nWhen the project's type is Go service, its environments"))
            #expect(!goPrompt.contains("{{"))
        }
    }

    @Test("The system prompt of a Go service chat lists the project's environments after its type, then its current working environment; a project of another type lists none")
    func environmentsInSystemPrompt() async throws {
        try await withChatEngine { bed in
            func systemPrompt(_ chat: ChatMeta, _ index: Int) async throws -> String {
                let process = try #require(await bed.launcher.chatProcess(index))
                #expect(process.request.arguments.contains(chat.id.uuidString))
                return try #require(process.request.arguments.firstIndex(of: "--append-system-prompt").map { process.request.arguments[$0 + 1] })
            }
            let header = "The project's environments, where the Go service runs; the Kubernetes, Argo CD and API tools take an environment's name:"
            let environments = [
                ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080),
                ProjectEnvironment(name: "staging", url: "https://staging.example.com/", namespace: "orders",
                                   deployment: "orders-api", argoCDApplication: "orders-staging", kubeconfig: "~/.kube/staging.yaml"),
            ]
            // The environments of a project of type None are kept, not listed.
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", environments: environments))
            let none = try await systemPrompt(try await bed.createChat(message: "Plan"), 0)
            #expect(none.contains("The project's type is None.\n\nThese rules apply in every chat."))
            #expect(!none.contains(header))

            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", type: .goService))
            let go = try await systemPrompt(try await bed.createChat(message: "Plan"), 1)
            let lines = "The project's type is Go service.\n\n\(header)\n- local: http://127.0.0.1:8080\n"
                + "- staging: https://staging.example.com; namespace: orders; deployment: orders-api; "
                + "Argo CD application: orders-staging; kubeconfig file: ~/.kube/staging.yaml\n"
            #expect(go.contains(lines + "The current working environment is local: use it when the user names no environment.\n\n"
                + "These rules apply in every chat."))
            #expect(!go.contains("{{"))

            // A chat started after a change of the current working environment names the new one.
            _ = try await bed.connection.call(ProjectsSetCurrentEnvironment.self, .init(projectID: "DEMO", environment: "staging"))
            let current = try await systemPrompt(try await bed.createChat(message: "Plan"), 2)
            #expect(current.contains(lines + "The current working environment is staging: use it when the user names no environment.\n\n"
                + "These rules apply in every chat."))

            // Without environments, the line is left out.
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", environments: []))
            let empty = try await systemPrompt(try await bed.createChat(message: "Plan"), 3)
            #expect(empty.contains("The project's type is Go service.\n\n\(header)\n- none: the user adds them in Project Settings\n\n"
                + "These rules apply in every chat."))
            #expect(!empty.contains("The current working environment"))
        }
    }

    @Test("The system prompt of a sub project's chat lists the environments it inherits, with its changes, before its own")
    func inheritedEnvironmentsInSystemPrompt() async throws {
        try await withChatEngine { bed in
            let header = "The project's environments, where the Go service runs; the Kubernetes, Argo CD and API tools take an environment's name:"
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", type: .goService, environments: [
                ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080),
                ProjectEnvironment(name: "staging", url: "https://staging.example.com", deployment: "orders-api"),
            ]))
            let root = bed.root.appendingPathComponent("worker").path
            _ = try await bed.connection.call(ProjectsCreate.self, .init(rootPath: root, name: "Worker", identifier: "WRK", parentID: "DEMO",
                                                                         type: .goService, createDirectory: true))
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environments: [
                ProjectEnvironment(name: "replay", url: "http://127.0.0.1", port: 9090),
            ], environmentOverrides: ["staging": EnvironmentOverride(deployment: "orders-worker")]))
            let chat = try await bed.connection.call(ChatsCreate.self, .init(projectID: "WRK", kind: .project,
                                                                             message: ChatMessageInput(text: "Plan")))
            let process = try #require(await bed.launcher.chatProcess(0))
            #expect(process.request.arguments.contains(chat.id.uuidString))
            let prompt = try #require(process.request.arguments.firstIndex(of: "--append-system-prompt").map { process.request.arguments[$0 + 1] })
            #expect(prompt.contains("The project's type is Go service.\n\n\(header)\n- local: http://127.0.0.1:8080\n"
                + "- staging: https://staging.example.com; deployment: orders-worker\n"
                + "- replay: http://127.0.0.1:9090\n"
                + "The current working environment is local: use it when the user names no environment.\n\nThese rules apply in every chat."))
        }
    }

    @Test("Implement All: the bundle chat and its message; a bundle without a ticket left is refused")
    func implementBundle() async throws {
        try await withChatEngine { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            try await bed.writeTicket(Ticket(id: "DEMO-2", title: "Two", status: .done, created: ISODate.now(), description: "Problem"))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B1", title: "Polish", created: ISODate.now(), ticketIDs: ["DEMO-1", "DEMO-2"]))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B2", title: "Finished", created: ISODate.now(), ticketIDs: ["DEMO-2"]))
            // A bundle file added with every ticket done is done (docs/tickets.md › Bundle status rules); set back to To Do, it is refused.
            _ = try await bed.connection.call(BundlesSetStatus.self, .init(bundleID: "DEMO-B2", status: "todo"))
            #expect(await engineError { try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B2")) }
                == EngineError(.conflict, "DEMO-B2 has no ticket left to implement."))
            let chat = try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1"))
            #expect(chat.bundleID == "DEMO-B1")
            #expect(try ProjectFileStore.readBundle(at: bed.folder.bundleFile("DEMO-B1"), projectID: "DEMO").chatIDs == [chat.id])
            let process = try #require(await bed.launcher.chatProcess())
            let prompt = try #require(process.request.arguments.firstIndex(of: "--append-system-prompt").map { process.request.arguments[$0 + 1] })
            #expect(prompt.contains("<bundle>\nID: DEMO-B1\nTitle: Polish\nTickets: DEMO-1, DEMO-2\n\nTicket 1 of 2:\nID: DEMO-1\n"))
            // The first message calls the internal skill implement-bundle (docs/chats.md › Implement and feedback chats).
            #expect(await process.line { $0.hasPrefix(#"{"type":"user""#) }?.contains(#"{"type":"text","text":"/hephaestus-skills:implement-bundle DEMO-B1"}"#) == true)

            // A review ticket counts as a ticket left to implement.
            try await bed.writeTicket(Ticket(id: "DEMO-3", title: "Three", status: .review, created: ISODate.now(), description: "Problem"))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B3", title: "Reviewed", created: ISODate.now(), ticketIDs: ["DEMO-2", "DEMO-3"]))
            #expect(try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B3")).bundleID == "DEMO-B3")
        }
    }

    @Test("Implement All and implement_bundle set the bundle to in_progress; an in_progress or done bundle is refused; the last ticket done sets it to done")
    func implementBundleStatus() async throws {
        try await withChatEngine { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            try await bed.writeTicket(Ticket(id: "DEMO-2", title: "Two", created: ISODate.now(), description: "Problem"))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B1", title: "Polish", created: ISODate.now(), ticketIDs: ["DEMO-1"]))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B2", title: "Docs", created: ISODate.now(), ticketIDs: ["DEMO-2"]))
            let chat = try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1"))
            let started = try ProjectFileStore.readBundle(at: bed.folder.bundleFile("DEMO-B1"), projectID: "DEMO")
            #expect(started.status == .inProgress && started.chatIDs == [chat.id])
            #expect(await engineError { try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1")) }
                == EngineError(.conflict, "DEMO-B1 is in progress; set it to To Do to implement it."))
            // implement_bundle: the same method with a claude actor.
            _ = try await bed.engine.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B2"), actor: .claude(chatID: chat.id.uuidString))
            #expect(try ProjectFileStore.readBundle(at: bed.folder.bundleFile("DEMO-B2"), projectID: "DEMO").status == .inProgress)
            // Every ticket done: the bundle is done (docs/tickets.md › Bundle status rules).
            _ = try await bed.connection.call(TicketsSetStatus.self, .init(ticketID: "DEMO-2", status: "done"))
            #expect(try await bed.connection.call(BundlesGet.self, .init(bundleID: "DEMO-B2")).status == .done)
            _ = try await bed.connection.call(BundlesSetStatus.self, .init(bundleID: "DEMO-B1", status: "done"))
            #expect(await engineError { try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1")) }
                == EngineError(.conflict, "DEMO-B1 is done; set it to To Do to implement it."))
            _ = try await bed.connection.call(BundlesSetStatus.self, .init(bundleID: "DEMO-B1", status: "todo"))
            #expect(try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1")).bundleID == "DEMO-B1")
        }
    }

    @Test("Orchestration: an orchestrated ticket chat takes the bundle chat's settings at the time of the call; other ticket chats take the defaults or the given settings")
    func orchestratedTicketChatSettings() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            // An orchestrated ticket chat needs a git repository for its branch and worktree.
            _ = try await ChatWorktreeTests.gitRepository(bed)
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            try await bed.writeTicket(Ticket(id: "DEMO-2", title: "Two", created: ISODate.now(), description: "Problem"))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B1", title: "Polish", created: ISODate.now(), ticketIDs: ["DEMO-1"]))
            let allowAll = ChatSettings(model: "sonnet", effort: .low, permissionMode: .bypassPermissions, ultracode: true)
            // Implement All with the settings chosen in the Implement sheet.
            let orchestrator = try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1", settings: allowAll))
            #expect(orchestrator.settings == allowAll)
            let claude = Actor.claude(chatID: orchestrator.id.uuidString)
            let first = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: claude)
            #expect(first.orchestratorChatID == orchestrator.id && first.settings == allowAll)
            #expect(try ProjectFileStore.readChatMeta(at: bed.folder.chatMetaFile(first.id), projectID: "DEMO").settings == allowAll)
            // A change of the bundle chat's settings applies to the ticket chats started afterwards.
            let acceptEdits = ChatSettings(model: "opus", effort: .max, permissionMode: .acceptEdits)
            _ = try await bed.connection.call(ChatsUpdateSettings.self, .init(chatID: orchestrator.id, settings: acceptEdits))
            let second = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: claude)
            #expect(second.settings == acceptEdits)
            #expect(try await bed.connection.call(ChatsGet.self, .init(chatID: first.id)).meta.settings == allowAll)
            // A ticket the bundle does not list takes the defaults; the user's Implement takes its settings.
            #expect(try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-2"), actor: claude).settings == ChatSettings())
            let plan = ChatSettings(permissionMode: .plan)
            #expect(try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1", settings: plan)).settings == plan)
            #expect(try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-2")).settings == ChatSettings())
        }
    }

    @Test("Orchestration: a bundle chat's implement_ticket starts a linked ticket chat whose turns report back, except on ask_questions")
    func orchestratedTicketChat() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            // An orchestrated ticket chat needs a git repository for its branch and worktree.
            _ = try await ChatWorktreeTests.gitRepository(bed)
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            try await bed.writeTicket(Ticket(id: "DEMO-2", title: "Two", created: ISODate.now(), description: "Problem"))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B1", title: "Polish", created: ISODate.now(), ticketIDs: ["DEMO-1"]))
            let orchestrator = try await bed.engine.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1"), actor: .claude(chatID: Actor.externalChatID))
            #expect(orchestrator.kind == .bundle && orchestrator.orchestratorChatID == nil)
            let claude = Actor.claude(chatID: orchestrator.id.uuidString)
            let chat = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: claude)
            #expect(chat.kind == .ticket && chat.ticketID == "DEMO-1" && chat.orchestratorChatID == orchestrator.id)
            let stored = try ProjectFileStore.readChatMeta(at: bed.folder.chatMetaFile(chat.id), projectID: "DEMO")
            #expect(stored.orchestratorChatID == orchestrator.id)
            #expect(try String(contentsOf: bed.folder.chatMetaFile(chat.id), encoding: .utf8).contains("\norchestrator: \(orchestrator.id.uuidString)\n"))
            #expect(try ProjectFileStore.readTicket(at: bed.folder.ticketFile("DEMO-1"), projectID: "DEMO").chatIDs == [chat.id])
            #expect(try ProjectFileStore.readBundle(at: bed.folder.bundleFile("DEMO-B1"), projectID: "DEMO").chatIDs == [orchestrator.id])
            let first = try await bed.transcript(chat.id).compactMap { item -> UserItem? in
                if case .user(let user) = item { return user }
                return nil
            }.first
            #expect(first?.text == "/hephaestus-skills:implement-ticket DEMO-1 DEMO-B1")
            #expect(first?.sender == "Claude")
            // A ticket the bundle does not list, or a call from another chat, is not orchestrated.
            #expect(try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-2"), actor: claude).orchestratorChatID == nil)
            #expect(try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1")).orchestratorChatID == nil)

            @Sendable func reports() async throws -> [UserItem] {
                try await bed.transcript(orchestrator.id).compactMap { item -> UserItem? in
                    if case .user(let user) = item, user.text.hasPrefix("Chat of ") { return user }
                    return nil
                }
            }
            let process = try #require(await launcher.chatProcess(1))
            // A turn that ends: the final reply.
            process.emit(FakeClaudeLauncher.initLine())
            for line in FakeClaudeLauncher.textReply(messageID: "msg_1", text: "Working on it.") { process.emit(line) }
            for line in FakeClaudeLauncher.textReply(messageID: "msg_2", text: "Implemented in abc1234.") { process.emit(line) }
            process.emit(FakeClaudeLauncher.resultLine())
            #expect(await eventually(timeout: waitLimit) { (try? await reports().count) == 1 })
            let report = try await reports()[0]
            #expect(report.text == "Chat of DEMO-1 finished its turn:\n\nImplemented in abc1234.")
            #expect(report.sender == (await bed.engine.deviceInfo.name))
            // A turn that ends on ask_questions sends nothing.
            try await bed.send(chat.id, "Go on")
            process.emit(FakeClaudeLauncher.initLine())
            let question = Question(label: "A", question: "Which?", options: [QuestionOption(label: "Yes"), QuestionOption(label: "No")],
                                    recommended: "Yes")
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]),
                                                actor: .claude(chatID: chat.id.uuidString))
            process.emit(FakeClaudeLauncher.resultLine())
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await Task.sleep(for: .milliseconds(200))
            #expect(try await reports().count == 1)
            // The turn after the answers ends in error.
            _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: set.questionSetID, label: "A", answer: "Yes"))
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_max_turns", errors: ["Too many turns."]))
            #expect(await eventually(timeout: waitLimit) { (try? await reports().count) == 2 })
            #expect(try await reports()[1].text == "Chat of DEMO-1 ended in error: Too many turns.")
            // A stopped turn.
            try await bed.send(chat.id, "Again")
            process.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(chat.id, .running))
            _ = try await bed.connection.call(ChatsInterrupt.self, .init(chatID: chat.id))
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_during_execution"))
            #expect(await eventually(timeout: waitLimit) { (try? await reports().count) == 3 })
            #expect(try await reports()[2].text == "Chat of DEMO-1 was stopped.")
        }
    }

    @Test("Feedback with added files: stored after the screenshot, images as image blocks, one Attachment line per file in order")
    func feedbackAttachments() async throws {
        try await withChatEngine { bed in
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
            let log = Data("Web tab 3 moved from index 2 to index 0\n".utf8)
            let context = FeedbackContext(appVersion: "0.4.0", build: 57, deviceName: "MacBook", mainDeviceName: "MacBook", projectID: "DEMO",
                                          section: .web)
            let chat = try await bed.connection.call(ChatsCreateFeedback.self, .init(
                projectID: "DEMO", comment: "The lock icon disappears.",
                screenshot: AttachmentUpload(name: "screenshot.png", contentType: "image/png", dataBase64: png.base64EncodedString()),
                context: context,
                attachments: [
                    AttachmentUpload(name: "web-tabs.log", contentType: "text/plain", dataBase64: log.base64EncodedString()),
                    AttachmentUpload(name: "tab-strip.jpg", contentType: "image/jpeg", dataBase64: jpeg.base64EncodedString()),
                ]))
            let process = try #require(await bed.launcher.chatProcess())
            let line = try #require(await process.line { $0.hasPrefix(#"{"type":"user""#) })
            #expect(await bed.waitForState(chat.id, .idle))
            guard case .user(let user)? = try await bed.transcript(chat.id).first else {
                Issue.record("no user item")
                return
            }
            // The attachments of the first message: the screenshot, then the files in the given order,
            // each stored as `chats/<chat id>/<uuid>-<name>`.
            #expect(user.attachments.map(\.name) == ["screenshot.png", "web-tabs.log", "tab-strip.jpg"])
            #expect(user.attachments.map(\.contentType) == ["image/png", "text/plain", "image/jpeg"])
            #expect(user.attachments.map(\.path) == user.attachments.map { "chats/\(chat.id.uuidString)/\($0.id.uuidString)-\($0.name)" })
            let paths = user.attachments.map { bed.folder.attachmentFile(path: $0.path).path }
            #expect(paths.map { FileManager.default.contents(atPath: $0) } == [png, log, jpeg])
            #expect(user.text == """
            /hephaestus-skills:feedback
            The lock icon disappears.

            Feedback context:
            - App: HephaestusV2 v0.4.0(57)
            - Device: MacBook
            - Project: Demo (DEMO)
            - Section: web
            - Screenshot: \(paths[0])
            - Attachment: \(paths[1])
            - Attachment: \(paths[2])
            """)
            // The image blocks of the screenshot and of the added image come before the text, in
            // attachment order; the text sent is the stored text, without an `Attached files:` list.
            let expected = ControlLines.userMessage(text: user.text, images: [
                ControlLines.Image(mediaType: "image/png", base64: png.base64EncodedString()),
                ControlLines.Image(mediaType: "image/jpeg", base64: jpeg.base64EncodedString()),
            ], uuid: user.id)
            #expect(line + "\n" == String(decoding: expected, as: UTF8.self))
            #expect(!line.contains("Attached files:"))
        }
    }

    @Test("Feedback with added files and no screenshot: the files are the attachments, and their lines follow the last context line")
    func feedbackAttachmentsWithoutScreenshot() async throws {
        try await withChatEngine { bed in
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            let log = Data("Web tab 3 moved from index 2 to index 0\n".utf8)
            let context = FeedbackContext(appVersion: "0.4.0", build: 57, deviceName: "MacBook", mainDeviceName: "MacBook", projectID: "DEMO",
                                          section: .web)
            let chat = try await bed.connection.call(ChatsCreateFeedback.self, .init(
                projectID: "DEMO", comment: "The lock icon disappears.", context: context,
                attachments: [
                    AttachmentUpload(name: "web-tabs.log", contentType: "text/plain", dataBase64: log.base64EncodedString()),
                    AttachmentUpload(name: "tab-strip.png", contentType: "image/png", dataBase64: png.base64EncodedString()),
                ]))
            let process = try #require(await bed.launcher.chatProcess())
            let line = try #require(await process.line { $0.hasPrefix(#"{"type":"user""#) })
            #expect(await bed.waitForState(chat.id, .idle))
            guard case .user(let user)? = try await bed.transcript(chat.id).first else {
                Issue.record("no user item")
                return
            }
            #expect(user.attachments.map(\.name) == ["web-tabs.log", "tab-strip.png"])
            let paths = user.attachments.map { bed.folder.attachmentFile(path: $0.path).path }
            #expect(user.text == """
            /hephaestus-skills:feedback
            The lock icon disappears.

            Feedback context:
            - App: HephaestusV2 v0.4.0(57)
            - Device: MacBook
            - Project: Demo (DEMO)
            - Section: web
            - Attachment: \(paths[0])
            - Attachment: \(paths[1])
            """)
            // The added image is the only image block; the text lists no file.
            let expected = ControlLines.userMessage(text: user.text, images: [
                ControlLines.Image(mediaType: "image/png", base64: png.base64EncodedString()),
            ], uuid: user.id)
            #expect(line + "\n" == String(decoding: expected, as: UTF8.self))
            // The chat's attachment folder holds the two files and no screenshot.
            let stored = try FileManager.default.contentsOfDirectory(atPath: bed.folder.chatAttachmentsFolder(chat.id).path)
            #expect(stored.count == 2 && !stored.contains { $0.hasSuffix("-screenshot.png") })
            // Without a screenshot the files alone are at most 20 MiB together.
            func file(_ name: String, bytes: Int) -> AttachmentUpload {
                AttachmentUpload(name: name, contentType: "", dataBase64: Data(count: bytes).base64EncodedString())
            }
            #expect(await engineError {
                try await bed.connection.call(ChatsCreateFeedback.self, .init(projectID: "DEMO", comment: "x", context: context, attachments: [
                    file("half.bin", bytes: AttachmentUploads.maximumSize / 2), file("other.bin", bytes: AttachmentUploads.maximumSize / 2 + 1),
                ]))
            } == EngineError(.invalid, "The attachments of one request exceed 20 MB."))
        }
    }

    @Test("Feedback with added files: sourcePath is forbidden, an invalid file is refused, and the screenshot and the files are at most 20 MiB together")
    func feedbackAttachmentLimits() async throws {
        try await withChatEngine { bed in
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            let context = FeedbackContext(appVersion: "0.4.0", build: 57, deviceName: "MacBook", mainDeviceName: "MacBook")
            @Sendable func feedback(_ attachments: [AttachmentUpload]) async throws -> ChatMeta {
                try await bed.connection.call(ChatsCreateFeedback.self, .init(
                    projectID: "DEMO", comment: "x",
                    screenshot: AttachmentUpload(name: "screenshot.png", contentType: "image/png", dataBase64: png.base64EncodedString()),
                    context: context, attachments: attachments))
            }
            func file(_ name: String, bytes: Int) -> AttachmentUpload {
                AttachmentUpload(name: name, contentType: "", dataBase64: Data(count: bytes).base64EncodedString())
            }
            #expect(await engineError { try await feedback([AttachmentUpload(name: "hosts", contentType: "", sourcePath: "/etc/hosts")]) }
                == EngineError(.forbidden, "sourcePath is accepted from Claude only."))
            #expect(await engineError { try await feedback([file("a.txt", bytes: 1), AttachmentUpload(name: "b.txt", contentType: "", dataBase64: "@@@")]) }?
                .code == .invalid)
            #expect(await engineError { try await feedback([AttachmentUpload(name: "c.txt", contentType: "")]) }?.code == .invalid)
            #expect(await engineError { try await feedback([file("big.bin", bytes: AttachmentUploads.maximumSize + 1)]) }
                == EngineError(.invalid, "big.bin is larger than 20 MB."))
            // The screenshot counts: with it, a file one byte under the limit exceeds 20 MiB.
            #expect(await engineError { try await feedback([file("rest.bin", bytes: AttachmentUploads.maximumSize - png.count + 1)]) }
                == EngineError(.invalid, "The attachments of one request exceed 20 MB."))
            #expect(await engineError { try await feedback([file("half.bin", bytes: AttachmentUploads.maximumSize / 2),
                                                             file("other.bin", bytes: AttachmentUploads.maximumSize / 2)]) }
                == EngineError(.invalid, "The attachments of one request exceed 20 MB."))
            // A refused request creates no chat and stores no file.
            #expect(try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO")).isEmpty)
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: bed.folder.chatsFolder.path)) ?? []).isEmpty)
            // Exactly 20 MiB together is accepted.
            let chat = try await feedback([file("rest.bin", bytes: AttachmentUploads.maximumSize - png.count)])
            guard case .user(let user)? = try await bed.transcript(chat.id).first else {
                Issue.record("no user item")
                return
            }
            #expect(user.attachments.map(\.size) == [png.count, AttachmentUploads.maximumSize - png.count])
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
            // The screenshot is the one file of the chat's attachment folder.
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([0x89, 0x50, 0x4E, 0x47]))
            #expect(try FileManager.default.contentsOfDirectory(atPath: bed.folder.chatAttachmentsFolder(chat.id).path).count == 1)
            // The image block comes before the text, which calls the internal skill feedback.
            #expect(line.range(of: #"{"type":"image""#)!.lowerBound < line.range(of: #"{"type":"text""#)!.lowerBound)
            #expect(user.text == """
            /hephaestus-skills:feedback
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
            // A feedback chat's system prompt is the common skill alone: the called skill feedback
            // describes the chat (docs/chats.md › Composition and rendering).
            #expect(prompt.hasPrefix("You are Claude, working inside HephaestusV2"))
            #expect(prompt.hasSuffix("wait for CI as hephaestus-skills:finish-implementation describes."))
            #expect(!prompt.contains("<feedback>") && !prompt.contains("This is a feedback chat") && !prompt.contains("# This chat"))
        }
    }

    @Test("Feedback without a screenshot: no file is stored, and the message has no image block and no Screenshot line")
    func feedbackWithoutScreenshot() async throws {
        try await withChatEngine { bed in
            let context = FeedbackContext(appVersion: "0.4.0", build: 57, deviceName: "MacBook", mainDeviceName: "MacBook", projectID: "DEMO",
                                          section: .tickets, item: "DEMO-1")
            let chat = try await bed.connection.call(ChatsCreateFeedback.self, .init(projectID: "DEMO", comment: "The list is empty.", context: context))
            #expect(chat.kind == .feedback)
            let process = try #require(await bed.launcher.chatProcess())
            let line = try #require(await process.line { $0.hasPrefix(#"{"type":"user""#) })
            #expect(!line.contains(#""type":"image""#))
            #expect(!line.contains("Screenshot:") && !line.contains("Attached files:"))
            #expect(await bed.waitForState(chat.id, .idle))
            guard case .user(let user)? = try await bed.transcript(chat.id).first else {
                Issue.record("no user item")
                return
            }
            #expect(user.attachments.isEmpty)
            #expect(user.text == """
            /hephaestus-skills:feedback
            The list is empty.

            Feedback context:
            - App: HephaestusV2 v0.4.0(57)
            - Device: MacBook
            - Project: Demo (DEMO)
            - Section: tickets
            - Item: DEMO-1
            """)
            // The chat's attachment folder holds no file.
            let stored = (try? FileManager.default.contentsOfDirectory(atPath: bed.folder.chatAttachmentsFolder(chat.id).path)) ?? []
            #expect(stored.isEmpty)
            // A null screenshot is an absent one, and the params of feedback without a screenshot
            // have no `screenshot` key (docs/engine-api.md › JSON encoding).
            let json = #"{"comment": "x", "context": {"appVersion": "0.4.0", "build": 57, "deviceName": "MacBook", "mainDeviceName": "MacBook"}, "#
                + #""projectID": "DEMO", "screenshot": null}"#
            let params = try EngineJSON.decode(ChatsCreateFeedback.Params.self, from: Data(json.utf8))
            #expect(params.screenshot == nil)
            #expect(!String(decoding: try EngineJSON.encode(params), as: UTF8.self).contains("screenshot"))
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
