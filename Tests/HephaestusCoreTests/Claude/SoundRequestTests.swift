import Foundation
import Testing
@testable import HephaestusCore

/// Sound requests: the project type, the rules of `chats.postSound`, one waiting request per chat,
/// the state, the answer message, and `sounds.list` and `sounds.read` (docs/chats.md › Sound
/// requests, docs/workflow.md › Sound requests, docs/engine-api.md › Sounds).
@Suite("Sound requests")
struct SoundRequestTests {
    static let glass = "macOS/Glass.aiff"
    static let sms = "iOS 26.1/sms-received1.caf"
    static let alert = "Project/Sounds/alert.caf"

    /// A Swift application project, unless `type` says otherwise.
    static func prepare(type: ProjectType = .swiftApplication) -> (ProjectFolder, DataDirectory) throws -> Void {
        { folder, _ in
            try ProjectFileStore.write(Project(id: "DEMO", name: "Demo", created: ISODate.date(from: "2026-10-31T12:00:00Z")!, type: type,
                                               commands: ProjectCommands(build: "make build")), to: folder)
            let sounds = folder.root.appendingPathComponent("Sounds", isDirectory: true)
            try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
            try Data("alert".utf8).write(to: sounds.appendingPathComponent("alert.caf"))
            try Data("notes".utf8).write(to: sounds.appendingPathComponent("notes.txt"))
        }
    }

    /// System sounds of a fixture folder next to the project: `Glass.aiff` for macOS and
    /// `sms-received1.caf` and `New/Anticipate.caf` for the runtime `iOS 26.1`.
    static func useSystemSounds(_ bed: ChatTestBed) async throws {
        let base = bed.root.deletingLastPathComponent()
        let macOS = base.appendingPathComponent("SystemSounds", isDirectory: true)
        let runtime = base.appendingPathComponent("Runtime", isDirectory: true)
        let uiSounds = runtime.appendingPathComponent(SoundCatalog.runtimeSoundsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: uiSounds.appendingPathComponent("New"), withIntermediateDirectories: true)
        try Data("glass".utf8).write(to: macOS.appendingPathComponent("Glass.aiff"))
        try Data("sms".utf8).write(to: uiSounds.appendingPathComponent("sms-received1.caf"))
        try Data("anticipate".utf8).write(to: uiSounds.appendingPathComponent("New/Anticipate.caf"))
        await bed.engine.useSystemSounds(.read(macOSFolder: macOS, runtimes: [SoundCatalog.Runtime(name: "iOS 26.1", root: runtime)]))
    }

    static func withSoundEngine(type: ProjectType = .swiftApplication, _ body: (ChatTestBed) async throws -> Void) async throws {
        try await withChatEngine(prepare: prepare(type: type)) { bed in
            try await useSystemSounds(bed)
            try await body(bed)
        }
    }

    static func post(_ bed: ChatTestBed, _ chatID: ChatID, question: String = "Which sound?", suggestions: [String],
                     recommended: String, actor: Actor? = nil) async throws -> SoundRequest {
        try await bed.engine.call(ChatsPostSound.self, .init(chatID: chatID, question: question, suggestions: suggestions,
                                                             recommended: recommended),
                                  actor: actor ?? .claude(chatID: chatID.uuidString))
    }

