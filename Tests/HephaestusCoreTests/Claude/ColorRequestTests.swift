import Foundation
import Testing
@testable import HephaestusCore

/// Color requests: the rules of `chats.postColor`, one waiting request per chat, the state and
/// the answer messages (docs/chats.md › Color requests, docs/workflow.md › Color requests).
@Suite("Color requests")
struct ColorRequestTests {
    static func post(_ bed: ChatTestBed, _ chatID: ChatID, question: String = "Which color?", suggestions: [ColorValue],
                     recommended: ColorValue, lightAndDark: Bool? = nil, actor: Actor? = nil) async throws -> ColorRequest {
        try await bed.engine.call(ChatsPostColor.self, .init(chatID: chatID, question: question, suggestions: suggestions,
                                                             recommended: recommended, lightAndDark: lightAndDark),
                                  actor: actor ?? .claude(chatID: chatID.uuidString))
    }

    static func colorItems(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> [ColorItem] {
        try await bed.transcript(chatID).compactMap { item -> ColorItem? in
            if case .color(let request) = item { return request }
            return nil
        }
    }

    @Test("ask_color validation: a question, 2 to 10 distinct hex or system colors, pairs with lightAndDark, recommended one of them")
    func validation() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            func refusal(question: String = "Which color?", _ suggestions: [ColorValue], _ recommended: ColorValue,
                         lightAndDark: Bool? = nil, actor: Actor? = nil) async -> EngineError? {
                await engineError {
                    try await Self.post(bed, chat.id, question: question, suggestions: suggestions, recommended: recommended,
                                        lightAndDark: lightAndDark, actor: actor)
                }
            }
            let two: [ColorValue] = [.color("#FF9500"), .color("systemBlue")]
            #expect(await refusal(two, .color("systemBlue"), actor: .claude(chatID: Actor.externalChatID))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(two, .color("systemBlue"), actor: .claude(chatID: UUID().uuidString))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(question: " \n ", two, .color("systemBlue")) == EngineError(.invalid, "ask_color needs a question."))
            #expect(await refusal([.color("red")], .color("red")) == EngineError(.invalid, "ask_color needs 2 to 10 suggestions."))
            let eleven = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink"].map(ColorValue.color)
            #expect(await refusal(eleven, .color("red")) == EngineError(.invalid, "ask_color needs 2 to 10 suggestions."))
            #expect(await refusal([.color("red"), .pair(light: "#FFFFFF", dark: "#000000")], .color("red"))
                == EngineError(.invalid, "ask_color needs one color per suggestion, or lightAndDark for light and dark pairs."))
            #expect(await refusal(two, .pair(light: "#FFFFFF", dark: "#000000"), lightAndDark: false)
                == EngineError(.invalid, "ask_color needs one color per suggestion, or lightAndDark for light and dark pairs."))
            #expect(await refusal([.pair(light: "#FFFFFF", dark: "#000000"), .color("red")], .color("red"), lightAndDark: true)
                == EngineError(.invalid, "ask_color needs a light and dark pair per suggestion."))
            // Hex colors and system color names; the first wrong color is named as given.
            #expect(await refusal([.color("#FF9500"), .color("#FF950080"), .color("#12")], .color("#FF9500"))
                == EngineError(.invalid, "#FF950080 is not a hex color #RRGGBB or a system color name."))
            #expect(await refusal([.color("red"), .color("FF9500")], .color("red"))
                == EngineError(.invalid, "FF9500 is not a hex color #RRGGBB or a system color name."))
            #expect(await refusal([.color("red"), .color("SystemBlue")], .color("red"))
                == EngineError(.invalid, "SystemBlue is not a hex color #RRGGBB or a system color name."))
            #expect(await refusal([.color("red"), .color("darkGrayColor")], .color("red"))
                == EngineError(.invalid, "darkGrayColor is not a hex color #RRGGBB or a system color name."))
            #expect(await refusal([.pair(light: "#FFFFFF", dark: "#GGGGGG"), .pair(light: "nope", dark: "#000000")],
                                  .pair(light: "#FFFFFF", dark: "#GGGGGG"), lightAndDark: true)
                == EngineError(.invalid, "#GGGGGG is not a hex color #RRGGBB or a system color name."))
            // Hex digits are compared ignoring their letter case; pairs color by color.
            #expect(await refusal([.color("#ff9500"), .color(" #FF9500 ")], .color("#ff9500"))
                == EngineError(.invalid, "ask_color has a repeated suggestion."))
            #expect(await refusal([.pair(light: "#FFFFFF", dark: "label"), .pair(light: "#ffffff", dark: "label")],
                                  .pair(light: "#FFFFFF", dark: "label"), lightAndDark: true)
                == EngineError(.invalid, "ask_color has a repeated suggestion."))
            #expect(await refusal(two, .color("systemRed"))
                == EngineError(.invalid, "ask_color: the recommended color must be one of the suggestions."))
            #expect(try await Self.colorItems(bed, chat.id).isEmpty)
            #expect(await bed.state(chat.id) == .idle)

            // Ten suggestions, trimmed, kept in Claude's order; the recommended color may differ in case.
            let ten = Array(eleven.prefix(9)) + [.color(" #ff9500 ")]
            let request = try await Self.post(bed, chat.id, suggestions: ten, recommended: .color("#FF9500"))
            #expect(request.suggestions == Array(eleven.prefix(9)) + [.color("#ff9500")])
            #expect(request.recommended == .color("#FF9500") && request.lightAndDark == false && request.answer == nil)
            let stored = try #require(try await Self.colorItems(bed, chat.id).first)
            #expect(stored.requestID == request.requestID && stored.id == request.requestID.uuidString)
            #expect(stored.suggestions == request.suggestions && stored.lightAndDark == false && stored.answer == nil)
        }
    }

    @Test("A light and dark request stores its pairs")
    func pairs() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let suggestions: [ColorValue] = [.pair(light: "#FFFFFF", dark: "#1C1C1E"),
                                             .pair(light: "systemBackground", dark: "secondarySystemBackground")]
            let request = try await Self.post(bed, chat.id, suggestions: suggestions, recommended: suggestions[0], lightAndDark: true)
            #expect(request.lightAndDark && request.suggestions == suggestions && request.recommended == suggestions[0])
            let stored = try #require(try await Self.colorItems(bed, chat.id).first)
            #expect(stored.lightAndDark && stored.suggestions == suggestions)
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
        }
    }

    @Test("One waiting request per chat: ask_color while questions or a symbol request wait, the others while a color request waits")
    func conflicts() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let claude = Actor.claude(chatID: chat.id.uuidString)
            let two: [ColorValue] = [.color("red"), .color("blue")]
            let question = Question(label: "A", question: "Which?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")],
                                    recommended: "x")
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: two, recommended: .color("red")) }
                == EngineError(.conflict, "Questions are already waiting for answers in this chat."))
            _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: set.questionSetID,
                                                                             label: "A", answer: "x"))
            #expect(await bed.waitForState(chat.id, .idle))

            let symbol = try await SymbolRequestTests.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star")
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: two, recommended: .color("red")) }
                == EngineError(.conflict, "A symbol request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerSymbol.self, .init(chatID: chat.id, requestID: symbol.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            _ = try await Self.post(bed, chat.id, suggestions: two, recommended: .color("red"))
            let waiting = EngineError(.conflict, "A color request is already waiting for an answer in this chat.")
            #expect(await engineError {
                try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            } == waiting)
            #expect(await engineError { try await SymbolRequestTests.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star") }
                == waiting)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: two, recommended: .color("blue")) } == waiting)
            #expect(try await Self.colorItems(bed, chat.id).count == 1)
        }
    }

    @Test("waitingAnswers until the answer; one color, a pair, free text and Skipped are sent to Claude as Color: <answer>")
    func answers() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let process = try #require(await bed.launcher.chatProcess())
            func answer(_ request: ColorRequest, _ text: String) async throws {
                _ = try await bed.connection.call(ChatsAnswerColor.self, .init(chatID: chat.id, requestID: request.requestID, answer: text))
            }
            let two: [ColorValue] = [.color("#FF9500"), .color("systemBlue")]

            // One color.
            let first = try await Self.post(bed, chat.id, suggestions: two, recommended: .color("systemBlue"))
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            #expect(await engineError { try await answer(first, "   ") } == EngineError(.invalid, "answer: use 1 to 10,000 characters."))
            #expect(await engineError {
                try await bed.connection.call(ChatsAnswerColor.self, .init(chatID: chat.id, requestID: UUID(), answer: "x"))
            }?.code == .notFound)
            #expect(await bed.state(chat.id) == .waitingAnswers)
            try await answer(first, " ![](color:systemBlue) ")
            let chosen = await process.line { $0.contains("Color: ![](color:systemBlue)") }
            #expect(chosen?.contains(#""text":"Color: ![](color:systemBlue)""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(await engineError { try await answer(first, "x") } == EngineError(.conflict, "This color request was already answered."))

            // A light and dark pair.
            let pairs: [ColorValue] = [.pair(light: "#FFFFFF", dark: "#1C1C1E"), .pair(light: "#F2F2F7", dark: "#000000")]
            let second = try await Self.post(bed, chat.id, suggestions: pairs, recommended: pairs[0], lightAndDark: true)
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(second, "Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E)")
            let pair = await process.line { $0.contains("Color: Light") }
            #expect(pair?.contains(#""text":"Color: Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E)""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))

            // An answer in the user's own words keeps its line breaks.
            let third = try await Self.post(bed, chat.id, suggestions: two, recommended: .color("#FF9500"))
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(third, "A warm orange\nlike the logo")
            let typed = await process.line { $0.contains("Color: A warm orange") }
            #expect(typed?.contains(#""text":"Color: A warm orange\nlike the logo""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))

            // Skip.
            let fourth = try await Self.post(bed, chat.id, suggestions: two, recommended: .color("#FF9500"))
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(fourth, "Skipped")
            let skipped = await process.line { $0.contains("Color: Skipped") }
            #expect(skipped?.contains(#""text":"Color: Skipped""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await Self.colorItems(bed, chat.id).map(\.answer) == [
                "![](color:systemBlue)", "Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E)", "A warm orange\nlike the logo", "Skipped",
            ])
        }
    }

    @Test("At startup a color request without answer gives waitingAnswers")
    func startupScan() async throws {
        let chatID = UUID()
        let requestID = UUID()
        try await withChatEngine(prepare: { folder, _ in
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), sessionStarted: true), to: folder)
            let request = ColorItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: "Which?",
                                    lightAndDark: false, suggestions: [.color("red"), .color("blue")], recommended: .color("red"))
            try JSONLinesWriter().append(TranscriptLine(op: .add, item: .color(request)), to: folder.transcriptFile(chatID))
        }) { bed in
            #expect(await bed.waitForState(chatID, .waitingAnswers))
            #expect(await engineError { try await Self.post(bed, chatID, suggestions: [.color("red"), .color("blue")], recommended: .color("red")) }
                == EngineError(.conflict, "A color request is already waiting for an answer in this chat."))
        }
    }
}

