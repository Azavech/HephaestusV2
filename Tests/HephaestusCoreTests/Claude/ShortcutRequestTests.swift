import Foundation
import Testing
@testable import HephaestusCore

/// Shortcut requests: the project type, the rules of `chats.postShortcut`, one waiting request per
/// chat, the state and the answer message (docs/chats.md › Shortcut requests, docs/workflow.md ›
/// Shortcut requests).
@Suite("Shortcut requests")
struct ShortcutRequestTests {
    static func post(_ bed: ChatTestBed, _ chatID: ChatID, question: String = "Which shortcut?", suggestions: [String],
                     recommended: String, inUse: [ShortcutInUse] = [], actor: Actor? = nil) async throws -> ShortcutRequest {
        try await bed.engine.call(ChatsPostShortcut.self, .init(chatID: chatID, question: question, suggestions: suggestions,
                                                                recommended: recommended, inUse: inUse),
                                  actor: actor ?? .claude(chatID: chatID.uuidString))
    }

    static func shortcutItems(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> [ShortcutItem] {
        try await bed.transcript(chatID).compactMap { item -> ShortcutItem? in
            if case .shortcut(let request) = item { return request }
            return nil
        }
    }

    /// Gives the test project the type Swift application.
    static func makeSwiftApplication(_ bed: ChatTestBed, _ type: ProjectType = .swiftApplication) async throws {
        _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", type: type))
    }

    static let refusedNotation = "is not a shortcut in menu notation: the modifiers ⌃⌥⇧⌘ in this order, then one key."

    @Test("ask_shortcut only in a Swift application project, by the chat's own Claude; nothing is posted otherwise")
    func projectTypeAndActor() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            func refusal(actor: Actor? = nil, suggestions: [String] = ["⇧⌘K", "⌘K"]) async -> EngineError? {
                await engineError { try await Self.post(bed, chat.id, suggestions: suggestions, recommended: "⇧⌘K", actor: actor) }
            }
            let projectType = EngineError(.forbidden, "ask_shortcut is available only in Swift application projects.")
            #expect(await refusal() == projectType)
            // The project type is checked before the rules.
            #expect(await refusal(suggestions: ["⌘⇧K"]) == projectType)
            try await Self.makeSwiftApplication(bed, .goService)
            #expect(await refusal() == projectType)
            #expect(try await Self.shortcutItems(bed, chat.id).isEmpty)
            #expect(await bed.state(chat.id) == .idle)

            try await Self.makeSwiftApplication(bed)
            #expect(await refusal(actor: .claude(chatID: Actor.externalChatID))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(actor: .claude(chatID: UUID().uuidString))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await engineError {
                try await bed.connection.call(ChatsPostShortcut.self, .init(chatID: chat.id, question: "Which?", suggestions: ["⌘K", "⌘L"],
                                                                            recommended: "⌘K", inUse: []))
            }?.code == .forbidden)
            _ = try await Self.post(bed, chat.id, suggestions: ["⇧⌘K", "⌘K"], recommended: "⇧⌘K")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
        }
    }

    @Test("ask_shortcut validation: question, 2 to 10 distinct suggestions in menu notation, recommended, inUse entries")
    func validation() async throws {
        try await withChatEngine { bed in
            try await Self.makeSwiftApplication(bed)
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            func refusal(question: String = "Which shortcut?", _ suggestions: [String], _ recommended: String,
                         inUse: [ShortcutInUse] = []) async -> EngineError? {
                await engineError {
                    try await Self.post(bed, chat.id, question: question, suggestions: suggestions, recommended: recommended, inUse: inUse)
                }
            }
            func use(_ shortcut: String, _ command: String) -> ShortcutInUse { ShortcutInUse(shortcut: shortcut, command: command) }
            #expect(await refusal(question: " \n ", ["⌘K", "⌘L"], "⌘K") == EngineError(.invalid, "ask_shortcut needs a question."))
            #expect(await refusal(["⌘K"], "⌘K") == EngineError(.invalid, "ask_shortcut needs 2 to 10 suggestions."))
            let eleven = ["⌘A", "⌘B", "⌘C", "⌘D", "⌘E", "⌘F", "⌘G", "⌘H", "⌘I", "⌘J", "⌘K"]
            #expect(await refusal(eleven, "⌘A") == EngineError(.invalid, "ask_shortcut needs 2 to 10 suggestions."))
            #expect(await refusal(["⌘K", " ⌘K "], "⌘K") == EngineError(.invalid, "ask_shortcut has an empty or repeated suggestion."))
            #expect(await refusal(["⌘K", "  "], "⌘K") == EngineError(.invalid, "ask_shortcut has an empty or repeated suggestion."))
            // The modifier order, a lowercase letter, two keys; the first wrong suggestion is named.
            #expect(await refusal(["⌘K", "⌘⇧K", "⌘k"], "⌘K") == EngineError(.invalid, "⌘⇧K \(Self.refusedNotation)"))
            #expect(await refusal(["⌘k", "⌘K"], "⌘K") == EngineError(.invalid, "⌘k \(Self.refusedNotation)"))
            #expect(await refusal(["⌘KL", "⌘K"], "⌘K") == EngineError(.invalid, "⌘KL \(Self.refusedNotation)"))
            #expect(await refusal(["⌘K", "⌘L"], "⌘M")
                == EngineError(.invalid, "ask_shortcut: the recommended shortcut must be one of the suggestions."))
            let many = (0..<501).map { use("F\($0 % 20 + 1)", "Command \($0)") }
            #expect(await refusal(["⌘K", "⌘L"], "⌘K", inUse: many) == EngineError(.invalid, "ask_shortcut accepts at most 500 inUse entries."))
            #expect(await refusal(["⌘K", "⌘L"], "⌘K", inUse: [use("⌘N", "New"), use("⌘⌥N", "Other")])
                == EngineError(.invalid, "⌘⌥N \(Self.refusedNotation)"))
            #expect(await refusal(["⌘K", "⌘L"], "⌘K", inUse: [use("⌘N", "  ")])
                == EngineError(.invalid, "ask_shortcut: the command of ⌘N in inUse must be one line of 1 to 200 characters."))
            #expect(await refusal(["⌘K", "⌘L"], "⌘K", inUse: [use("⌘N", "New\nTicket")])
                == EngineError(.invalid, "ask_shortcut: the command of ⌘N in inUse must be one line of 1 to 200 characters."))
            #expect(await refusal(["⌘K", "⌘L"], "⌘K", inUse: [use("⌘N", String(repeating: "x", count: 201))])
                == EngineError(.invalid, "ask_shortcut: the command of ⌘N in inUse must be one line of 1 to 200 characters."))
            #expect(await refusal(["⌘K", "⌘L"], "⌘K", inUse: [use("⌘N", "New Ticket"), use(" ⌘N", "New Bundle")])
                == EngineError(.invalid, "ask_shortcut: ⌘N appears twice in inUse."))
            #expect(try await Self.shortcutItems(bed, chat.id).isEmpty)
            #expect(await bed.state(chat.id) == .idle)

            // Every kind of key, with or without modifiers, trimmed and kept in Claude's order.
            let suggestions = ["⎋", "⌃⌥⇧⌘F20", "⌘↩", "⌃Space", "⌥⌫", "⌘←", "⇧⌘/", "1", " ⇧⌘K ", "⌦"]
            let request = try await Self.post(bed, chat.id, suggestions: suggestions, recommended: " ⇧⌘K",
                                              inUse: [use(" ⌘N ", " New Ticket "), use("⇧⌘K", "Commit")])
            #expect(request.suggestions == suggestions.map { $0.trimmingCharacters(in: .whitespaces) })
            #expect(request.recommended == "⇧⌘K" && request.answer == nil && request.chatID == chat.id)
            #expect(request.inUse == [use("⌘N", "New Ticket"), use("⇧⌘K", "Commit")])
            let stored = try #require(try await Self.shortcutItems(bed, chat.id).first)
            #expect(stored.requestID == request.requestID && stored.id == request.requestID.uuidString)
            #expect(stored.suggestions == request.suggestions && stored.inUse == request.inUse && stored.answer == nil)
        }
    }

    @Test("One waiting request per chat: ask_shortcut while questions, a symbol, a color or a sound request wait; the others while a shortcut request waits")
    func conflicts() async throws {
        try await SoundRequestTests.withSoundEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let claude = Actor.claude(chatID: chat.id.uuidString)
            let question = Question(label: "A", question: "Which?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")],
                                    recommended: "x")
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘K") }
                == EngineError(.conflict, "Questions are already waiting for answers in this chat."))
            _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: set.questionSetID,
                                                                             label: "A", answer: "x"))
            #expect(await bed.waitForState(chat.id, .idle))

            let symbol = try await SymbolRequestTests.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star")
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘K") }
                == EngineError(.conflict, "A symbol request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerSymbol.self, .init(chatID: chat.id, requestID: symbol.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let colors: [ColorValue] = [.color("red"), .color("blue")]
            let color = try await ColorRequestTests.post(bed, chat.id, suggestions: colors, recommended: .color("red"))
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘K") }
                == EngineError(.conflict, "A color request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerColor.self, .init(chatID: chat.id, requestID: color.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let sounds = [SoundRequestTests.glass, SoundRequestTests.sms]
            let sound = try await SoundRequestTests.post(bed, chat.id, suggestions: sounds, recommended: SoundRequestTests.glass)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘K") }
                == EngineError(.conflict, "A sound request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerSound.self, .init(chatID: chat.id, requestID: sound.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            _ = try await Self.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘K")
            let waiting = EngineError(.conflict, "A shortcut request is already waiting for an answer in this chat.")
            #expect(await engineError {
                try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            } == waiting)
            #expect(await engineError { try await SymbolRequestTests.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star") }
                == waiting)
            #expect(await engineError { try await ColorRequestTests.post(bed, chat.id, suggestions: colors, recommended: .color("blue")) }
                == waiting)
            #expect(await engineError { try await SoundRequestTests.post(bed, chat.id, suggestions: sounds, recommended: SoundRequestTests.sms) }
                == waiting)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘L") } == waiting)
            #expect(try await Self.shortcutItems(bed, chat.id).count == 1)
        }
    }

    @Test("waitingAnswers until the answer; Shortcut: ![](shortcut:<shortcut>), Shortcut: <text> and Shortcut: Skipped are sent to Claude")
    func answers() async throws {
        try await withChatEngine { bed in
            try await Self.makeSwiftApplication(bed)
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let process = try #require(await bed.launcher.chatProcess())
            func answer(_ request: ShortcutRequest, _ text: String) async throws {
                _ = try await bed.connection.call(ChatsAnswerShortcut.self, .init(chatID: chat.id, requestID: request.requestID, answer: text))
            }

            // A chosen shortcut, even one that macOS uses.
            let first = try await Self.post(bed, chat.id, suggestions: ["⇧⌘K", "⌘Space"], recommended: "⇧⌘K")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            #expect(await engineError { try await answer(first, "   ") } == EngineError(.invalid, "answer: use 1 to 10,000 characters."))
            #expect(await engineError {
                try await bed.connection.call(ChatsAnswerShortcut.self, .init(chatID: chat.id, requestID: UUID(), answer: "x"))
            }?.code == .notFound)
            #expect(await bed.state(chat.id) == .waitingAnswers)
            try await answer(first, " ![](shortcut:⌘Space) ")
            let chosen = await process.line { $0.contains("Shortcut: ") }
            #expect(chosen?.contains(#""text":"Shortcut: ![](shortcut:⌘Space)""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await Self.shortcutItems(bed, chat.id).first?.answer == "![](shortcut:⌘Space)")
            #expect(await engineError { try await answer(first, "x") } == EngineError(.conflict, "This shortcut request was already answered."))
            let user = try await bed.transcript(chat.id).compactMap { item -> UserItem? in
                if case .user(let user) = item, user.text.hasPrefix("Shortcut: ") { return user }
                return nil
            }.last
            #expect(user?.text == "Shortcut: ![](shortcut:⌘Space)")

            // An answer in the user's own words keeps its line breaks.
            let second = try await Self.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘K")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(second, "Whatever Xcode uses\nfor this")
            let typed = await process.line { $0.contains("Shortcut: Whatever Xcode") }
            #expect(typed?.contains(#""text":"Shortcut: Whatever Xcode uses\nfor this""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))

            // Skip.
            let third = try await Self.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘L")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(third, "Skipped")
            let skipped = await process.line { $0.contains("Shortcut: Skipped") }
            #expect(skipped?.contains(#""text":"Shortcut: Skipped""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await Self.shortcutItems(bed, chat.id).map(\.answer)
                == ["![](shortcut:⌘Space)", "Whatever Xcode uses\nfor this", "Skipped"])
        }
    }

    @Test("At startup a shortcut request without answer gives waitingAnswers")
    func startupScan() async throws {
        let chatID = UUID()
        let requestID = UUID()
        try await withChatEngine(prepare: { folder, _ in
            var project = try ProjectFileStore.readProject(folder)
            project.type = .swiftApplication
            try ProjectFileStore.write(project, to: folder)
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), sessionStarted: true), to: folder)
            let request = ShortcutItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: "Which?",
                                       suggestions: ["⌘K", "⌘L"], recommended: "⌘K", inUse: [])
            try JSONLinesWriter().append(TranscriptLine(op: .add, item: .shortcut(request)), to: folder.transcriptFile(chatID))
        }) { bed in
            #expect(await bed.waitForState(chatID, .waitingAnswers))
            #expect(await engineError { try await Self.post(bed, chatID, suggestions: ["⌘K", "⌘L"], recommended: "⌘K") }
                == EngineError(.conflict, "A shortcut request is already waiting for an answer in this chat."))
        }
    }
}
