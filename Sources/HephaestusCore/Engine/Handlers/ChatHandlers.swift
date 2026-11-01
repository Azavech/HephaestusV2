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
        register(ChatsClose.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsClose(params, actor)
        }
        register(ChatsReopen.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsReopen(params, actor)
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

    // MARK: Lists

    /// `chats.list`: every chat of the project, all kinds, sorted by `updated` descending.
    func chatsList(_ params: ChatsList.Params, _ actor: Actor) async throws -> [ChatMeta] {
        let projectID = try loadedProjectID(params.projectID)
        return domain.chats(of: projectID)
            .filter { !chats.deleting.contains($0.id) }
            .map(apiChatMeta)
            .sorted { $0.updated > $1.updated }
    }

    /// `chats.get`: the metadata and every item after replaying the transcript; without a live
    /// process the pending permission requests are cancelled (docs/chats.md › Cancellation).
    func chatsGet(_ params: ChatsGet.Params, _ actor: Actor) async throws -> ChatTranscript {
        _ = try requireChat(params.chatID)
        let items = try loadTranscript(params.chatID)
        return ChatTranscript(meta: try requireChat(params.chatID), items: items)
    }

    // MARK: Creation

    /// `chats.create` (docs/engine-api.md › chats.create).
    func chatsCreate(_ params: ChatsCreate.Params, _ actor: Actor) async throws -> ChatMeta {
        try ActorRules.requireNoSourcePath(params.message?.attachments, actor)
        let projectID = try Engine.projectIdentifier(params.projectID)
        var ticketID: TicketID?
        var bundleID: BundleID?
        switch params.kind {
        case .feedback:
            throw EngineError.invalid("kind", "feedback chats are created by chats.createFeedback")
        case .project:
            guard params.ticketID == nil else { throw EngineError.invalid("ticketID", "only a ticket chat has a ticket") }
            guard params.bundleID == nil else { throw EngineError.invalid("bundleID", "only a bundle chat has a bundle") }
        case .ticket:
            guard let value = params.ticketID else { throw EngineError.invalid("ticketID", "a ticket chat needs its ticket") }
            guard params.bundleID == nil else { throw EngineError.invalid("bundleID", "only a bundle chat has a bundle") }
            ticketID = try Engine.validated { try ModelRules.ticketID(value) }
            guard Identifiers.projectID(of: ticketID!) == projectID else {
                throw EngineError(.invalid, "\(ticketID!) does not belong to project \(projectID).")
            }
        case .bundle:
            guard let value = params.bundleID else { throw EngineError.invalid("bundleID", "a bundle chat needs its bundle") }
            guard params.ticketID == nil else { throw EngineError.invalid("ticketID", "only a ticket chat has a ticket") }
            bundleID = try Engine.validated { try ModelRules.bundleID(value) }
            guard Identifiers.projectID(of: bundleID!) == projectID else {
                throw EngineError(.invalid, "\(bundleID!) does not belong to project \(projectID).")
            }
        }
        if let settings = params.settings { try Engine.validated { try settings.validate() } }
        func checkTargets() throws -> (Project, URL) {
            guard let project = domain.project(projectID), let root = domain.projectRoot(projectID) else {
                throw EngineError.notFound("Project", projectID)
            }
            if let ticketID, domain.ticket(ticketID) == nil { throw EngineError.notFound("Ticket", ticketID) }
            if let bundleID, domain.bundle(bundleID) == nil { throw EngineError.notFound("Bundle", bundleID) }
            return (project, root)
        }
        let (_, root) = try checkTargets()
        let prepared = try params.message.map { try prepareMessage($0, projectRoot: root) }
        if params.message != nil { _ = try await requireClaudeCLI() }
        let sender = senderName(actor)
        let (project, _) = try checkTargets()

        let meta = try createChat(kind: params.kind, project: project, ticketID: ticketID, bundleID: bundleID,
                                  settings: params.settings, origin: actor)
        if let message = params.message {
            recordDrivingDevice(meta.id, actor)
            let stored = try storeChatAttachments(prepared ?? [], chatID: meta.id)
            try sendChatMessage(meta.id, text: message.text, attachments: stored, sender: sender, origin: actor)
        }
        return try requireChat(meta.id)
    }

    /// Creates a chat: a new id, `New Chat`, `sessionStarted` false, the settings given, else the
    /// project's `chatDefaults`, else the host's `defaultChatSettings`; writes its metadata file
    /// (`chat.updated`), then links it to its ticket or bundle (docs/data-model.md › Changes that
    /// touch several files). A given `bundleStatus` is set on the bundle in the same write.
    private func createChat(kind: ChatKind, project: Project, ticketID: TicketID?, bundleID: BundleID?, settings chosen: ChatSettings?,
                            orchestratorChatID: ChatID? = nil, bundleStatus: BundleStatus? = nil, origin: Actor) throws -> ChatMeta {
        let now = ISODate.now()
        let meta = ChatMeta(id: UUID(), kind: kind, ticketID: ticketID, bundleID: bundleID, orchestratorChatID: orchestratorChatID,
                            created: now, updated: now,
                            settings: chosen ?? project.chatDefaults ?? settings.defaultChatSettings, projectID: project.id)
        let saved = try saveChatMeta(meta, origin: origin)
        chats.scannedChats.insert(meta.id)
        chats.hasTextMessage[meta.id] = false
        if let ticketID { try linkChat(meta.id, toTicket: ticketID, origin: origin) }
        if let bundleID { try linkChat(meta.id, toBundle: bundleID, status: bundleStatus, origin: origin) }
        return saved
    }

    /// `chats.implementTicket` (docs/engine-api.md › chats.implementTicket).
    func chatsImplementTicket(_ params: ChatsImplementTicket.Params, _ actor: Actor) async throws -> ChatMeta {
        try ActorRules.requireNoChatSettings(params.settings, actor)
        let ticketID = try Engine.validated { try ModelRules.ticketID(params.ticketID) }
        if let settings = params.settings { try Engine.validated { try settings.validate() } }
        func checkTicket() throws -> Ticket {
            guard let ticket = domain.ticket(ticketID) else { throw EngineError.notFound("Ticket", ticketID) }
            guard ticket.status != .done else {
                throw EngineError(.conflict, "\(ticketID) is done; set it to To Do or In Progress to implement it.")
            }
            return ticket
        }
        _ = try checkTicket()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        let ticket = try checkTicket()
        guard let projectID = ticket.projectID, let project = domain.project(projectID) else { throw EngineError.notFound("Ticket", ticketID) }
        let orchestrator = orchestratorChat(of: ticketID, actor)
        let meta = try createChat(kind: .ticket, project: project, ticketID: ticketID, bundleID: nil, settings: params.settings,
                                  orchestratorChatID: orchestrator?.chat.id, origin: actor)
        recordDrivingDevice(meta.id, actor)
        let text: String
        if let orchestrator {
            text = Prompts.render(Prompts.text(.implementBundleTicket),
                                  ["ticketID": ticketID, "ticketTitle": ticket.title, "bundleID": orchestrator.bundleID])
        } else {
            text = Prompts.render(Prompts.text(.implementTicket), ["ticketID": ticketID, "ticketTitle": ticket.title])
        }
        try sendChatMessage(meta.id, text: text, attachments: [], sender: sender, origin: actor)
        return try requireChat(meta.id)
    }

    /// The calling chat when it orchestrates the ticket: a claude actor whose chat is of kind
    /// bundle and whose bundle lists the ticket (docs/chats.md › Orchestrated ticket chats).
    private func orchestratorChat(of ticketID: TicketID, _ actor: Actor) -> (chat: ChatMeta, bundleID: BundleID)? {
        guard let chatID = actor.chat, let chat = domain.chat(chatID), chat.kind == .bundle,
              let bundleID = chat.bundleID, let bundle = domain.bundle(bundleID), bundle.ticketIDs.contains(ticketID)
        else { return nil }
        return (chat, bundleID)
    }

    /// `chats.implementBundle` (docs/engine-api.md › chats.implementBundle).
    func chatsImplementBundle(_ params: ChatsImplementBundle.Params, _ actor: Actor) async throws -> ChatMeta {
        try ActorRules.requireNoChatSettings(params.settings, actor)
        let bundleID = try Engine.validated { try ModelRules.bundleID(params.bundleID) }
        if let settings = params.settings { try Engine.validated { try settings.validate() } }
        func checkBundle() throws -> TicketBundle {
            guard let bundle = domain.bundle(bundleID) else { throw EngineError.notFound("Bundle", bundleID) }
            // A started or finished bundle waits for the user to set it back to To Do
            // (docs/tickets.md › Bundle status rules).
            switch bundle.status {
            case .todo: break
            case .inProgress: throw EngineError(.conflict, "\(bundleID) is in progress; set it to To Do to implement it.")
            case .done: throw EngineError(.conflict, "\(bundleID) is done; set it to To Do to implement it.")
            }
            // An id whose ticket no longer exists is not a ticket left to implement
            // (docs/engine-api.md › chats.implementBundle, errors).
            guard bundle.ticketIDs.contains(where: { domain.ticket($0).map { $0.status != .done } ?? false }) else {
                throw EngineError(.conflict, "\(bundleID) has no ticket left to implement.")
            }
            return bundle
        }
        _ = try checkBundle()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        let bundle = try checkBundle()
        guard let projectID = bundle.projectID, let project = domain.project(projectID) else { throw EngineError.notFound("Bundle", bundleID) }
        let meta = try createChat(kind: .bundle, project: project, ticketID: nil, bundleID: bundleID, settings: params.settings,
                                  bundleStatus: .inProgress, origin: actor)
        recordDrivingDevice(meta.id, actor)
        let text = Prompts.render(Prompts.text(.implementBundle), [
            "bundleID": bundleID, "bundleTitle": bundle.title, "bundleTicketIDs": bundle.ticketIDs.joined(separator: ", "),
        ])
        try sendChatMessage(meta.id, text: text, attachments: [], sender: sender, origin: actor)
        return try requireChat(meta.id)
    }

    /// `chats.createFeedback` (docs/engine-api.md › chats.createFeedback, docs/chats.md ›
    /// Feedback message).
    func chatsCreateFeedback(_ params: ChatsCreateFeedback.Params, _ actor: Actor) async throws -> ChatMeta {
        try ActorRules.requireNoSourcePath([params.screenshot], actor)
        let projectID = try Engine.projectIdentifier(params.projectID)
        // docs/engine-api.md › chats.createFeedback, errors
        guard params.screenshot.contentType == "image/png" else { throw EngineError.invalid("screenshot", "use a PNG image (image/png)") }
        guard let base64 = params.screenshot.dataBase64 else { throw EngineError.invalid("screenshot", "give its content in dataBase64") }
        guard let screenshot = Data(base64Encoded: base64) else { throw EngineError.invalid("screenshot", "dataBase64 is not valid base64") }
        guard screenshot.count <= AttachmentUploads.maximumSize else {
            throw EngineError(.invalid, "\(params.screenshot.name) is larger than 20 MB.")
        }
        if let settings = params.settings { try Engine.validated { try settings.validate() } }
        if let contextProject = params.context.projectID, Identifiers.normalizedProjectID(contextProject) == nil {
            throw EngineError.invalid("context.projectID", "use 2 to 8 letters A–Z")
        }
        func checkProject() throws -> Project {
            guard let project = domain.project(projectID) else { throw EngineError.notFound("Project", projectID) }
            return project
        }
        _ = try checkProject()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        let project = try checkProject()
        let meta = try createChat(kind: .feedback, project: project, ticketID: nil, bundleID: nil, settings: params.settings, origin: actor)
        recordDrivingDevice(meta.id, actor)
        let stored = try storeChatAttachments([ChatAttachments.Prepared(name: "screenshot.png", contentType: "image/png", data: screenshot)],
                                              chatID: meta.id)
        let folder = try chatFolder(meta)
        let contextProjectName = params.context.projectID.flatMap { Identifiers.normalizedProjectID($0) }.flatMap { domain.project($0)?.name }
        let text = Engine.feedbackMessage(comment: params.comment, context: params.context, projectName: contextProjectName,
                                          screenshotPath: folder.attachmentFile(path: stored[0].0.path).path)
        try sendChatMessage(meta.id, text: text, attachments: stored, sender: sender, origin: actor)
        return try requireChat(meta.id)
    }

    // MARK: Messages and settings

    /// `chats.send` (docs/engine-api.md › chats.send).
    func chatsSend(_ params: ChatsSend.Params, _ actor: Actor) async throws -> Empty {
        try ActorRules.requireNoSourcePath(params.message.attachments, actor)
        let meta = try requireChat(params.chatID)
        let prepared = try prepareMessage(params.message, projectRoot: try chatFolder(meta).root)
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        _ = try requireChat(params.chatID)
        recordDrivingDevice(params.chatID, actor)
        let stored = try storeChatAttachments(prepared, chatID: params.chatID)
        try sendChatMessage(params.chatID, text: params.message.text, attachments: stored, sender: sender, origin: actor)
        return Empty()
    }

    /// `chats.interrupt`: the stop sequence in the states starting, running and
    /// waitingPermission; nothing in the others.
    func chatsInterrupt(_ params: ChatsInterrupt.Params, _ actor: Actor) async throws -> Empty {
        _ = try requireChat(params.chatID)
        let name = senderName(actor)
        interruptChat(params.chatID, deviceName: name, origin: actor)
        return Empty()
    }

    /// `chats.updateSettings` (docs/chats.md › Changing settings).
    func chatsUpdateSettings(_ params: ChatsUpdateSettings.Params, _ actor: Actor) async throws -> ChatMeta {
        try Engine.validated { try params.settings.validate() }
        var meta = try requireChat(params.chatID)
        let old = meta.settings
        var new = old
        new.model = params.settings.model
        new.effort = params.settings.effort
        new.permissionMode = params.settings.permissionMode
        new.ultracode = params.settings.ultracode
        guard new != old else { return meta }
        meta.settings = new
        let saved = try saveChatMeta(meta, origin: actor)
        applyChatSettingsLive(params.chatID, old: old, new: new)
        return saved
    }

    /// `chats.rename`: the title is trimmed, one line of 1 to 100 characters.
    func chatsRename(_ params: ChatsRename.Params, _ actor: Actor) async throws -> ChatMeta {
        let title = try Engine.validated { try ModelRules.chatTitle(params.title) }
        var meta = try requireChat(params.chatID)
        guard meta.title != title else { return meta }
        meta.title = title
        return try saveChatMeta(meta, origin: actor)
    }

    /// `chats.delete` (docs/chats.md › Persistence): the process is terminated (SIGTERM, SIGKILL
    /// 5 s later) and its token revoked, the chat leaves its ticket's or bundle's `chats`, and its
    /// metadata, transcript and attachment folder go to the Trash. From the start, the lines of
    /// the terminating process are ignored.
    func chatsDelete(_ params: ChatsDelete.Params, _ actor: Actor) async throws -> Empty {
        let chatID = params.chatID
        let meta = try requireChat(chatID)
        let folder = try chatFolder(meta)
        // The cost is known once the transcript has been replayed (docs/costs.md › Deleted chats).
        try? ensureChatScanned(chatID)
        let cost = chats.costs[chatID]?.costUSD
        chats.deleting.insert(chatID)
        defer { chats.deleting.remove(chatID) }
        if let runtime = chats.runtimes.removeValue(forKey: chatID) {
            runtime.idleTask?.cancel()
            runtime.deltaTask?.cancel()
            runtime.pendingMessages = []
            if let process = runtime.process, !process.exited {
                process.cancelTimers()
                terminateChatProcess(process)
                process.log.close()
            }
        }
        await tokens.revokeChatToken(chatID: chatID)
        try? FileManager.default.removeItem(at: dataDirectory.mcpConfigFile(chatID: chatID))
        if let cost, domain.isLoaded(meta.projectID) {
            var project = loaded(meta.projectID).project
            project.deletedChats.append(DeletedChat(id: chatID, title: meta.title, kind: meta.kind, ticketID: meta.ticketID,
                                                    bundleID: meta.bundleID, costUSD: cost, deleted: ISODate.now()))
            try saveProject(project)
            emitProjectUpdated(meta.projectID, origin: actor)
        }
        chats.costs[chatID] = nil
        chats.openQuestionSets[chatID] = nil
        chats.drivingDevices[chatID] = nil
        chats.scannedChats.remove(chatID)
        chats.hasTextMessage[chatID] = nil
        chats.reportedStates[chatID] = nil
        try unlinkChat(chatID, origin: actor)
        try moveChatItemToTrash(folder.chatMetaFile(chatID))
        try moveChatItemToTrash(folder.transcriptFile(chatID))
        try moveChatItemToTrash(folder.chatAttachmentsFolder(chatID))
        domain.removeChat(chatID)
        emit(ChatDeletedEvent.self, .init(projectID: meta.projectID, chatID: chatID), origin: actor)
        return Empty()
    }

    // MARK: Closing

    /// `chats.close` (docs/chats.md › Closing a chat): during a turn the chat closes when the turn
    /// ends; without a turn in progress it closes at once.
    func chatsClose(_ params: ChatsClose.Params, _ actor: Actor) async throws -> Empty {
        try ActorRules.requireOwnChat(params.chatID, actor, refusal: ActorRules.ownChatCloseOnly)
        let meta = try requireChat(params.chatID)
        guard !meta.closed else { return Empty() }
        closeChat(params.chatID, origin: actor)
        return Empty()
    }

    /// `chats.reopen` (docs/chats.md › Closing a chat): `closed` becomes false; the next message
    /// resumes the session.
    func chatsReopen(_ params: ChatsReopen.Params, _ actor: Actor) async throws -> ChatMeta {
        var meta = try requireChat(params.chatID)
        guard meta.closed else { return meta }
        meta.closed = false
        return try saveChatMeta(meta, origin: actor)
    }

    // MARK: Permissions and questions

    /// `chats.answerPermission` (docs/chats.md › Answer).
    func chatsAnswerPermission(_ params: ChatsAnswerPermission.Params, _ actor: Actor) async throws -> Empty {
        _ = try requireChat(params.chatID)
        let name = senderName(actor)
        recordDrivingDevice(params.chatID, actor)
        try answerChatPermission(params.chatID, requestID: params.requestID, decision: params.decision, message: params.message,
                                 deviceName: name, origin: actor)
        return Empty()
    }

    /// `chats.postQuestions` (docs/chats.md › Posting questions).
    func chatsPostQuestions(_ params: ChatsPostQuestions.Params, _ actor: Actor) async throws -> QuestionSet {
        try ActorRules.requireOwnChat(params.chatID, actor)
        try Engine.validated { try ModelRules.questions(params.questions) }
        let questions = params.questions.map { question in
            let recommended = question.recommended.trimmingCharacters(in: .whitespacesAndNewlines)
            let options = question.options.map {
                QuestionOption(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines), description: $0.description)
            }
            // The recommended option goes first; the others keep their relative order.
            let first = options.filter { $0.label == recommended }
            return Question(label: question.label, question: ModelRules.normalizedLineBreaks(question.question),
                            options: first + options.filter { $0.label != recommended }, recommended: recommended)
        }
        _ = try requireChat(params.chatID)
        try ensureChatScanned(params.chatID)
        guard chats.openQuestionSets[params.chatID] == nil else {
            throw EngineError(.conflict, "Questions are already waiting for answers in this chat.")
        }
        let setID = UUID()
        let item = QuestionsItem(id: setID.uuidString, created: ISODate.now(), questionSetID: setID, questions: questions)
        try appendChatItem(.questions(item), chatID: params.chatID, origin: actor)
        chats.openQuestionSets[params.chatID] = item
        emitChatUpdated(params.chatID, origin: actor)
        return QuestionSet(questionSetID: setID, chatID: params.chatID, questions: questions)
    }

    /// `chats.answerQuestion` (docs/chats.md › Answering).
    func chatsAnswerQuestion(_ params: ChatsAnswerQuestion.Params, _ actor: Actor) async throws -> Empty {
        let chatID = params.chatID
        let answer = ModelRules.normalizedLineBreaks(params.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (1...10_000).contains(answer.count) else {
            // docs/engine-api.md › chats.answerQuestion, errors
            throw EngineError.invalid("answer", "use 1 to 10,000 characters")
        }
        func check() throws -> (set: QuestionsItem, completes: Bool) {
            _ = try requireChat(chatID)
            try ensureChatScanned(chatID)
            let set = try questionSet(params.questionSetID, chatID: chatID)
            guard !set.completed, set.questions.contains(where: { set.answers[$0.label] == nil }) else {
                throw EngineError(.conflict, "These questions were already answered.")
            }
            // Any label, in any order; an answer given again replaces the earlier one.
            guard set.questions.contains(where: { $0.label == params.label }) else {
                throw EngineError.invalid("label", "no question of the set has this label")
            }
            let remaining = set.questions.filter { $0.label != params.label && set.answers[$0.label] == nil }
            return (set, remaining.isEmpty)
        }
        var (set, completes) = try check()
        var sender = ""
        if completes {
            _ = try await requireClaudeCLI()
            sender = senderName(actor)
            (set, completes) = try check()
        }
        recordDrivingDevice(chatID, actor)
        set.answers[params.label] = answer
        if completes { set.completed = true }
        try appendChatItem(.questions(set), chatID: chatID, op: .update, origin: actor)
        if completes {
            chats.openQuestionSets[chatID] = nil
            try sendChatMessage(chatID, text: Engine.answersMessage(set), attachments: [], sender: sender, origin: actor)
        } else {
            chats.openQuestionSets[chatID] = set
        }
        return Empty()
    }

    /// The question set `questionSetID` of a chat: the open one, or one of the transcript;
    /// `conflict` when it is completed, `notFound` when the chat has none with this id.
    private func questionSet(_ questionSetID: UUID, chatID: ChatID) throws -> QuestionsItem {
        if let open = chats.openQuestionSets[chatID], open.questionSetID == questionSetID { return open }
        for item in try loadTranscript(chatID) {
            guard case .questions(let set) = item, set.questionSetID == questionSetID else { continue }
            if set.completed { throw EngineError(.conflict, "These questions were already answered.") }
            return set
        }
        throw EngineError.notFound("Question set", questionSetID.uuidString)
    }

    // MARK: Helpers

    /// A project identifier received from a client or Claude, uppercased; `invalid` otherwise.
    static func projectIdentifier(_ value: String) throws -> ProjectID {
        guard let id = Identifiers.normalizedProjectID(value) else { throw EngineError.invalid("projectID", "use 2 to 8 letters A–Z") }
        return id
    }

    /// The identifier of a loaded project; `invalid` or `notFound`.
    private func loadedProjectID(_ value: String) throws -> ProjectID {
        let id = try Engine.projectIdentifier(value)
        guard domain.project(id) != nil else { throw EngineError.notFound("Project", id) }
        return id
    }

    /// Runs a write rule check and turns its ValidationError into the EngineError of the call.
    @discardableResult
    static func validated<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ValidationError {
            throw EngineError(error)
        }
    }
}
