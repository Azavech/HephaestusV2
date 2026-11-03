import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Notifications, › Summary call.
@Suite("Chat notifications")
struct ChatNotificationTests {
    typealias Payload = ChatNotificationEvent.Payload

    /// The `chat.notification` events of a chat, in emission order.
    static func notifications(_ bed: ChatTestBed, _ chatID: ChatID) async -> [Payload] {
        await bed.events.named(ChatNotificationEvent.name).compactMap { try? $0.payload(ChatNotificationEvent.self) }
            .filter { $0.chatID == chatID }
    }

    /// Waits for the notification of the chat with `kind` and `stage`.
    static func waitFor(_ bed: ChatTestBed, _ chatID: ChatID, _ kind: Payload.Kind, _ stage: Payload.Stage) async -> Payload? {
        await bed.events.wait(for: ChatNotificationEvent.name) { event in
            guard let payload = try? event.payload(ChatNotificationEvent.self) else { return false }
            return payload.chatID == chatID && payload.kind == kind && payload.stage == stage
        }.flatMap { try? $0.payload(ChatNotificationEvent.self) }
    }

    /// The `<input>` of every summary call the launcher started.
    static func summaryInputs(_ launcher: FakeClaudeLauncher) -> [String] {
        let prompt = Prompts.text(.notificationSummary)
        return launcher.started.compactMap { process in
            let arguments = process.arguments
            guard let index = arguments.firstIndex(of: "--system-prompt"), index + 1 < arguments.count,
                  arguments[index + 1] == prompt else { return nil }
            return arguments.last
        }
    }

    /// A chat process that answers `initialize` and, for each user message, opens a CLI turn,
    /// writes `reply` and then sends `can_use_tool` for Bash `rm -rf build`.
    static func permissionChat(reply: String) -> @Sendable (FakeClaudeProcess) -> Void {
        { process in
            FakeClaudeLauncher.silentChat()(process)
            let previous = process.onLine
            process.onLine = { process, line in
                previous?(process, line)
                guard line.hasPrefix(#"{"type":"user""#) else { return }
                process.emit(FakeClaudeLauncher.initLine())
                for output in FakeClaudeLauncher.textReply(messageID: "msg_1", text: reply) { process.emit(output) }
                process.emit(#"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"description":"Clean","command":"rm -rf build"}}}"#)
            }
        }
    }

    // MARK: Events

    @Test("A turn that ends in idle posts finished: the first line of the reply at once, then Haiku's summary of the reply")
    func finishedTurn() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.replyingChat(reply: "\n  Fixed the crash at launch.  \nThen I pushed it.")
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Fix the crash")
            let summary = try #require(await Self.waitFor(bed, chat.id, .finished, .summary))
            #expect(summary.detail == "Plan the sprint" && summary.projectID == "DEMO")
            let all = await Self.notifications(bed, chat.id)
            #expect(all.map(\.stage) == [.immediate, .summary])
            #expect(all.first?.detail == "Fixed the crash at launch.")
            #expect(Self.summaryInputs(launcher) == ["Claude's reply:\n\n  Fixed the crash at launch.  \nThen I pushed it."])
            let event = try #require(await bed.events.named(ChatNotificationEvent.name).first)
            #expect(event.origin == .system)
        }
    }

