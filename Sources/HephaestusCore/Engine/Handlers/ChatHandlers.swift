import Foundation

extension Engine {
    /// docs/engine-api.md › Chats; what the methods do with Claude is in docs/chats.md › Chat
    /// methods.
    func registerChatHandlers() {
        register(ChatsList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.chatsList(params, actor)
        }
        register(ChatsGet.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.chatsGet(params, actor)
        }
        register(ChatsCreate.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsCreate(params, actor)
        }
        register(ChatsSend.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsSend(params, actor)
        }
        register(ChatsInterrupt.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsInterrupt(params, actor)
        }
        register(ChatsUpdateSettings.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsUpdateSettings(params, actor)
        }
        register(ChatsRename.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.chatsRename(params, actor)
        }
        register(ChatsDelete.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsDelete(params, actor)
        }
        register(ChatsAnswerPermission.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsAnswerPermission(params, actor)
        }
        register(ChatsPostQuestions.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsPostQuestions(params, actor)
        }
        register(ChatsAnswerQuestion.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsAnswerQuestion(params, actor)
        }
        register(ChatsImplementTicket.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.chatsImplementTicket(params, actor)
        }
        register(ChatsImplementBundle.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.chatsImplementBundle(params, actor)
        }
        register(ChatsCreateFeedback.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsCreateFeedback(params, actor)
        }
    }

    // STUB: core-claude — docs/engine-api.md › chats.list.
    func chatsList(_ params: ChatsList.Params, _ actor: Actor) async throws -> [ChatMeta] {
        throw EngineError.notImplemented(ChatsList.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.get.
    func chatsGet(_ params: ChatsGet.Params, _ actor: Actor) async throws -> ChatTranscript {
        throw EngineError.notImplemented(ChatsGet.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.create.
    func chatsCreate(_ params: ChatsCreate.Params, _ actor: Actor) async throws -> ChatMeta {
        try ActorRules.requireNoSourcePath(params.message?.attachments, actor)
        throw EngineError.notImplemented(ChatsCreate.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.send.
    func chatsSend(_ params: ChatsSend.Params, _ actor: Actor) async throws -> Empty {
        try ActorRules.requireNoSourcePath(params.message.attachments, actor)
        throw EngineError.notImplemented(ChatsSend.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.interrupt.
    func chatsInterrupt(_ params: ChatsInterrupt.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(ChatsInterrupt.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.updateSettings.
    func chatsUpdateSettings(_ params: ChatsUpdateSettings.Params, _ actor: Actor) async throws -> ChatMeta {
        throw EngineError.notImplemented(ChatsUpdateSettings.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.rename.
    func chatsRename(_ params: ChatsRename.Params, _ actor: Actor) async throws -> ChatMeta {
        throw EngineError.notImplemented(ChatsRename.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.delete.
    func chatsDelete(_ params: ChatsDelete.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(ChatsDelete.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.answerPermission.
    func chatsAnswerPermission(_ params: ChatsAnswerPermission.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(ChatsAnswerPermission.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.postQuestions; the question rules are
    // `ModelRules.questions`.
    func chatsPostQuestions(_ params: ChatsPostQuestions.Params, _ actor: Actor) async throws -> QuestionSet {
        try ActorRules.requireOwnChat(params.chatID, actor)
        throw EngineError.notImplemented(ChatsPostQuestions.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.answerQuestion.
    func chatsAnswerQuestion(_ params: ChatsAnswerQuestion.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(ChatsAnswerQuestion.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.implementTicket.
    func chatsImplementTicket(_ params: ChatsImplementTicket.Params, _ actor: Actor) async throws -> ChatMeta {
        try ActorRules.requireNoChatSettings(params.settings, actor)
        throw EngineError.notImplemented(ChatsImplementTicket.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.implementBundle.
    func chatsImplementBundle(_ params: ChatsImplementBundle.Params, _ actor: Actor) async throws -> ChatMeta {
        try ActorRules.requireNoChatSettings(params.settings, actor)
        throw EngineError.notImplemented(ChatsImplementBundle.name)
    }

    // STUB: core-claude — docs/engine-api.md › chats.createFeedback.
    func chatsCreateFeedback(_ params: ChatsCreateFeedback.Params, _ actor: Actor) async throws -> ChatMeta {
        try ActorRules.requireNoSourcePath([params.screenshot], actor)
        throw EngineError.notImplemented(ChatsCreateFeedback.name)
    }
}
