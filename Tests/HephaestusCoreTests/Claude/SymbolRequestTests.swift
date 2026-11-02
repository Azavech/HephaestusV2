import Foundation
import Testing
@testable import HephaestusCore

/// Symbol requests: the rules of `chats.postSymbol`, one waiting request per chat, the state and
/// the answer message (docs/chats.md › Symbol requests, docs/workflow.md › Symbol requests).
@Suite("Symbol requests")
struct SymbolRequestTests {
    static func post(_ bed: ChatTestBed, _ chatID: ChatID, question: String = "Which icon?", suggestions: [String],
                     recommended: String, actor: Actor? = nil) async throws -> SymbolRequest {
        try await bed.engine.call(ChatsPostSymbol.self, .init(chatID: chatID, question: question, suggestions: suggestions,
                                                              recommended: recommended),
                                  actor: actor ?? .claude(chatID: chatID.uuidString))
    }

    static func symbolItems(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> [SymbolItem] {
        try await bed.transcript(chatID).compactMap { item -> SymbolItem? in
            if case .symbol(let request) = item { return request }
            return nil
        }
    }

    @Test("ask_symbol validation: a question, 2 to 10 known and distinct suggestions, recommended one of them, the chat's own Claude")
    func validation() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            func refusal(question: String = "Which icon?", _ suggestions: [String], _ recommended: String,
                         actor: Actor? = nil) async -> EngineError? {
                await engineError {
                    try await Self.post(bed, chat.id, question: question, suggestions: suggestions, recommended: recommended, actor: actor)
                }
            }
            #expect(await refusal(["star", "heart"], "star", actor: .claude(chatID: Actor.externalChatID))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(["star", "heart"], "star", actor: .claude(chatID: UUID().uuidString))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(question: " \n ", ["star", "heart"], "star") == EngineError(.invalid, "ask_symbol needs a question."))
            #expect(await refusal(["star"], "star") == EngineError(.invalid, "ask_symbol needs 2 to 10 suggestions."))
            let eleven = ["star", "heart", "circle", "square", "trash", "folder", "doc", "gear", "bell", "flag", "house"]
            #expect(await refusal(eleven, "star") == EngineError(.invalid, "ask_symbol needs 2 to 10 suggestions."))
            #expect(await refusal(["star", " star "], "star") == EngineError(.invalid, "ask_symbol has an empty or repeated suggestion."))
            #expect(await refusal(["star", "  "], "star") == EngineError(.invalid, "ask_symbol has an empty or repeated suggestion."))
            #expect(await refusal(["star", "no.such.symbol", "also.unknown"], "star")
                == EngineError(.invalid, "no.such.symbol is not an SF Symbol of this Mac."))
            #expect(await refusal(["star", "heart"], "circle")
                == EngineError(.invalid, "ask_symbol: the recommended symbol must be one of the suggestions."))
            #expect(try await Self.symbolItems(bed, chat.id).isEmpty)
            #expect(await bed.state(chat.id) == .idle)

            // Ten suggestions, trimmed, kept in Claude's order.
            let ten = Array(eleven.prefix(10))
            let request = try await Self.post(bed, chat.id, suggestions: [" heart "] + ten.dropFirst(2) + ["star"], recommended: " star ")
            #expect(request.suggestions == ["heart"] + ten.dropFirst(2) + ["star"])
            #expect(request.recommended == "star" && request.answer == nil && request.chatID == chat.id)
            let stored = try #require(try await Self.symbolItems(bed, chat.id).first)
            #expect(stored.requestID == request.requestID && stored.id == request.requestID.uuidString)
            #expect(stored.suggestions == request.suggestions && stored.answer == nil)
        }
    }

    @Test("One waiting request per chat: ask_symbol while questions wait, ask_questions and ask_symbol while a symbol request waits")
    func conflicts() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let claude = Actor.claude(chatID: chat.id.uuidString)
            let question = Question(label: "A", question: "Which?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")],
                                    recommended: "x")
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star") }
                == EngineError(.conflict, "Questions are already waiting for answers in this chat."))
            _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: set.questionSetID,
                                                                             label: "A", answer: "x"))
            #expect(await bed.waitForState(chat.id, .idle))

            _ = try await Self.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star")
            #expect(await engineError {
                try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            } == EngineError(.conflict, "A symbol request is already waiting for an answer in this chat."))
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "heart") }
                == EngineError(.conflict, "A symbol request is already waiting for an answer in this chat."))
            #expect(try await Self.symbolItems(bed, chat.id).count == 1)
        }
    }

    @Test("waitingAnswers until the answer; Symbol: ![](sf:<name>), Symbol: <text> and Symbol: Skipped are sent to Claude")
    func answers() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let process = try #require(await bed.launcher.chatProcess())
            func answer(_ request: SymbolRequest, _ text: String) async throws {
                _ = try await bed.connection.call(ChatsAnswerSymbol.self, .init(chatID: chat.id, requestID: request.requestID, answer: text))
            }

            // A chosen symbol.
            let first = try await Self.post(bed, chat.id, suggestions: ["line.3.horizontal.decrease.circle", "slider.horizontal.3"],
                                            recommended: "line.3.horizontal.decrease.circle")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            #expect(await engineError { try await answer(first, "   ") } == EngineError(.invalid, "answer: use 1 to 10,000 characters."))
            #expect(await engineError {
                try await bed.connection.call(ChatsAnswerSymbol.self, .init(chatID: chat.id, requestID: UUID(), answer: "x"))
            }?.code == .notFound)
            #expect(await bed.state(chat.id) == .waitingAnswers)
            try await answer(first, " ![](sf:slider.horizontal.3) ")
            let chosen = await process.line { $0.contains("Symbol: ") }
            #expect(chosen?.contains(#""text":"Symbol: ![](sf:slider.horizontal.3)""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await Self.symbolItems(bed, chat.id).first?.answer == "![](sf:slider.horizontal.3)")
            #expect(await engineError { try await answer(first, "x") } == EngineError(.conflict, "This symbol request was already answered."))
            let user = try await bed.transcript(chat.id).compactMap { item -> UserItem? in
                if case .user(let user) = item, user.text.hasPrefix("Symbol: ") { return user }
                return nil
            }.last
            #expect(user?.text == "Symbol: ![](sf:slider.horizontal.3)")

            // An answer in the user's own words keeps its line breaks.
            let second = try await Self.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(second, "A filled star\nin orange")
            let typed = await process.line { $0.contains("Symbol: A filled star") }
            #expect(typed?.contains(#""text":"Symbol: A filled star\nin orange""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))

            // Skip.
            let third = try await Self.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "heart")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(third, "Skipped")
            let skipped = await process.line { $0.contains("Symbol: Skipped") }
            #expect(skipped?.contains(#""text":"Symbol: Skipped""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await Self.symbolItems(bed, chat.id).map(\.answer)
                == ["![](sf:slider.horizontal.3)", "A filled star\nin orange", "Skipped"])
        }
    }

    @Test("At startup a symbol request without answer gives waitingAnswers")
    func startupScan() async throws {
        let chatID = UUID()
        let requestID = UUID()
        try await withChatEngine(prepare: { folder, _ in
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), sessionStarted: true), to: folder)
            let request = SymbolItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: "Which?",
                                     suggestions: ["star", "heart"], recommended: "star")
            try JSONLinesWriter().append(TranscriptLine(op: .add, item: .symbol(request)), to: folder.transcriptFile(chatID))
        }) { bed in
            #expect(await bed.waitForState(chatID, .waitingAnswers))
            #expect(await engineError { try await Self.post(bed, chatID, suggestions: ["star", "heart"], recommended: "star") }
                == EngineError(.conflict, "A symbol request is already waiting for an answer in this chat."))
        }
    }
}