    @Test("A permission request posts needs you with the tool and its input; the turn's reply is the fallback detail")
    func permissionRequest() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.permissionChat(reply: "I'll clean the build folder.")
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Clean")
            #expect(await bed.waitForState(chat.id, .waitingPermission))
            let summary = try #require(await Self.waitFor(bed, chat.id, .needsYou, .summary))
            #expect(summary.detail == "Plan the sprint")
            let immediate = await Self.notifications(bed, chat.id).first
            #expect(immediate == Payload(chatID: chat.id, projectID: "DEMO", kind: .needsYou, stage: .immediate,
                                         detail: "I'll clean the build folder."))
            #expect(Self.summaryInputs(launcher)
                == [#"Permission request:\#nTool: Bash\#nInput: {"command":"rm -rf build","description":"Clean"}"#])
        }
    }

    @Test("Questions post needs you with their texts, and the turn that ends with them posts no finished")
    func questions() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Plan")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            let options = [QuestionOption(label: "Yes"), QuestionOption(label: "No")]
            _ = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [
                Question(label: "A", question: "Keep the tab open?", options: options, recommended: "Yes"),
                Question(label: "B", question: "Beep?", options: options, recommended: "No"),
            ]), actor: .claude(chatID: chat.id.uuidString))
            process.emit(FakeClaudeLauncher.resultLine())
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            #expect(await Self.waitFor(bed, chat.id, .needsYou, .summary) != nil)
            let all = await Self.notifications(bed, chat.id)
            #expect(all.map(\.kind) == [.needsYou, .needsYou])
            #expect(all.first?.detail == "Waiting for your answers")
            #expect(Self.summaryInputs(launcher) == ["Questions:\nA: Keep the tab open?\nB: Beep?"])
        }
    }

    @Test("A symbol request posts needs you with its question")
    func symbolRequest() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Plan")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            _ = try await SymbolRequestTests.post(bed, chat.id, question: "Which icon for the tab?", suggestions: ["star", "heart"],
                                                  recommended: "star")
            process.emit(FakeClaudeLauncher.resultLine())
            #expect(await Self.waitFor(bed, chat.id, .needsYou, .summary) != nil)
            #expect(await Self.notifications(bed, chat.id).map(\.kind) == [.needsYou, .needsYou])
            #expect(Self.summaryInputs(launcher) == ["Symbol request:\nWhich icon for the tab?"])
        }
    }

    @Test("A turn stopped with Stop posts no finished; error posts nothing")
    func stoppedAndError() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Long work")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(chat.id, .running))
            _ = try await bed.connection.call(ChatsInterrupt.self, .init(chatID: chat.id))
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_during_execution"))
            #expect(await bed.waitForState(chat.id, .idle))
            // A turn that ends in error.
            try await bed.send(chat.id, "Again")
            process.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(chat.id, .running))
            process.exit(.exited(1))
            #expect(await bed.waitForState(chat.id, .error))
            try await Task.sleep(for: .milliseconds(200))
            #expect(await Self.notifications(bed, chat.id).isEmpty)
        }
    }

    @Test("Implement All: no finished for the ticket chats, nor for the bundle chat while one works; finished at the end")
    func orchestration() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            // An orchestrated ticket chat needs a git repository for its branch and worktree.
            _ = try await ChatWorktreeTests.gitRepository(bed)
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B1", title: "Polish", created: ISODate.now(), ticketIDs: ["DEMO-1"]))
            let bundleChat = try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1"))
            let bundleProcess = try #require(await launcher.chatProcess(0))
            bundleProcess.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(bundleChat.id, .running))
            let ticketChat = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"),
                                                       actor: .claude(chatID: bundleChat.id.uuidString))
            bundleProcess.emit(FakeClaudeLauncher.resultLine())
            #expect(await bed.waitForState(bundleChat.id, .idle))
            // The ticket chat's turn ends; its report starts a turn of the bundle chat.
            let ticketProcess = try #require(await launcher.chatProcess(1))
            ticketProcess.emit(FakeClaudeLauncher.initLine())
            for line in FakeClaudeLauncher.textReply(messageID: "msg_1", text: "Implemented in abc1234.") { ticketProcess.emit(line) }
            ticketProcess.emit(FakeClaudeLauncher.resultLine())
            #expect(await bed.waitForState(ticketChat.id, .idle))
            #expect(await bed.waitForState(bundleChat.id, .running))
            #expect(await Self.notifications(bed, bundleChat.id).isEmpty)
            bundleProcess.emit(FakeClaudeLauncher.initLine())
            bundleProcess.emit(FakeClaudeLauncher.resultLine())
            let summary = try #require(await Self.waitFor(bed, bundleChat.id, .finished, .summary))
            // No reply text: no summary call, the fallback detail at both stages.
            #expect(summary.detail == "Claude finished replying")
            #expect(await Self.notifications(bed, bundleChat.id).map(\.stage) == [.immediate, .summary])
            #expect(await Self.notifications(bed, ticketChat.id).isEmpty)
            #expect(Self.summaryInputs(launcher).isEmpty)
        }
    }

    @Test("The summary of needs you is dropped when the chat no longer waits, or when a newer event of the chat came")
    func droppedSummary() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.permissionChat(reply: "Cleaning.")
        let summarizer = GatedSummarizer()
        try await withChatEngine(launcher: launcher) { bed in
            await bed.engine.useNotificationSummarizer(summarizer)
            let chat = try await bed.createChat(message: "Clean")
            #expect(await Self.waitFor(bed, chat.id, .needsYou, .immediate) != nil)
            _ = try await bed.connection.call(ChatsAnswerPermission.self, .init(chatID: chat.id, requestID: "p1", decision: .allow))
            #expect(await bed.waitForState(chat.id, .running))
            summarizer.open()
            #expect(await eventually(timeout: waitLimit) { summarizer.answered == 1 })
            try await Task.sleep(for: .milliseconds(200))
            #expect(await Self.notifications(bed, chat.id).map(\.stage) == [.immediate])
            // A finished event while its summary waits, then another one: only the newest summary.
            summarizer.close()
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.resultLine())
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(await Self.waitFor(bed, chat.id, .finished, .immediate) != nil)
            try await bed.send(chat.id, "Again")
            #expect(await bed.waitForState(chat.id, .waitingPermission))
            #expect(await Self.waitFor(bed, chat.id, .needsYou, .immediate).map { _ in true } == true)
            summarizer.open()
            #expect(await Self.waitFor(bed, chat.id, .needsYou, .summary)?.detail == "Summary")
            try await Task.sleep(for: .milliseconds(200))
            #expect(await Self.notifications(bed, chat.id).filter { $0.kind == .finished }.map(\.stage) == [.immediate])
        }
    }

    @Test("The waiting states the engine computes at launch post nothing")
    func launchStates() async throws {
        let chatID = UUID()
        let setID = UUID()
        try await withChatEngine(prepare: { folder, _ in
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), sessionStarted: true), to: folder)
            let questions = QuestionsItem(id: setID.uuidString, created: ISODate.now(), questionSetID: setID, questions: [
                Question(label: "A", question: "?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")], recommended: "x"),
            ])
            try JSONLinesWriter().append(TranscriptLine(op: .add, item: .questions(questions)), to: folder.transcriptFile(chatID))
        }) { bed in
            #expect(await bed.waitForState(chatID, .waitingAnswers))
            try await Task.sleep(for: .milliseconds(200))
            #expect(await Self.notifications(bed, chatID).isEmpty)
        }
    }

    // MARK: Detail and summary call

    @Test("Fallback detail: the first line of the reply that is not empty, trimmed, cut to 200 characters, else the state text")
    func fallbackDetail() {
        #expect(NotificationDetail.fallback(reply: "\n \n  Done: tests pass.  \nMore", kind: .finished, state: .idle) == "Done: tests pass.")
        let long = String(repeating: "a", count: 250)
        #expect(NotificationDetail.fallback(reply: long, kind: .finished, state: .idle) == String(repeating: "a", count: 200))
        #expect(NotificationDetail.fallback(reply: nil, kind: .finished, state: .idle) == "Claude finished replying")
        #expect(NotificationDetail.fallback(reply: " \n", kind: .finished, state: .idle) == "Claude finished replying")
        #expect(NotificationDetail.fallback(reply: nil, kind: .needsYou, state: .waitingPermission) == "Waiting for your permission")
        #expect(NotificationDetail.fallback(reply: nil, kind: .needsYou, state: .waitingAnswers) == "Waiting for your answers")
    }

    @Test("Summary input per event: the label line, then the text cut at 4,000 characters")
    func summaryInput() {
        #expect(HaikuNotificationSummarizer.input(for: .reply("Done.")) == "Claude's reply:\nDone.")
        #expect(HaikuNotificationSummarizer.input(for: .permission(toolName: "Edit", input: .object(["file_path": .string("/a/b"), "a": .int(1)])))
            == #"Permission request:\#nTool: Edit\#nInput: {"a":1,"file_path":"/a/b"}"#)
        let options = [QuestionOption(label: "x"), QuestionOption(label: "y")]
        #expect(HaikuNotificationSummarizer.input(for: .questions([
            Question(label: "B", question: "Second?", options: options, recommended: "x"),
            Question(label: "A", question: "First?", options: options, recommended: "x"),
        ])) == "Questions:\nA: First?\nB: Second?")
        #expect(HaikuNotificationSummarizer.input(for: .symbol(question: "Which icon?")) == "Symbol request:\nWhich icon?")
        #expect(HaikuNotificationSummarizer.input(for: .reply(String(repeating: "x", count: 5_000))).count == "Claude's reply:\n".count + 4_000)
    }

    @Test("Summary cleanup: one line, no Summary: prefix, no quotes, at most 150 characters cut at a space")
    func summaryCleanup() {
        #expect(HaikuNotificationSummarizer.cleanSummary("  Summary:  \"Fixed the crash\n and pushed.\"  ") == "Fixed the crash and pushed.")
        #expect(HaikuNotificationSummarizer.cleanSummary(" “ ” ") == nil)
        let words = Array(repeating: "word", count: 40).joined(separator: " ")
        let cut = HaikuNotificationSummarizer.cleanSummary(words)
        #expect(cut?.count == 149 && cut?.hasSuffix("word") == true)
        #expect(HaikuNotificationSummarizer.cleanSummary(String(repeating: "x", count: 160))?.count == 150)
        let output = Data(#"{"type":"result","is_error":false,"result":"Wants to run swift test."}"#.utf8)
        #expect(HaikuNotificationSummarizer.summary(fromOutput: output).summary == "Wants to run swift test.")
        #expect(HaikuNotificationSummarizer.summary(fromOutput: Data(#"{"is_error":true,"result":"x"}"#.utf8)).summary == nil)
        #expect(HaikuNotificationSummarizer.summary(fromOutput: Data("not json".utf8)).summary == nil)
    }

    @Test("The three notification settings are true by default and round-trip through settings.yml and settings.update")
    func settingsKeys() async throws {
        let defaults = try YAMLCoding.decode(HostSettings.self, from: "schema: 1\n")
        #expect(defaults.notifyNeedsYou && defaults.notifyFinished && defaults.notifyAISummary)
        let off = HostSettings(notifyNeedsYou: false, notifyFinished: false, notifyAISummary: false)
        let yaml = try YAMLCoding.encode(off)
        #expect(yaml.contains("notifyNeedsYou: false\nnotifyFinished: false\nnotifyAISummary: false\n"))
        #expect(try YAMLCoding.decode(HostSettings.self, from: yaml) == off)
        try await withChatEngine { bed in
            let updated = try await bed.connection.call(SettingsUpdate.self, .init(notifyFinished: false, notifyAISummary: false))
            #expect(updated.notifyNeedsYou && !updated.notifyFinished && !updated.notifyAISummary)
            let stored = try ProjectFileStore.decodeYAML(HostSettings.self, at: bed.dataDirectory.settingsFile)
            #expect(stored == updated)
        }
    }
}

/// A summarizer that answers `Summary` once its gate is open.
final class GatedSummarizer: NotificationSummarizer, @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var count = 0

    var answered: Int { lock.withLock { count } }

    func open() { lock.withLock { isOpen = true } }
    func close() { lock.withLock { isOpen = false } }

    func summary(for subject: NotificationSubject) async -> String? {
        while !lock.withLock({ isOpen }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        lock.withLock { count += 1 }
        return "Summary"
    }
}

extension Engine {
    /// Replaces the summarizer of chat notifications.
    func useNotificationSummarizer(_ summarizer: any NotificationSummarizer) {
        notificationSummarizer = summarizer
    }
}
