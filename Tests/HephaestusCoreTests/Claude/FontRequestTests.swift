import Foundation
import Testing
@testable import HephaestusCore

/// Font requests: the rules of `chats.postFont`, one waiting request per chat, the state, the
/// answer messages and `files.fonts` (docs/chats.md › Font requests, docs/workflow.md › Font
/// requests, docs/engine-api.md › files.fonts).
@Suite("Font requests")
struct FontRequestTests {
    static func post(_ bed: ChatTestBed, _ chatID: ChatID, question: String = "Which font?", sample: String = "Ticket titles",
                     suggestions: [String], recommended: String, actor: Actor? = nil) async throws -> FontRequest {
        try await bed.engine.call(ChatsPostFont.self, .init(chatID: chatID, question: question, sample: sample, suggestions: suggestions,
                                                            recommended: recommended),
                                  actor: actor ?? .claude(chatID: chatID.uuidString))
    }

    static func fontItems(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> [FontItem] {
        try await bed.transcript(chatID).compactMap { item -> FontItem? in
            if case .font(let request) = item { return request }
            return nil
        }
    }

    /// Writes the font files of the test project, outside git: the walk of the folder lists them.
    static func writeProjectFonts(_ root: URL) throws {
        let fonts = root.appendingPathComponent("Resources/Fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try FontTestFiles.font(family: "Heph Test Sans", style: "Regular", postScriptName: "HephTestSans-Regular")
            .write(to: fonts.appendingPathComponent("HephTestSans-Regular.TTF"))
        try FontTestFiles.font(family: "Heph Test Sans", style: "Bold", postScriptName: "HephTestSans-Bold", base: "Helvetica-Bold")
            .write(to: fonts.appendingPathComponent("HephTestSans-Bold.otf"))
        try FontTestFiles.font(family: "Heph Ignored", style: "Regular", postScriptName: "HephIgnored-Regular")
            .write(to: root.appendingPathComponent(".build/Ignored.ttf", isDirectory: false).creatingParent())
        try Data("not a font".utf8).write(to: fonts.appendingPathComponent("Broken.ttc"))
    }

    @Test("ask_font validation: question, sample, 2 to 10 distinct fonts of the notation and the catalogue, recommended one of them")
    func validation() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            func refusal(question: String = "Which font?", sample: String = "Titles", _ suggestions: [String], _ recommended: String,
                         actor: Actor? = nil) async -> EngineError? {
                await engineError {
                    try await Self.post(bed, chat.id, question: question, sample: sample, suggestions: suggestions,
                                        recommended: recommended, actor: actor)
                }
            }
            let two = ["System/Bold/17", ".headline"]
            #expect(await refusal(two, ".headline", actor: .claude(chatID: Actor.externalChatID))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(two, ".headline", actor: .claude(chatID: UUID().uuidString))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(question: " \n ", two, ".headline") == EngineError(.invalid, "ask_font needs a question."))
            #expect(await refusal(sample: " \n ", two, ".headline") == EngineError(.invalid, "ask_font needs a sample text."))
            #expect(await refusal([".headline"], ".headline") == EngineError(.invalid, "ask_font needs 2 to 10 suggestions."))
            let styles = FontTextStyle.allCases.map(\.notation)
            #expect(await refusal(styles, ".body") == EngineError(.invalid, "ask_font needs 2 to 10 suggestions."))
            #expect(await refusal([".body", " .body "], ".body") == EngineError(.invalid, "ask_font has an empty or repeated suggestion."))
            #expect(await refusal([".body", "  "], ".body") == EngineError(.invalid, "ask_font has an empty or repeated suggestion."))
            #expect(await refusal([".body", "Helvetica", ".title9"], ".body") == EngineError(.invalid,
                "Helvetica is not a font: write a text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17."))
            #expect(await refusal([".body", ".title9"], ".body") == EngineError(.invalid,
                ".title9 is not a font: write a text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17."))
            #expect(await refusal([".body", "System/Bold/15.25"], ".body")
                == EngineError(.invalid, "System/Bold/15.25: the size must be 1 to 999 pt, with at most one decimal."))
            #expect(await refusal([".body", "System/Bold/1000"], ".body")
                == EngineError(.invalid, "System/Bold/1000: the size must be 1 to 999 pt, with at most one decimal."))
            #expect(await refusal([".body", "No Such Family/Regular/12", "Avenir Next/Semibold/12"], ".body")
                == EngineError(.invalid, "No Such Family/Regular/12 is not a font of this Mac."))
            #expect(await refusal([".body", "Avenir Next/Semibold/12"], ".body")
                == EngineError(.invalid, "Avenir Next/Semibold/12 is not a font of this Mac."))
            #expect(await refusal([".body", "System/Demi Bold/12"], ".body")
                == EngineError(.invalid, "System/Demi Bold/12 is not a font of this Mac."))
            #expect(await refusal(two, ".body") == EngineError(.invalid, "ask_font: the recommended font must be one of the suggestions."))
            #expect(try await Self.fontItems(bed, chat.id).isEmpty)
            #expect(await bed.state(chat.id) == .idle)

            // Ten suggestions, trimmed, kept in Claude's order, with the sample.
            let ten = [" System Rounded/Semibold/17 ", "Avenir Next/Demi Bold/15", "System Monospaced/Black/999", "System Serif/Light/1.5"]
                + styles.prefix(6)
            let request = try await Self.post(bed, chat.id, sample: "  Replace the status filter\nwith a menu  ", suggestions: ten,
                                              recommended: " System Rounded/Semibold/17")
            #expect(request.suggestions == ten.map { $0.trimmingCharacters(in: .whitespaces) })
            #expect(request.recommended == "System Rounded/Semibold/17" && request.answer == nil && request.chatID == chat.id)
            #expect(request.sample == "Replace the status filter\nwith a menu")
            let stored = try #require(try await Self.fontItems(bed, chat.id).first)
            #expect(stored.requestID == request.requestID && stored.id == request.requestID.uuidString)
            #expect(stored.suggestions == request.suggestions && stored.sample == request.sample && stored.answer == nil)
        }
    }

    @Test("The project's font files are fonts of the catalogue; files.fonts returns their families")
    func projectFonts() async throws {
        try await withChatEngine(prepare: { folder, _ in try Self.writeProjectFonts(folder.root) }) { bed in
            let families = try await bed.connection.call(FilesFonts.self, .init(projectID: "DEMO"))
            #expect(families.map(\.name) == ["Heph Test Sans"])
            #expect(families.first?.faces.map(\.name) == ["Regular", "Bold"])
            #expect(families.first?.faces.map(\.path) == ["Resources/Fonts/HephTestSans-Regular.TTF", "Resources/Fonts/HephTestSans-Bold.otf"])
            #expect(await engineError { try await bed.connection.call(FilesFonts.self, .init(projectID: "nope!")) }?.code == .invalid)
            #expect(await engineError { try await bed.connection.call(FilesFonts.self, .init(projectID: "NOPE")) }?.code == .notFound)

            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(await engineError {
                try await Self.post(bed, chat.id, suggestions: ["Heph Ignored/Regular/12", ".body"], recommended: ".body")
            } == EngineError(.invalid, "Heph Ignored/Regular/12 is not a font of this Mac."))
            let request = try await Self.post(bed, chat.id, suggestions: ["Heph Test Sans/Bold/14", ".body"], recommended: "Heph Test Sans/Bold/14")
            #expect(request.suggestions.first == "Heph Test Sans/Bold/14")
        }
    }

    @Test("One waiting request per chat: ask_font while questions, a symbol, a color, a sound or a shortcut request wait; the others while a font request waits")
    func conflicts() async throws {
        try await SoundRequestTests.withSoundEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let claude = Actor.claude(chatID: chat.id.uuidString)
            let question = Question(label: "A", question: "Which?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")],
                                    recommended: "x")
            let fonts = [".headline", ".body"]
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: fonts, recommended: ".body") }
                == EngineError(.conflict, "Questions are already waiting for answers in this chat."))
            _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: set.questionSetID,
                                                                             label: "A", answer: "x"))
            #expect(await bed.waitForState(chat.id, .idle))

            let symbol = try await SymbolRequestTests.post(bed, chat.id, suggestions: ["star", "heart"], recommended: "star")
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: fonts, recommended: ".body") }
                == EngineError(.conflict, "A symbol request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerSymbol.self, .init(chatID: chat.id, requestID: symbol.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let colors: [ColorValue] = [.color("red"), .color("blue")]
            let color = try await ColorRequestTests.post(bed, chat.id, suggestions: colors, recommended: .color("red"))
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: fonts, recommended: ".body") }
                == EngineError(.conflict, "A color request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerColor.self, .init(chatID: chat.id, requestID: color.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let sounds = [SoundRequestTests.glass, SoundRequestTests.sms]
            let sound = try await SoundRequestTests.post(bed, chat.id, suggestions: sounds, recommended: SoundRequestTests.glass)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: fonts, recommended: ".body") }
                == EngineError(.conflict, "A sound request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerSound.self, .init(chatID: chat.id, requestID: sound.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let shortcut = try await ShortcutRequestTests.post(bed, chat.id, suggestions: ["⌘K", "⌘L"], recommended: "⌘K")
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: fonts, recommended: ".body") }
                == EngineError(.conflict, "A shortcut request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerShortcut.self, .init(chatID: chat.id, requestID: shortcut.requestID,
                                                                             answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            _ = try await Self.post(bed, chat.id, suggestions: fonts, recommended: ".body")
            let waiting = EngineError(.conflict, "A font request is already waiting for an answer in this chat.")
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
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: fonts, recommended: ".headline") } == waiting)
            #expect(try await Self.fontItems(bed, chat.id).count == 1)
        }
    }

    @Test("waitingAnswers until the answer; Font: ![](font:<font>), Font: <text> and Font: Skipped are sent to Claude")
    func answers() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let process = try #require(await bed.launcher.chatProcess())
            func answer(_ request: FontRequest, _ text: String) async throws {
                _ = try await bed.connection.call(ChatsAnswerFont.self, .init(chatID: chat.id, requestID: request.requestID, answer: text))
            }
            let fonts = ["System Rounded/Semibold/17", "Avenir Next/Demi Bold/15", ".headline"]

            // A chosen family font.
            let first = try await Self.post(bed, chat.id, suggestions: fonts, recommended: fonts[0])
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            #expect(await engineError { try await answer(first, "   ") } == EngineError(.invalid, "answer: use 1 to 10,000 characters."))
            #expect(await engineError {
                try await bed.connection.call(ChatsAnswerFont.self, .init(chatID: chat.id, requestID: UUID(), answer: "x"))
            }?.code == .notFound)
            #expect(await bed.state(chat.id) == .waitingAnswers)
            try await answer(first, " ![](font:System Rounded/Semibold/17) ")
            let chosen = await process.line { $0.contains("Font: ") }
            #expect(chosen?.contains(#""text":"Font: ![](font:System Rounded/Semibold/17)""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(await engineError { try await answer(first, "x") } == EngineError(.conflict, "This font request was already answered."))
            let user = try await bed.transcript(chat.id).compactMap { item -> UserItem? in
                if case .user(let user) = item, user.text.hasPrefix("Font: ") { return user }
                return nil
            }.last
            #expect(user?.text == "Font: ![](font:System Rounded/Semibold/17)")

            // A text style.
            let second = try await Self.post(bed, chat.id, suggestions: fonts, recommended: ".headline")
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(second, "![](font:.headline)")
            let style = await process.line { $0.contains("Font: ![](font:.headline)") }
            #expect(style != nil)
            #expect(await bed.waitForState(chat.id, .idle))

            // An answer in the user's own words keeps its line breaks.
            let third = try await Self.post(bed, chat.id, suggestions: fonts, recommended: fonts[1])
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(third, "Something rounder\nand larger")
            let typed = await process.line { $0.contains("Font: Something rounder") }
            #expect(typed?.contains(#""text":"Font: Something rounder\nand larger""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))

            // Skip.
            let fourth = try await Self.post(bed, chat.id, suggestions: fonts, recommended: fonts[1])
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(fourth, "Skipped")
            let skipped = await process.line { $0.contains("Font: Skipped") }
            #expect(skipped?.contains(#""text":"Font: Skipped""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await Self.fontItems(bed, chat.id).map(\.answer)
                == ["![](font:System Rounded/Semibold/17)", "![](font:.headline)", "Something rounder\nand larger", "Skipped"])
        }
    }

    @Test("At startup a font request without answer gives waitingAnswers")
    func startupScan() async throws {
        let chatID = UUID()
        let requestID = UUID()
        try await withChatEngine(prepare: { folder, _ in
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), sessionStarted: true), to: folder)
            let request = FontItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: "Which?",
                                   sample: "Titles", suggestions: [".headline", ".body"], recommended: ".body")
            try JSONLinesWriter().append(TranscriptLine(op: .add, item: .font(request)), to: folder.transcriptFile(chatID))
        }) { bed in
            #expect(await bed.waitForState(chatID, .waitingAnswers))
            #expect(await engineError { try await Self.post(bed, chatID, suggestions: [".headline", ".body"], recommended: ".body") }
                == EngineError(.conflict, "A font request is already waiting for an answer in this chat."))
        }
    }
}

private extension URL {
    /// The URL, its parent folder created.
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
