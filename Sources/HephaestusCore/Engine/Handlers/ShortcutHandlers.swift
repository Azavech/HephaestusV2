import Foundation

extension Engine {
    /// The refusal of `chats.postShortcut` in a project of another type than Swift application
    /// (docs/workflow.md › Shortcut requests).
    static let shortcutProjectTypeRefusal = EngineError(.forbidden, "ask_shortcut is available only in Swift application projects.")

    /// `chats.postShortcut` (docs/chats.md › Posting a shortcut request): the chat's own Claude,
    /// then the project type, the rules and the waiting request.
    func chatsPostShortcut(_ params: ChatsPostShortcut.Params, _ actor: Actor) async throws -> ShortcutRequest {
        try ActorRules.requireOwnChat(params.chatID, actor)
        try ActorRules.requireQuestionsAllowed(domain.chat(params.chatID), actor)
        let meta = try requireChat(params.chatID)
        try requireSwiftApplication(meta.projectID, else: Engine.shortcutProjectTypeRefusal)
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let suggestions = params.suggestions.map(trim)
        let recommended = trim(params.recommended)
        let inUse = params.inUse.map { ShortcutInUse(shortcut: trim($0.shortcut), command: trim($0.command)) }
        try Engine.validated {
            try ModelRules.shortcutRequest(question: params.question, suggestions: suggestions, recommended: recommended,
                                           inUse: inUse)
        }
        try ensureChatScanned(params.chatID)
        try requireNoWaitingRequest(params.chatID)
        let requestID = UUID()
        let question = ModelRules.normalizedLineBreaks(params.question)
        let item = ShortcutItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: question,
                                suggestions: suggestions, recommended: recommended, inUse: inUse)
        try appendChatItem(.shortcut(item), chatID: params.chatID, origin: actor)
        chats.openShortcutRequests[params.chatID] = item
        emitChatUpdated(params.chatID, origin: actor)
        return ShortcutRequest(requestID: requestID, chatID: params.chatID, question: question, suggestions: suggestions,
                               recommended: recommended, inUse: inUse)
    }

    /// `chats.answerShortcut` (docs/chats.md › Answering a shortcut request).
    func chatsAnswerShortcut(_ params: ChatsAnswerShortcut.Params, _ actor: Actor) async throws -> Empty {
        let chatID = params.chatID
        let answer = ModelRules.normalizedLineBreaks(params.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (1...10_000).contains(answer.count) else {
            throw EngineError.invalid("answer", "use 1 to 10,000 characters")
        }
        func check() throws -> ShortcutItem {
            _ = try requireChat(chatID)
            try ensureChatScanned(chatID)
            return try shortcutRequest(params.requestID, chatID: chatID)
        }
        _ = try check()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        var request = try check()
        recordDrivingDevice(chatID, actor)
        request.answer = answer
        try appendChatItem(.shortcut(request), chatID: chatID, op: .update, origin: actor)
        chats.openShortcutRequests[chatID] = nil
        try sendChatMessage(chatID, text: Engine.shortcutMessage(answer), attachments: [], sender: sender, origin: actor)
        return Empty()
    }

    /// The shortcut request `requestID` of a chat without answer: the open one, or one of the
    /// transcript; `conflict` when it has an answer, `notFound` when the chat has none with this id.
    private func shortcutRequest(_ requestID: UUID, chatID: ChatID) throws -> ShortcutItem {
        if let open = chats.openShortcutRequests[chatID], open.requestID == requestID { return open }
        for item in try loadTranscript(chatID) {
            guard case .shortcut(let request) = item, request.requestID == requestID else { continue }
            if request.answer != nil { throw EngineError(.conflict, "This shortcut request was already answered.") }
            return request
        }
        throw EngineError.notFound("Shortcut request", requestID.uuidString)
    }
}
