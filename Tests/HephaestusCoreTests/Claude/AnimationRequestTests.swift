import Foundation
import Testing
@testable import HephaestusCore

/// Animation requests: the project type, the rules of `chats.postAnimation`, one waiting request
/// per chat, the state and the answer message (docs/chats.md › Animation requests,
/// docs/workflow.md › Animation requests).
@Suite("Animation requests")
struct AnimationRequestTests {
    static func post(_ bed: ChatTestBed, _ chatID: ChatID, question: String = "How should it move?", suggestions: [String],
                     recommended: String, actor: Actor? = nil) async throws -> AnimationRequest {
        try await bed.engine.call(ChatsPostAnimation.self, .init(chatID: chatID, question: question, suggestions: suggestions,
                                                                 recommended: recommended),
                                  actor: actor ?? .claude(chatID: chatID.uuidString))
    }

    static func animationItems(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> [AnimationItem] {
        try await bed.transcript(chatID).compactMap { item -> AnimationItem? in
            if case .animation(let request) = item { return request }
            return nil
        }
    }

    static func makeSwiftApplication(_ bed: ChatTestBed) async throws {
        _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", type: .swiftApplication))
    }

    @Test("ask_animation is refused outside Swift application projects, and nothing is posted")
    func projectType() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let refusal = EngineError(.forbidden, "ask_animation is available only in Swift application projects.")
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: [".snappy", ".smooth"], recommended: ".snappy") }
                == refusal)
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", type: .goService))
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: [".snappy", ".smooth"], recommended: ".snappy") }
                == refusal)
            #expect(try await Self.animationItems(bed, chat.id).isEmpty)
            #expect(await bed.state(chat.id) == .idle)
            try await Self.makeSwiftApplication(bed)
            _ = try await Self.post(bed, chat.id, suggestions: [".snappy", ".smooth"], recommended: ".snappy")
            #expect(try await Self.animationItems(bed, chat.id).count == 1)
        }
    }

    @Test("ask_animation validation: a question, 2 to 10 distinct presets with their parameters in range, recommended one of them")
    func validation() async throws {
        try await withChatEngine { bed in
            try await Self.makeSwiftApplication(bed)
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            func refusal(question: String = "How?", _ suggestions: [String], _ recommended: String,
                         actor: Actor? = nil) async -> EngineError? {
                await engineError {
                    try await Self.post(bed, chat.id, question: question, suggestions: suggestions, recommended: recommended, actor: actor)
                }
            }
            #expect(await refusal([".snappy", ".smooth"], ".snappy", actor: .claude(chatID: Actor.externalChatID))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(question: " \n ", [".snappy", ".smooth"], ".snappy") == EngineError(.invalid, "ask_animation needs a question."))
            #expect(await refusal([".snappy"], ".snappy") == EngineError(.invalid, "ask_animation needs 2 to 10 suggestions."))
            let eleven = [".smooth", ".snappy", ".bouncy", ".spring", ".easeIn", ".easeOut", ".easeInOut", ".linear",
                          ".spring(duration: 0.4)", ".spring(bounce: 0.2)", ".linear(duration: 1)"]
            #expect(await refusal(eleven, ".snappy") == EngineError(.invalid, "ask_animation needs 2 to 10 suggestions."))
            #expect(await refusal([".snappy", " .snappy "], ".snappy") == EngineError(.invalid, "ask_animation has an empty or repeated suggestion."))
            #expect(await refusal([".snappy", " "], ".snappy") == EngineError(.invalid, "ask_animation has an empty or repeated suggestion."))
            #expect(await refusal([".snappy", "Animation.spring", ".smooth"], ".snappy")
                == EngineError(.invalid, "Animation.spring is not a SwiftUI animation expression."))
            #expect(await refusal([".snappy", ".spring(duration 0.4)"], ".snappy")
                == EngineError(.invalid, ".spring(duration 0.4) is not a SwiftUI animation expression."))
            #expect(await refusal([".snappy", ".interactiveSpring"], ".snappy")
                == EngineError(.invalid, ".interactiveSpring: use .smooth, .snappy, .bouncy, .spring, .easeIn, .easeOut, .easeInOut or .linear."))
            #expect(await refusal([".snappy", ".spring(response: 0.5)"], ".snappy")
                == EngineError(.invalid, ".spring(response: 0.5): .spring takes (duration:bounce:)."))
            #expect(await refusal([".snappy", ".snappy(bounce: 0.2)"], ".snappy")
                == EngineError(.invalid, ".snappy(bounce: 0.2): .snappy takes (duration:extraBounce:)."))
            #expect(await refusal([".snappy", ".easeIn(duration: 0.3, bounce: 0)"], ".snappy")
                == EngineError(.invalid, ".easeIn(duration: 0.3, bounce: 0): .easeIn takes (duration:)."))
            #expect(await refusal([".snappy", ".spring(bounce: 0.2, duration: 0.4)"], ".snappy")
                == EngineError(.invalid, ".spring(bounce: 0.2, duration: 0.4): .spring takes (duration:bounce:)."))
            #expect(await refusal([".snappy", ".linear(duration: 2.5)"], ".snappy")
                == EngineError(.invalid, ".linear(duration: 2.5): duration must be from 0.1 to 2."))
            #expect(await refusal([".snappy", ".spring(bounce: -1.5)"], ".snappy")
                == EngineError(.invalid, ".spring(bounce: -1.5): bounce must be from -1 to 1."))
            #expect(await refusal([".snappy", ".bouncy(extraBounce: -0.1)"], ".snappy")
                == EngineError(.invalid, ".bouncy(extraBounce: -0.1): extraBounce must be from 0 to 1."))
            #expect(await refusal([".snappy", ".smooth"], ".spring")
                == EngineError(.invalid, "ask_animation: the recommended animation must be one of the suggestions."))
            #expect(try await Self.animationItems(bed, chat.id).isEmpty)
            #expect(await bed.state(chat.id) == .idle)

            // Ten suggestions, trimmed, kept in Claude's order.
            let ten = Array(eleven.prefix(10))
            let request = try await Self.post(bed, chat.id, suggestions: [" .spring(duration: 0.4, bounce: 0.2) "] + ten.dropFirst(1),
                                              recommended: " .snappy ")
            #expect(request.suggestions == [".spring(duration: 0.4, bounce: 0.2)"] + ten.dropFirst(1))
            #expect(request.recommended == ".snappy" && request.answer == nil && request.chatID == chat.id)
            let stored = try #require(try await Self.animationItems(bed, chat.id).first)
            #expect(stored.requestID == request.requestID && stored.id == request.requestID.uuidString)
            #expect(stored.suggestions == request.suggestions && stored.answer == nil)
        }
    }

    @Test("One waiting request per chat: questions and symbol, color, sound, shortcut, font and animation requests exclude each other")
    func conflicts() async throws {
        try await SoundRequestTests.withSoundEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let claude = Actor.claude(chatID: chat.id.uuidString)
            let question = Question(label: "A", question: "Which?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")],
                                    recommended: "x")
            let animations = [".snappy", ".smooth"]
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: animations, recommended: ".snappy") }
                == EngineError(.conflict, "Questions are already waiting for answers in this chat."))
            _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: set.questionSetID,
                                                                             label: "A", answer: "x"))
            #expect(await bed.waitForState(chat.id, .idle))

            let symbol = try await SymbolRequestTests.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star")
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: animations, recommended: ".snappy") }
                == EngineError(.conflict, "A symbol request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerSymbol.self, .init(chatID: chat.id, requestID: symbol.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let colors: [ColorValue] = [.color("red"), .color("blue")]
            let color = try await ColorRequestTests.post(bed, chat.id, suggestions: colors, recommended: .color("red"))
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: animations, recommended: ".snappy") }
                == EngineError(.conflict, "A color request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerColor.self, .init(chatID: chat.id, requestID: color.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let sounds = [SoundRequestTests.glass, SoundRequestTests.sms]
            let sound = try await SoundRequestTests.post(bed, chat.id, suggestions: sounds, recommended: SoundRequestTests.glass)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: animations, recommended: ".snappy") }
                == EngineError(.conflict, "A sound request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerSound.self, .init(chatID: chat.id, requestID: sound.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let shortcut = try await ShortcutRequestTests.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘K")
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: animations, recommended: ".snappy") }
                == EngineError(.conflict, "A shortcut request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerShortcut.self, .init(chatID: chat.id, requestID: shortcut.requestID,
                                                                             answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let fonts = [".headline", ".body"]
            let font = try await FontRequestTests.post(bed, chat.id, suggestions: fonts, recommended: ".body")
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: animations, recommended: ".snappy") }
                == EngineError(.conflict, "A font request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerFont.self, .init(chatID: chat.id, requestID: font.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            _ = try await Self.post(bed, chat.id, suggestions: animations, recommended: ".snappy")
            let waiting = EngineError(.conflict, "An animation request is already waiting for an answer in this chat.")
            #expect(await engineError {
                try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            } == waiting)
            #expect(await engineError { try await SymbolRequestTests.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star") }
                == waiting)
            #expect(await engineError { try await ColorRequestTests.post(bed, chat.id, suggestions: colors, recommended: .color("blue")) }
                == waiting)
            #expect(await engineError { try await SoundRequestTests.post(bed, chat.id, suggestions: sounds, recommended: SoundRequestTests.sms) }
                == waiting)
            #expect(await engineError { try await ShortcutRequestTests.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘L") }
                == waiting)
            #expect(await engineError { try await FontRequestTests.post(bed, chat.id, suggestions: fonts, recommended: ".headline") }
                == waiting)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: animations, recommended: ".smooth") } == waiting)
            #expect(try await Self.animationItems(bed, chat.id).count == 1)
        }
    }

    @Test("waitingAnswers until the answer; Animation: ![](animation:…) for a suggestion or a Custom animation, text and Skipped")
    func answers() async throws {
        try await withChatEngine { bed in
            try await Self.makeSwiftApplication(bed)
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let process = try #require(await bed.launcher.chatProcess())
            func answer(_ request: AnimationRequest, _ text: String) async throws {
                _ = try await bed.connection.call(ChatsAnswerAnimation.self, .init(chatID: chat.id, requestID: request.requestID, answer: text))
            }
            let suggestions = [".spring(duration: 0.4, bounce: 0.2)", ".snappy"]

            // A chosen suggestion.
            let first = try await Self.post(bed, chat.id, suggestions: suggestions, recommended: ".snappy")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            #expect(await engineError { try await answer(first, "   ") } == EngineError(.invalid, "answer: use 1 to 10,000 characters."))
            #expect(await engineError {
                try await bed.connection.call(ChatsAnswerAnimation.self, .init(chatID: chat.id, requestID: UUID(), answer: "x"))
            }?.code == .notFound)
            #expect(await bed.state(chat.id) == .waitingAnswers)
            try await answer(first, " ![](animation:.spring(duration: 0.4, bounce: 0.2)) ")
            let chosen = await process.line { $0.contains("Animation: ") }
            #expect(chosen?.contains(#""text":"Animation: ![](animation:.spring(duration: 0.4, bounce: 0.2))""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(await engineError { try await answer(first, "x") } == EngineError(.conflict, "This animation request was already answered."))
            let user = try await bed.transcript(chat.id).compactMap { item -> UserItem? in
                if case .user(let user) = item, user.text.hasPrefix("Animation: ") { return user }
                return nil
            }.last
            #expect(user?.text == "Animation: ![](animation:.spring(duration: 0.4, bounce: 0.2))")

            // The Custom row's expression.
            let second = try await Self.post(bed, chat.id, suggestions: suggestions, recommended: ".snappy")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(second, "![](animation:.bouncy(duration: 0.8, extraBounce: 0.15))")
            let custom = await process.line { $0.contains("Animation: ![](animation:.bouncy") }
            #expect(custom?.contains(#""text":"Animation: ![](animation:.bouncy(duration: 0.8, extraBounce: 0.15))""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))

            // An answer in the user's own words keeps its line breaks.
            let third = try await Self.post(bed, chat.id, suggestions: suggestions, recommended: ".snappy")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(third, "Faster\nand without bounce")
            let typed = await process.line { $0.contains("Animation: Faster") }
            #expect(typed?.contains(#""text":"Animation: Faster\nand without bounce""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))

            // Skip.
            let fourth = try await Self.post(bed, chat.id, suggestions: suggestions, recommended: ".snappy")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(fourth, "Skipped")
            let skipped = await process.line { $0.contains("Animation: Skipped") }
            #expect(skipped?.contains(#""text":"Animation: Skipped""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await Self.animationItems(bed, chat.id).map(\.answer) == [
                "![](animation:.spring(duration: 0.4, bounce: 0.2))", "![](animation:.bouncy(duration: 0.8, extraBounce: 0.15))",
                "Faster\nand without bounce", "Skipped",
            ])
        }
    }

    @Test("At startup an animation request without answer gives waitingAnswers")
    func startupScan() async throws {
        let chatID = UUID()
        let requestID = UUID()
        try await withChatEngine(prepare: { folder, _ in
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), sessionStarted: true), to: folder)
            let request = AnimationItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: "How?",
                                        suggestions: [".snappy", ".smooth"], recommended: ".snappy")
            try JSONLinesWriter().append(TranscriptLine(op: .add, item: .animation(request)), to: folder.transcriptFile(chatID))
        }) { bed in
            #expect(await bed.waitForState(chatID, .waitingAnswers))
            #expect(await engineError { try await SymbolRequestTests.post(bed, chatID, suggestions: ["star", "heart"], recommended: "star") }
                == EngineError(.conflict, "An animation request is already waiting for an answer in this chat."))
        }
    }
}