    static func soundItems(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> [SoundItem] {
        try await bed.transcript(chatID).compactMap { item -> SoundItem? in
            if case .sound(let request) = item { return request }
            return nil
        }
    }

    @Test("ask_sound validation: the chat's own Claude, a question, 2 to 10 distinct names of the catalogue, recommended one of them")
    func validation() async throws {
        try await Self.withSoundEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            func refusal(question: String = "Which sound?", _ suggestions: [String], _ recommended: String,
                         actor: Actor? = nil) async -> EngineError? {
                await engineError {
                    try await Self.post(bed, chat.id, question: question, suggestions: suggestions, recommended: recommended, actor: actor)
                }
            }
            let two = [Self.glass, Self.sms]
            #expect(await refusal(two, Self.glass, actor: .claude(chatID: Actor.externalChatID))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(two, Self.glass, actor: .claude(chatID: UUID().uuidString))
                == EngineError(.forbidden, "Only the chat's own Claude can ask questions."))
            #expect(await refusal(question: " \n ", two, Self.glass) == EngineError(.invalid, "ask_sound needs a question."))
            #expect(await refusal([Self.glass], Self.glass) == EngineError(.invalid, "ask_sound needs 2 to 10 suggestions."))
            #expect(await refusal(Array(repeating: Self.glass, count: 11), Self.glass)
                == EngineError(.invalid, "ask_sound needs 2 to 10 suggestions."))
            #expect(await refusal([Self.glass, " \(Self.glass) "], Self.glass)
                == EngineError(.invalid, "ask_sound has an empty or repeated suggestion."))
            #expect(await refusal([Self.glass, "  "], Self.glass) == EngineError(.invalid, "ask_sound has an empty or repeated suggestion."))
            #expect(await refusal([Self.glass, "macOS/Nope.aiff", "Project/Sounds/notes.txt"], Self.glass)
                == EngineError(.invalid, "macOS/Nope.aiff is not a sound of this Mac or of the project."))
            #expect(await refusal([Self.glass, "Project/Sounds/notes.txt"], Self.glass)
                == EngineError(.invalid, "Project/Sounds/notes.txt is not a sound of this Mac or of the project."))
            #expect(await refusal(two, Self.alert) == EngineError(.invalid, "ask_sound: the recommended sound must be one of the suggestions."))
            #expect(try await Self.soundItems(bed, chat.id).isEmpty)
            #expect(await bed.state(chat.id) == .idle)

            // The three sources, trimmed and kept in Claude's order.
            let request = try await Self.post(bed, chat.id, suggestions: [" \(Self.alert) ", Self.sms, "iOS 26.1/New/Anticipate.caf", Self.glass],
                                              recommended: " \(Self.sms) ")
            #expect(request.suggestions == [Self.alert, Self.sms, "iOS 26.1/New/Anticipate.caf", Self.glass])
            #expect(request.recommended == Self.sms && request.answer == nil && request.chatID == chat.id)
            let stored = try #require(try await Self.soundItems(bed, chat.id).first)
            #expect(stored.requestID == request.requestID && stored.id == request.requestID.uuidString)
            #expect(stored.suggestions == request.suggestions && stored.answer == nil)
        }
    }

    @Test("ask_sound fails with forbidden in a project whose type is not Swift application, and nothing is posted")
    func projectType() async throws {
        for type in [ProjectType.none, .goService] {
            try await Self.withSoundEngine(type: type) { bed in
                let chat = try await bed.createChat(message: "Plan")
                #expect(await bed.waitForState(chat.id, .idle))
                #expect(await engineError { try await Self.post(bed, chat.id, suggestions: [Self.glass, Self.sms], recommended: Self.glass) }
                    == EngineError(.forbidden, "ask_sound is only available in Swift application projects."))
                #expect(try await Self.soundItems(bed, chat.id).isEmpty)
                #expect(await bed.state(chat.id) == .idle)
            }
        }
    }

    @Test("One waiting request per chat: ask_sound while questions, a symbol, a color or a sound request wait; the others while a sound request waits")
    func conflicts() async throws {
        try await Self.withSoundEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let claude = Actor.claude(chatID: chat.id.uuidString)
            let question = Question(label: "A", question: "Which?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")],
                                    recommended: "x")
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: [Self.glass, Self.sms], recommended: Self.glass) }
                == EngineError(.conflict, "Questions are already waiting for answers in this chat."))
            _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: chat.id, questionSetID: set.questionSetID,
                                                                             label: "A", answer: "x"))
            #expect(await bed.waitForState(chat.id, .idle))

            let symbol = try await bed.engine.call(ChatsPostSymbol.self, .init(chatID: chat.id, question: "Which icon?",
                                                                              suggestions: ["star", "heart"], recommended: "star"),
                                                   actor: claude)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: [Self.glass, Self.sms], recommended: Self.glass) }
                == EngineError(.conflict, "A symbol request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerSymbol.self, .init(chatID: chat.id, requestID: symbol.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            let colors: [ColorValue] = [.color("red"), .color("blue")]
            let color = try await ColorRequestTests.post(bed, chat.id, suggestions: colors, recommended: .color("red"))
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: [Self.glass, Self.sms], recommended: Self.glass) }
                == EngineError(.conflict, "A color request is already waiting for an answer in this chat."))
            _ = try await bed.connection.call(ChatsAnswerColor.self, .init(chatID: chat.id, requestID: color.requestID, answer: "Skipped"))
            #expect(await bed.waitForState(chat.id, .idle))

            _ = try await Self.post(bed, chat.id, suggestions: [Self.glass, Self.sms], recommended: Self.glass)
            let waiting = EngineError(.conflict, "A sound request is already waiting for an answer in this chat.")
            #expect(await engineError {
                try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            } == waiting)
            #expect(await engineError {
                try await bed.engine.call(ChatsPostSymbol.self, .init(chatID: chat.id, question: "Which icon?",
                                                                      suggestions: ["star", "heart"], recommended: "star"), actor: claude)
            } == waiting)
            #expect(await engineError { try await ColorRequestTests.post(bed, chat.id, suggestions: colors, recommended: .color("blue")) }
                == waiting)
            #expect(await engineError { try await Self.post(bed, chat.id, suggestions: [Self.glass, Self.sms], recommended: Self.sms) }
                == waiting)
            #expect(try await Self.soundItems(bed, chat.id).count == 1)
        }
    }

    @Test("waitingAnswers until the answer; Sound: ![](sound:<name>), Sound: <text> and Sound: Skipped are sent to Claude")
    func answers() async throws {
        try await Self.withSoundEngine { bed in
            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let process = try #require(await bed.launcher.chatProcess())
            func answer(_ request: SoundRequest, _ text: String) async throws {
                _ = try await bed.connection.call(ChatsAnswerSound.self, .init(chatID: chat.id, requestID: request.requestID, answer: text))
            }

            // A chosen sound, whose name holds a space.
            let first = try await Self.post(bed, chat.id, suggestions: [Self.sms, Self.glass], recommended: Self.sms)
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            #expect(await engineError { try await answer(first, "   ") } == EngineError(.invalid, "answer: use 1 to 10,000 characters."))
            #expect(await engineError {
                try await bed.connection.call(ChatsAnswerSound.self, .init(chatID: chat.id, requestID: UUID(), answer: "x"))
            }?.code == .notFound)
            #expect(await bed.state(chat.id) == .waitingAnswers)
            try await answer(first, " ![](sound:iOS 26.1/sms-received1.caf) ")
            let chosen = await process.line { $0.contains("Sound: ") }
            #expect(chosen?.contains(#""text":"Sound: ![](sound:iOS 26.1/sms-received1.caf)""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(await engineError { try await answer(first, "x") } == EngineError(.conflict, "This sound request was already answered."))
            let user = try await bed.transcript(chat.id).compactMap { item -> UserItem? in
                if case .user(let user) = item, user.text.hasPrefix("Sound: ") { return user }
                return nil
            }.last
            #expect(user?.text == "Sound: ![](sound:iOS 26.1/sms-received1.caf)")

            // An answer in the user's own words keeps its line breaks.
            let second = try await Self.post(bed, chat.id, suggestions: [Self.glass, Self.alert], recommended: Self.alert)
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(second, "A soft chime\nlike Glass")
            let typed = await process.line { $0.contains("Sound: A soft chime") }
            #expect(typed?.contains(#""text":"Sound: A soft chime\nlike Glass""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))

            // Skip.
            let third = try await Self.post(bed, chat.id, suggestions: [Self.glass, Self.alert], recommended: Self.glass)
            #expect(await bed.waitForState(chat.id, .waitingAnswers))
            try await answer(third, "Skipped")
            let skipped = await process.line { $0.contains("Sound: Skipped") }
            #expect(skipped?.contains(#""text":"Sound: Skipped""#) == true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await Self.soundItems(bed, chat.id).map(\.answer)
                == ["![](sound:iOS 26.1/sms-received1.caf)", "A soft chime\nlike Glass", "Skipped"])
        }
    }

    @Test("At startup a sound request without answer gives waitingAnswers")
    func startupScan() async throws {
        let chatID = UUID()
        let requestID = UUID()
        let base = Self.prepare()
        try await withChatEngine(prepare: { folder, data in
            try base(folder, data)
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), sessionStarted: true), to: folder)
            let request = SoundItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: "Which?",
                                    suggestions: [Self.glass, Self.sms], recommended: Self.glass)
            try JSONLinesWriter().append(TranscriptLine(op: .add, item: .sound(request)), to: folder.transcriptFile(chatID))
        }) { bed in
            try await Self.useSystemSounds(bed)
            #expect(await bed.waitForState(chatID, .waitingAnswers))
            let claude = Actor.claude(chatID: chatID.uuidString)
            #expect(await engineError {
                try await bed.engine.call(ChatsPostSymbol.self, .init(chatID: chatID, question: "Which icon?",
                                                                      suggestions: ["star", "heart"], recommended: "star"), actor: claude)
            } == EngineError(.conflict, "A sound request is already waiting for an answer in this chat."))
        }
    }

    @Test("sounds.list gives the catalogue in order: macOS, each runtime, the project; sounds.read reads a sound of it")
    func listAndRead() async throws {
        try await Self.withSoundEngine { bed in
            let names = try await bed.connection.call(SoundsList.self, .init(projectID: "DEMO"))
            #expect(names == [Self.glass, "iOS 26.1/New/Anticipate.caf", Self.sms, Self.alert])

            let content = try await bed.connection.call(SoundsRead.self, .init(projectID: "DEMO", name: Self.sms))
            #expect(content.name == "sms-received1.caf")
            #expect(Data(base64Encoded: content.dataBase64) == Data("sms".utf8))
            let project = try await bed.connection.call(SoundsRead.self, .init(projectID: "DEMO", name: Self.alert))
            #expect(Data(base64Encoded: project.dataBase64) == Data("alert".utf8))

            #expect(await engineError { try await bed.connection.call(SoundsRead.self, .init(projectID: "DEMO", name: "Project/Sounds/notes.txt")) }
                == EngineError(.notFound, "Sound Project/Sounds/notes.txt not found."))
            #expect(await engineError { try await bed.connection.call(SoundsRead.self, .init(projectID: "DEMO", name: "Project/../x.caf")) }
                == EngineError(.notFound, "Sound Project/../x.caf not found."))
            #expect(await engineError { try await bed.connection.call(SoundsList.self, .init(projectID: "NOPE")) }?.code == .notFound)
        }
    }
}
