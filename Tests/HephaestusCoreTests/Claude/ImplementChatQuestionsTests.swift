import Foundation
import Testing
@testable import HephaestusCore

/// Implement chats ask no question until the user writes in them: `chats.implementTicket` writes
/// `questionsBlocked`, the seven requests to the user are refused while it is set, and the user's
/// first message removes it (docs/workflow.md › Implement chats, docs/chats.md › Implement and
/// feedback chats).
@Suite("Implement chat questions")
struct ImplementChatQuestionsTests {
    static let refusal = EngineError(
        .forbidden, "This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.")

    static let question = Question(label: "A", question: "Which name?",
                                   options: [QuestionOption(label: "lightAndDark"), QuestionOption(label: "pair")], recommended: "lightAndDark")

    /// The error of each of the seven requests posted by the chat's own Claude, in the order
    /// questions, symbol, color, sound, shortcut, font, animation; nil for a request that passed.
    static func requestErrors(_ bed: ChatTestBed, _ chatID: ChatID) async -> [EngineError?] {
        let claude = Actor.claude(chatID: chatID.uuidString)
        let engine = bed.engine
        return [
            await engineError { _ = try await engine.call(ChatsPostQuestions.self, .init(chatID: chatID, questions: [question]), actor: claude) },
            await engineError {
                _ = try await engine.call(ChatsPostSymbol.self, .init(chatID: chatID, question: "Which icon?", suggestions: ["star", "heart"],
                                                                      recommended: "star"), actor: claude)
            },
            await engineError {
                _ = try await engine.call(ChatsPostColor.self, .init(chatID: chatID, question: "Which color?",
                                                                     suggestions: [.color("#FF9500"), .color("systemBlue")],
                                                                     recommended: .color("#FF9500")), actor: claude)
            },
            await engineError {
                _ = try await engine.call(ChatsPostSound.self, .init(chatID: chatID, question: "Which sound?",
                                                                     suggestions: ["macOS/Glass.aiff", "macOS/Ping.aiff"],
                                                                     recommended: "macOS/Glass.aiff"), actor: claude)
            },
            await engineError {
                _ = try await engine.call(ChatsPostShortcut.self, .init(chatID: chatID, question: "Which shortcut?", suggestions: ["⇧⌘K", "⌥⌘K"],
                                                                        recommended: "⇧⌘K", inUse: []), actor: claude)
            },
            await engineError {
                _ = try await engine.call(ChatsPostFont.self, .init(chatID: chatID, question: "Which font?", sample: "Tickets",
                                                                    suggestions: [".headline", ".body"], recommended: ".headline"), actor: claude)
            },
            await engineError {
                _ = try await engine.call(ChatsPostAnimation.self, .init(chatID: chatID, question: "Which animation?",
                                                                         suggestions: [".spring", ".smooth"], recommended: ".spring"),
                                          actor: claude)
            },
        ]
    }

    /// The chat's metadata file as written on disk.
    static func metadataFile(_ bed: ChatTestBed, _ chatID: ChatID) throws -> String {
        try String(contentsOf: bed.folder.chatMetaFile(chatID), encoding: .utf8)
    }

    static func meta(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> ChatMeta {
        try await bed.connection.call(ChatsGet.self, .init(chatID: chatID)).meta
    }

    @Test("Implement: the chat gets questionsBlocked; the seven requests are refused, the implement message keeps the key, the user's message removes it")
    func implementChat() async throws {
        try await withChatEngine { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            let chat = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"))
            #expect(chat.questionsBlocked)
            #expect(chat.orchestratorChatID == nil)
            #expect(try Self.metadataFile(bed, chat.id).contains("questionsBlocked: true\n"))
            // The implement message, a user message sent by the engine, does not remove the key.
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await Self.meta(bed, chat.id).questionsBlocked)

            // Every request is refused with the same message, before its other checks: the
            // project DEMO is not a Swift application and the suggestions are not checked.
            let errors = await Self.requestErrors(bed, chat.id)
            #expect(errors == Array(repeating: Self.refusal, count: 7))
            #expect(try await bed.transcript(chat.id).allSatisfy { if case .questions = $0 { false } else { true } })
            #expect(await bed.state(chat.id) == .idle)
            // The token check stays first.
            #expect(await engineError {
                _ = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [Self.question]),
                                              actor: .claude(chatID: Actor.externalChatID))
            } == ActorRules.ownChatOnly)

            // The user's first message removes the key, in the metadata file too; then Claude asks.
            try await bed.send(chat.id, "Call it lightAndDark")
            #expect(try await !Self.meta(bed, chat.id).questionsBlocked)
            #expect(try !Self.metadataFile(bed, chat.id).contains("questionsBlocked"))
            #expect(await bed.waitForState(chat.id, .idle))
            let set = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [Self.question]),
                                                actor: .claude(chatID: chat.id.uuidString))
            #expect(set.chatID == chat.id)
        }
    }

    @Test("implement_ticket from another chat, and a chat opened with New Chat: only the first gets questionsBlocked")
    func implementTicketAndNewChat() async throws {
        try await withChatEngine { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            let project = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(project.id, .idle))
            let implement = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"),
                                                      actor: .claude(chatID: project.id.uuidString))
            #expect(implement.questionsBlocked)
            #expect(await bed.waitForState(implement.id, .idle))
            #expect(await Self.requestErrors(bed, implement.id).first == Self.refusal)

            // A ticket chat created by chats.create, and the project chat, ask as usual.
            let newChat = try await bed.createChat(kind: .ticket, ticketID: "DEMO-1", message: "Why does it fail?")
            #expect(!newChat.questionsBlocked)
            #expect(try !Self.metadataFile(bed, newChat.id).contains("questionsBlocked"))
            #expect(await bed.waitForState(newChat.id, .idle))
            #expect(await Self.requestErrors(bed, newChat.id).first == .some(nil))
            #expect(!project.questionsBlocked)
            #expect(await Self.requestErrors(bed, project.id).first == .some(nil))
        }
    }

    @Test("Orchestration: the ticket chats a bundle chat starts get questionsBlocked; the bundle chat still asks")
    func orchestratedChat() async throws {
        try await withChatEngine { bed in
            _ = try await ChatWorktreeTests.gitRepository(bed)
            let orchestrator = try await ChatWorktreeTests.orchestrator(bed)
            #expect(!orchestrator.questionsBlocked)
            let chat = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"),
                                                 actor: .claude(chatID: orchestrator.id.uuidString))
            #expect(chat.orchestratorChatID == orchestrator.id)
            #expect(chat.questionsBlocked)
            #expect(try Self.metadataFile(bed, chat.id).contains("questionsBlocked: true\n"))
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(await Self.requestErrors(bed, chat.id) == Array(repeating: Self.refusal, count: 7))

            #expect(await bed.waitForState(orchestrator.id, .idle))
            #expect(await Self.requestErrors(bed, orchestrator.id).first == .some(nil))

            try await bed.send(chat.id, "Use the recommended name")
            #expect(try await !Self.meta(bed, chat.id).questionsBlocked)
        }
    }
}