/// Animation expressions: the presets, their parameters, SwiftUI's defaults and the Custom row's
/// expression (docs/workflow.md › Animation expressions, docs/chats.md › Pinned animation card).
@Suite("Animation expressions")
struct AnimationExpressionTests {
    @Test("Presets with or without parameters, spaces around the punctuation, SwiftUI's defaults")
    func parsing() throws {
        let spring = try AnimationExpression(parsing: ".spring(duration: 0.4, bounce: 0.2)")
        #expect(spring == AnimationExpression(preset: .spring, values: [.duration: 0.4, .bounce: 0.2]))
        #expect(try AnimationExpression(parsing: ".spring( duration : 0.4 ,bounce:-0.25 )")
            == AnimationExpression(preset: .spring, values: [.duration: 0.4, .bounce: -0.25]))
        let snappy = try AnimationExpression(parsing: ".snappy")
        #expect(snappy.values.isEmpty && snappy.value(.duration) == 0.5 && snappy.value(.extraBounce) == 0)
        let ease = try AnimationExpression(parsing: ".easeInOut")
        #expect(ease.value(.duration) == 0.35)
        #expect(try AnimationExpression(parsing: ".bouncy(extraBounce: 1)").value(.duration) == 0.5)
        #expect(try AnimationExpression(parsing: ".linear(duration: 0.1)").value(.duration) == 0.1)
        for text in ["spring", ".", ".spring()", ".spring(duration: .5)", ".spring(duration: 1.)", ".spring (duration: 1)",
                     ".spring(duration: 0.4,)", ".spring(duration: 0.4) ", ".spring(duration:\t0.4)", ".spring(duration: 1e-1)",
                     ".spring(duration: 0.4", ".spring\n"] {
            #expect(throws: AnimationExpressionError.syntax) { try AnimationExpression(parsing: text) }
        }
        #expect(throws: AnimationExpressionError.unknownPreset) { try AnimationExpression(parsing: ".easeinout") }
        #expect(throws: AnimationExpressionError.parameters(.spring)) {
            try AnimationExpression(parsing: ".spring(duration: 0.4, duration: 0.5)")
        }
        #expect(throws: AnimationExpressionError.range(.duration)) { try AnimationExpression(parsing: ".easeIn(duration: 0.05)") }
        #expect(throws: AnimationExpressionError.range(.extraBounce)) { try AnimationExpression(parsing: ".smooth(extraBounce: 1.01)") }
    }

    @Test("The Custom row's expression has every parameter of its preset, at most two decimals, no trailing zeros")
    func fullExpression() throws {
        #expect(AnimationExpression(preset: .spring).fullExpression == ".spring(duration: 0.5, bounce: 0)")
        #expect(AnimationExpression(preset: .easeInOut, values: [.duration: 0.25]).fullExpression == ".easeInOut(duration: 0.25)")
        #expect(AnimationExpression(preset: .bouncy, values: [.duration: 2, .extraBounce: 0.104]).fullExpression
            == ".bouncy(duration: 2, extraBounce: 0.1)")
        #expect(AnimationExpression(preset: .spring, values: [.bounce: -0.001]).fullExpression == ".spring(duration: 0.5, bounce: 0)")
        #expect(AnimationExpression(preset: .spring, values: [.bounce: -0.3]).fullExpression == ".spring(duration: 0.5, bounce: -0.3)")
        for preset in AnimationPreset.allCases {
            let full = AnimationExpression(preset: preset).fullExpression
            #expect(try AnimationExpression(parsing: full).preset == preset)
        }
    }
}