/// The system color names and the check of a color (docs/chats.md › System colors).
@Suite("System colors")
struct SystemColorsTests {
    @Test("86 distinct names in four groups; hex colors in either case; names with their case")
    func names() {
        #expect(SystemColors.names.count == 86)
        #expect(Set(SystemColors.names).count == 86)
        #expect(SystemColors.names.prefix(3) == ["red", "orange", "yellow"])
        #expect(SystemColors.names.last == "shadowColor")
        for name in ["accentColor", "systemGray6", "label", "secondaryLabel", "separator", "tintColor", "windowBackgroundColor",
                     "controlAccentColor", "quinaryLabelColor"] {
            #expect(SystemColors.isColor(name), "\(name)")
        }
        for text in ["windowBackground", "Label", "clear", "clearColor", "magentaColor", "scrubberTexturedBackgroundColor",
                     "#FFF", "#FF950080", "FF9500", "#GG9500", "", " #FF9500"] {
            #expect(!SystemColors.isColor(text), "\(text)")
        }
        #expect(SystemColors.isHex("#ff9500") && SystemColors.isHex("#FF9500"))
        #expect(SystemColors.isSame("#ff9500", "#FF9500") && !SystemColors.isSame("label", "Label"))
        #expect(SystemColors.normalized("#ff9500") == "#FF9500" && SystemColors.normalized("systemBlue") == "systemBlue")
        // Every UIKit name AppKit lacks has values, tintColor aside.
        #expect(Set(SystemColors.uiKitValues.keys).isSubset(of: Set(SystemColors.names)))
        #expect(SystemColors.uiKitValues["systemGray6"] == SystemColorValues(light: "#F2F2F7", dark: "#1C1C1E"))
    }

    @Test("A color value is a string or an object with light and dark")
    func colorValueCoding() throws {
        let decoded = try JSONDecoder().decode([ColorValue].self, from: Data(##"["#FF9500",{"light":"#FFFFFF","dark":"label"}]"##.utf8))
        #expect(decoded == [.color("#FF9500"), .pair(light: "#FFFFFF", dark: "label")])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ColorValue].self, from: Data(##"[{"light":"#FFFFFF"}]"##.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ColorValue].self, from: Data("[3]".utf8))
        }
    }
}
