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
        register(ChatsClose.self, actors: [.user, .claude]) { [unowned self] params, actor in
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
        register(ChatsPostSymbol.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsPostSymbol(params, actor)
        }
        register(ChatsAnswerSymbol.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsAnswerSymbol(params, actor)
        }
        register(ChatsPostColor.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsPostColor(params, actor)
        }
        register(ChatsAnswerColor.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsAnswerColor(params, actor)
        }
        register(ChatsPostSound.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsPostSound(params, actor)
        }
        register(ChatsAnswerSound.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsAnswerSound(params, actor)
        }
        register(ChatsPostShortcut.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsPostShortcut(params, actor)
        }
        register(ChatsAnswerShortcut.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsAnswerShortcut(params, actor)
        }
        register(ChatsPostFont.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsPostFont(params, actor)
        }
        register(ChatsAnswerFont.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsAnswerFont(params, actor)
        }
        register(ChatsPostAnimation.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsPostAnimation(params, actor)
        }
        register(ChatsAnswerAnimation.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsAnswerAnimation(params, actor)
        }
        register(ChatsPostImages.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsPostImages(params, actor)
        }
        register(ChatsImplementTicket.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.chatsImplementTicket(params, actor)
        }
        register(ChatsImplementBundle.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.chatsImplementBundle(params, actor)
        }
        register(ChatsWatchCI.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.chatsWatchCI(params, actor)
        }
        register(ChatsCreateFeedback.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsCreateFeedback(params, actor)
        }
        register(ChatsCreateSetup.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsCreateSetup(params, actor)
        }
        register(ChatsListAgents.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsListAgents(params, actor)
        }
        register(ChatsAgentTranscript.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsAgentTranscript(params, actor)
        }
        register(ChatsStopWorkflow.self, actors: [.user]) { [unowned self] params, actor in
            try await self.chatsStopWorkflow(params, actor)
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

    /// `chats.listAgents` (docs/chats.md › Agents): the workflows and agents of every chat of the
    /// project that has any, sorted by chat id.
    func chatsListAgents(_ params: ChatsListAgents.Params, _ actor: Actor) async throws -> [ChatAgents] {
        let projectID = try loadedProjectID(params.projectID)
        return domain.chats(of: projectID)
            .filter { !chats.deleting.contains($0.id) }
            .map { chatAgents($0.id, projectID: projectID) }
            .filter { !$0.isEmpty }
            .sorted { $0.chatID.uuidString < $1.chatID.uuidString }
    }

    /// `chats.agentTranscript` (docs/chats.md › Agent transcript lines, › Sub-agent transcripts).
    func chatsAgentTranscript(_ params: ChatsAgentTranscript.Params, _ actor: Actor) async throws -> [ChatItem] {
        try agentTranscript(params.chatID, agentID: params.agentID)
    }

    /// `chats.stopWorkflow` (docs/chats.md › Stopping a workflow).
    func chatsStopWorkflow(_ params: ChatsStopWorkflow.Params, _ actor: Actor) async throws -> Empty {
        _ = try requireChat(params.chatID)
        try stopWorkflow(params.chatID, workflowID: params.workflowID)
        return Empty()
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
        case .ci:
            throw EngineError.invalid("kind", "CI chats are created by chats.watchCI")
        case .setup:
            throw EngineError.invalid("kind", "Auto Setup chats are created by chats.createSetup")
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
            try sendChatMessage(meta.id, text: message.text, attachments: stored, linkedItems: message.linkedItems ?? [],
                                sender: sender, origin: actor)
        }
        return try requireChat(meta.id)
    }

    /// Creates a chat: a new id, `New Chat`, `sessionStarted` false, the settings given, else the
    /// project's `chatDefaults`, else the host's `defaultChatSettings`; writes its metadata file
    /// (`chat.updated`), then links it to its ticket or bundle (docs/data-model.md › Changes that
    /// touch several files). A given `bundleStatus` is set on the bundle in the same write.
    private func createChat(kind: ChatKind, project: Project?, ticketID: TicketID?, bundleID: BundleID?, settings chosen: ChatSettings?,
                            orchestratorChatID: ChatID? = nil, imageID: UUID? = nil, questionsBlocked: Bool = false,
                            bundleStatus: BundleStatus? = nil, origin: Actor) throws -> ChatMeta {
        let now = ISODate.now()
        let meta = ChatMeta(id: UUID(), kind: kind, ticketID: ticketID, bundleID: bundleID, orchestratorChatID: orchestratorChatID,
                            imageID: imageID, created: now, updated: now,
                            settings: chosen ?? project?.chatDefaults ?? settings.defaultChatSettings, questionsBlocked: questionsBlocked,
                            projectID: project?.id ?? "")
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
        // An orchestrated ticket chat works on its own branch in its own worktree, created before
        // the chat (docs/chats.md › Branch and worktree).
        if let orchestrator = orchestratorChat(of: ticketID, actor), let projectID = try checkTicket().projectID,
           let root = domain.projectRoot(projectID) {
            try await prepareWorktree(projectID: projectID, root: root, bundleID: orchestrator.bundleID, ticketID: ticketID)
        }
        let ticket = try checkTicket()
        guard let projectID = ticket.projectID, let project = domain.project(projectID) else { throw EngineError.notFound("Ticket", ticketID) }
        let orchestrator = orchestratorChat(of: ticketID, actor)
        // An orchestrated ticket chat takes its orchestrator's settings (docs/chats.md ›
        // Orchestrated ticket chats). Every chat created here is an implement chat, which asks no
        // question until the user writes in it (docs/chats.md › Implement and feedback chats).
        let meta = try createChat(kind: .ticket, project: project, ticketID: ticketID, bundleID: nil,
                                  settings: params.settings ?? orchestrator?.chat.settings,
                                  orchestratorChatID: orchestrator?.chat.id, questionsBlocked: true, origin: actor)
        recordDrivingDevice(meta.id, actor)
        // The first message calls the internal skill implement-ticket (docs/chats.md › Implement
        // and feedback chats).
        let text = Engine.implementTicketMessage(ticketID: ticketID, bundleID: orchestrator?.bundleID)
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
        // The first message calls the internal skill implement-bundle (docs/chats.md › Implement
        // and feedback chats).
        try sendChatMessage(meta.id, text: Engine.implementBundleMessage(bundleID: bundleID), attachments: [], sender: sender, origin: actor)
        return try requireChat(meta.id)
    }

    /// `chats.watchCI` (docs/engine-api.md › chats.watchCI, docs/chats.md › CI chats): a chat of
    /// kind ci whose orchestrator is the calling chat, linked to that chat's ticket or bundle,
    /// with its settings, and whose first message names the commit.
    func chatsWatchCI(_ params: ChatsWatchCI.Params, _ actor: Actor) async throws -> ChatMeta {
        _ = try ciOrchestrator(actor)
        guard Engine.isFullCommitHash(params.commit) else {
            throw EngineError.invalid("commit", "give the full hash of the pushed commit, 40 or 64 hexadecimal characters")
        }
        func checkTargets() throws -> (orchestrator: ChatMeta, project: Project) {
            let orchestrator = try ciOrchestrator(actor)
            guard let project = domain.project(orchestrator.projectID) else { throw EngineError.notFound("Project", orchestrator.projectID) }
            guard githubPage(of: project.id) != nil else { throw EngineError(.conflict, "\(project.id) has no GitHub page.") }
            if let ticketID = orchestrator.ticketID, domain.ticket(ticketID) == nil { throw EngineError.notFound("Ticket", ticketID) }
            if let bundleID = orchestrator.bundleID, domain.bundle(bundleID) == nil { throw EngineError.notFound("Bundle", bundleID) }
            return (orchestrator, project)
        }
        _ = try checkTargets()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        let (orchestrator, project) = try checkTargets()
        // The CI chat takes its orchestrator's settings and is linked to its ticket or its bundle
        // (docs/chats.md › CI chats).
        let meta = try createChat(kind: .ci, project: project,
                                  ticketID: orchestrator.kind == .ticket ? orchestrator.ticketID : nil,
                                  bundleID: orchestrator.kind == .bundle ? orchestrator.bundleID : nil,
                                  settings: orchestrator.settings, orchestratorChatID: orchestrator.id, origin: actor)
        try sendChatMessage(meta.id, text: Engine.ciMessage(commit: params.commit), attachments: [], sender: sender, origin: actor)
        return try requireChat(meta.id)
    }

    /// The calling chat of chats.watchCI, which becomes the orchestrator of the CI chat: the chat
    /// of a claude actor, of kind ticket or bundle and without orchestrator (docs/engine-api.md ›
    /// chats.watchCI).
    private func ciOrchestrator(_ actor: Actor) throws -> ChatMeta {
        guard let chatID = actor.chat else { throw ActorRules.ownChatCIOnly }
        guard let chat = domain.chat(chatID) else { throw EngineError.notFound("Chat", chatID.uuidString) }
        guard chat.kind == .ticket || chat.kind == .bundle, chat.orchestratorChatID == nil else { throw ActorRules.ciOrchestratorOnly }
        return chat
    }

    /// Whether `commit` is a full commit hash: 40 or 64 hexadecimal characters, in any case
    /// (docs/engine-api.md › chats.watchCI).
    static func isFullCommitHash(_ commit: String) -> Bool {
        let bytes = Array(commit.utf8)
        guard bytes.count == 40 || bytes.count == 64 else { return false }
        return bytes.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The first message of a CI chat (docs/chats.md › CI chats).
    static func ciMessage(commit: String) -> String {
        "Watch the CI of commit \(commit.lowercased())."
    }

    /// `chats.createFeedback` (docs/engine-api.md › chats.createFeedback, docs/chats.md ›
    /// Feedback message).
    func chatsCreateFeedback(_ params: ChatsCreateFeedback.Params, _ actor: Actor) async throws -> ChatMeta {
        try ActorRules.requireNoSourcePath(params.screenshot.map { [$0] }, actor)
        try ActorRules.requireNoSourcePath(params.attachments, actor)
        let projectID = try Engine.projectIdentifier(params.projectID)
        // docs/engine-api.md › chats.createFeedback, errors; feedback sent without a screenshot
        // stores no screenshot.
        var screenshots: [ChatAttachments.Prepared] = []
        if let upload = params.screenshot {
            guard upload.contentType == "image/png" else { throw EngineError.invalid("screenshot", "use a PNG image (image/png)") }
            guard let base64 = upload.dataBase64 else { throw EngineError.invalid("screenshot", "give its content in dataBase64") }
            guard let screenshot = Data(base64Encoded: base64) else { throw EngineError.invalid("screenshot", "dataBase64 is not valid base64") }
            guard screenshot.count <= AttachmentUploads.maximumSize else {
                throw EngineError(.invalid, "\(upload.name) is larger than 20 MB.")
            }
            screenshots = [ChatAttachments.Prepared(name: "screenshot.png", contentType: "image/png", data: screenshot)]
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
        let files = try feedbackFiles(params.attachments ?? [], projectID: projectID, screenshotSize: screenshots.first?.data.count ?? 0)
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        let project = try checkProject()
        let meta = try createChat(kind: .feedback, project: project, ticketID: nil, bundleID: nil, settings: params.settings, origin: actor)
        recordDrivingDevice(meta.id, actor)
        let stored = try storeChatAttachments(screenshots, chatID: meta.id)
        // The added files follow the screenshot (docs/chats.md › Feedback message).
        let storedFiles = try storeChatAttachments(files, chatID: meta.id)
        let folder = try chatFolder(meta)
        let contextProjectName = params.context.projectID.flatMap { Identifiers.normalizedProjectID($0) }.flatMap { domain.project($0)?.name }
        let text = Engine.feedbackMessage(comment: params.comment, context: params.context, projectName: contextProjectName,
                                          screenshotPath: stored.first.map { folder.attachmentFile(path: $0.0.path).path },
                                          attachmentPaths: storedFiles.map { folder.attachmentFile(path: $0.0.path).path })
        // The text holds the path of every attachment, so the message lists no file.
        try sendChatMessage(meta.id, text: text, attachments: stored + storedFiles, sender: sender, listsFiles: false, origin: actor)
        return try requireChat(meta.id)
    }

    /// `chats.createSetup` (docs/engine-api.md › chats.createSetup, docs/chats.md › Auto Setup
    /// chats): a chat of kind setup for the image, in the project given or in no project, whose
    /// first message calls the internal skill auto-setup.
    func chatsCreateSetup(_ params: ChatsCreateSetup.Params, _ actor: Actor) async throws -> ChatMeta {
        let projectID = try params.projectID.map { try Engine.projectIdentifier($0) }
        if let settings = params.settings { try Engine.validated { try settings.validate() } }
        func checkTargets() throws -> Project? {
            guard vmImages.images[params.imageID] != nil, !vmImages.deleting.contains(params.imageID) else {
                throw EngineError.notFound("Image", params.imageID.uuidString)
            }
            guard let projectID else { return nil }
            guard let project = domain.project(projectID) else { throw EngineError.notFound("Project", projectID) }
            return project
        }
        _ = try checkTargets()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        let project = try checkTargets()
        let meta = try createChat(kind: .setup, project: project, ticketID: nil, bundleID: nil, settings: params.settings,
                                  imageID: params.imageID, origin: actor)
        recordDrivingDevice(meta.id, actor)
        try sendChatMessage(meta.id, text: Engine.autoSetupMessage(imageID: params.imageID), attachments: [], sender: sender, origin: actor)
        return try requireChat(meta.id)
    }

    /// The files the user added to a feedback, checked and read as chat attachments. With the
    /// screenshot, when the feedback has one, they are the attachments of one request: at most
    /// 20 MiB together (docs/engine-api.md › chats.createFeedback, › Limits).
    private func feedbackFiles(_ uploads: [AttachmentUpload], projectID: ProjectID, screenshotSize: Int) throws -> [ChatAttachments.Prepared] {
        guard let root = domain.projectRoot(projectID) else { throw EngineError.notFound("Project", projectID) }
        let files = try ChatAttachments.prepare(uploads, projectRoot: root)
        guard files.reduce(screenshotSize, { $0 + $1.data.count }) <= AttachmentUploads.maximumSize else {
            throw EngineError(.invalid, "The attachments of one request exceed 20 MB.")
        }
        return files
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
        // The user's message lifts the refusal of questions in an implement chat (docs/engine-api.md ›
        // chats.send).
        try sendChatMessage(params.chatID, text: params.message.text, attachments: stored,
                            linkedItems: params.message.linkedItems ?? [], sender: sender, unblocksQuestions: true, origin: actor)
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
        new.contextWindow = params.settings.contextWindow
        guard new != old else { return meta }
        meta.settings = new
        let saved = try saveChatMeta(meta, origin: actor)
        applyChatSettingsLive(params.chatID, old: old, new: new, origin: actor)
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
    /// 5 s later), its port forwards stopped and its token revoked, the chat leaves its ticket's or
    /// bundle's `chats`, and its metadata, transcript and attachment folder go to the Trash. From
    /// the start, the lines of the terminating process are ignored.
    func chatsDelete(_ params: ChatsDelete.Params, _ actor: Actor) async throws -> Empty {
        let meta = try requireChat(params.chatID)
        try await discardChat(meta, movesFilesToTrash: true, actor)
        return Empty()
    }

    /// Ends a chat as `chats.delete` does, its files moved to the Trash or, for a chat without a
    /// project whose image is deleted, left to the deletion of the image's folder
    /// (docs/virtual-machines.md › Deleting an image).
    func discardChat(_ meta: ChatMeta, movesFilesToTrash: Bool, _ actor: Actor) async throws {
        let chatID = meta.id
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
        // The exit of the process no longer reaches `chatProcessExited`, which stops the port
        // forwards of a chat whose process exits (docs/chats.md › Exit handling and logs).
        stopPortForwards(ofChat: chatID)
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
        chats.mentions[chatID] = nil
        chats.openQuestionSets[chatID] = nil
        chats.openSymbolRequests[chatID] = nil
        chats.openColorRequests[chatID] = nil
        chats.openSoundRequests[chatID] = nil
        chats.openShortcutRequests[chatID] = nil
        chats.openFontRequests[chatID] = nil
        chats.openAnimationRequests[chatID] = nil
        chats.ciQuestionAllowances.remove(chatID)
        chats.drivingDevices[chatID] = nil
        chats.scannedChats.remove(chatID)
        chats.hasTextMessage[chatID] = nil
        chats.reportedStates[chatID] = nil
        chats.reportedBackgroundWork[chatID] = nil
        chats.reportedCompactingSince[chatID] = nil
        forgetAgents(chatID)
        try unlinkChat(chatID, origin: actor)
        if movesFilesToTrash {
            try moveChatItemToTrash(folder.chatMetaFile(chatID))
            try moveChatItemToTrash(folder.transcriptFile(chatID))
            try moveChatItemToTrash(folder.chatAttachmentsFolder(chatID))
        }
        domain.removeChat(chatID)
        emit(ChatDeletedEvent.self, .init(projectID: meta.projectID, chatID: chatID), origin: actor)
    }

    // MARK: Closing

    /// `chats.close` (docs/engine-api.md › chats.close, docs/chats.md › Closing a chat): a chat
    /// closed by the user, or Claude's own chat, closes when its turn ends, or at once without a
    /// turn in progress; another chat of Claude's project closes at once, and is refused while a
    /// turn is in progress in it.
    func chatsClose(_ params: ChatsClose.Params, _ actor: Actor) async throws -> Empty {
        if actor.kind == .claude, actor.chat == nil { throw ActorRules.ownChatCloseOnly }
        let meta = try requireChat(params.chatID)
        let other = actor.kind == .claude && actor.chat != params.chatID
        if other, actor.chat.flatMap({ chatMeta($0) })?.projectID != meta.projectID {
            throw ActorRules.otherProjectChat(params.chatID)
        }
        guard !meta.closed else { return Empty() }
        if other, let runtime = chats.runtimes[params.chatID], runtime.starting || runtime.turnInProgress {
            throw ActorRules.turnInProgress(params.chatID)
        }
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
        // After a CI failure report, an implement chat may post one question set
        // (docs/chats.md › Reports to the orchestrator).
        try ActorRules.requireQuestionsAllowed(domain.chat(params.chatID), actor,
                                               allowedOnce: chats.ciQuestionAllowances.contains(params.chatID))
        try Engine.validated { try ModelRules.questions(params.questions) }
        let questions = params.questions.map { question in
            let recommended = Set(question.recommended.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            let options = question.options.map {
                QuestionOption(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines), description: $0.description)
            }
            // The recommended options go first, in their order among the options; the others keep
            // their relative order.
            let first = options.filter { recommended.contains($0.label) }
            return Question(label: question.label, question: ModelRules.normalizedLineBreaks(question.question), kind: question.kind,
                            options: first + options.filter { !recommended.contains($0.label) }, recommended: first.map(\.label),
                            minChoices: question.minChoices, maxChoices: question.maxChoices)
        }
        _ = try requireChat(params.chatID)
        try ensureChatScanned(params.chatID)
        try requireNoWaitingRequest(params.chatID)
        let setID = UUID()
        let item = QuestionsItem(id: setID.uuidString, created: ISODate.now(), questionSetID: setID, questions: questions)
        try appendChatItem(.questions(item), chatID: params.chatID, origin: actor)
        chats.openQuestionSets[params.chatID] = item
        chats.ciQuestionAllowances.remove(params.chatID)
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
            guard let question = set.questions.first(where: { $0.label == params.label }) else {
                throw EngineError.invalid("label", "no question of the set has this label")
            }
            if question.kind == .multiple, answer != ModelRules.skippedAnswer {
                guard let choices = ModelRules.multipleChoices(in: answer) else {
                    throw EngineError.invalid("answer", "write one line \"- <choice>\" per choice, or Skipped")
                }
                guard choices.count >= question.fewestChoices, choices.count <= question.maxChoices ?? .max else {
                    throw EngineError.invalid("answer", "the number of choices must be between minChoices and maxChoices")
                }
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

    /// A chat has at most one waiting request: a question set that is not completed, or a symbol
    /// request, a color request, a sound request, a shortcut request, a font request or an
    /// animation request without answer (docs/chats.md › Posting questions, › Posting a symbol
    /// request, › Posting a color request, › Posting a sound request, › Posting a shortcut request,
    /// › Posting a font request, › Posting an animation request).
    func requireNoWaitingRequest(_ chatID: ChatID) throws {
        guard chats.openQuestionSets[chatID] == nil else {
            throw EngineError(.conflict, "Questions are already waiting for answers in this chat.")
        }
        guard chats.openSymbolRequests[chatID] == nil else {
            throw EngineError(.conflict, "A symbol request is already waiting for an answer in this chat.")
        }
        guard chats.openColorRequests[chatID] == nil else {
            throw EngineError(.conflict, "A color request is already waiting for an answer in this chat.")
        }
        guard chats.openSoundRequests[chatID] == nil else {
            throw EngineError(.conflict, "A sound request is already waiting for an answer in this chat.")
        }
        guard chats.openShortcutRequests[chatID] == nil else {
            throw EngineError(.conflict, "A shortcut request is already waiting for an answer in this chat.")
        }
        guard chats.openFontRequests[chatID] == nil else {
            throw EngineError(.conflict, "A font request is already waiting for an answer in this chat.")
        }
        guard chats.openAnimationRequests[chatID] == nil else {
            throw EngineError(.conflict, "An animation request is already waiting for an answer in this chat.")
        }
    }

    /// The ask tools of Swift application projects (docs/projects.md › Project types): `refusal`
    /// when the chat's project has another type.
    func requireSwiftApplication(_ projectID: ProjectID, else refusal: EngineError) throws {
        guard domain.project(projectID)?.type == .swiftApplication else { throw refusal }
    }

    /// The symbol catalogue of this Mac, the main device; what could not be read is logged the
    /// first time `chats.postSymbol` or `projects.update` uses it (docs/chats.md › Symbol
    /// catalogue).
    func symbolCatalog() -> SFSymbolCatalog {
        let catalog = SFSymbolCatalog.system
        if !chats.loggedSymbolCatalogProblems {
            chats.loggedSymbolCatalogProblems = true
            for problem in catalog.problems {
                log.error(.claude, "symbol catalogue: \(problem)")
            }
        }
        return catalog
    }

    /// `chats.postSymbol` (docs/chats.md › Posting a symbol request).
    func chatsPostSymbol(_ params: ChatsPostSymbol.Params, _ actor: Actor) async throws -> SymbolRequest {
        try ActorRules.requireOwnChat(params.chatID, actor)
        try ActorRules.requireQuestionsAllowed(domain.chat(params.chatID), actor)
        let catalog = symbolCatalog()
        let suggestions = params.suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let recommended = params.recommended.trimmingCharacters(in: .whitespacesAndNewlines)
        try Engine.validated {
            try ModelRules.symbolRequest(question: params.question, suggestions: suggestions, recommended: recommended,
                                         isSymbol: catalog.contains)
        }
        _ = try requireChat(params.chatID)
        try ensureChatScanned(params.chatID)
        try requireNoWaitingRequest(params.chatID)
        let requestID = UUID()
        let question = ModelRules.normalizedLineBreaks(params.question)
        let item = SymbolItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: question,
                              suggestions: suggestions, recommended: recommended)
        try appendChatItem(.symbol(item), chatID: params.chatID, origin: actor)
        chats.openSymbolRequests[params.chatID] = item
        emitChatUpdated(params.chatID, origin: actor)
        return SymbolRequest(requestID: requestID, chatID: params.chatID, question: question, suggestions: suggestions,
                             recommended: recommended)
    }

    /// `chats.answerSymbol` (docs/chats.md › Answering a symbol request).
    func chatsAnswerSymbol(_ params: ChatsAnswerSymbol.Params, _ actor: Actor) async throws -> Empty {
        let chatID = params.chatID
        let answer = ModelRules.normalizedLineBreaks(params.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (1...10_000).contains(answer.count) else {
            throw EngineError.invalid("answer", "use 1 to 10,000 characters")
        }
        func check() throws -> SymbolItem {
            _ = try requireChat(chatID)
            try ensureChatScanned(chatID)
            return try symbolRequest(params.requestID, chatID: chatID)
        }
        _ = try check()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        var request = try check()
        recordDrivingDevice(chatID, actor)
        request.answer = answer
        try appendChatItem(.symbol(request), chatID: chatID, op: .update, origin: actor)
        chats.openSymbolRequests[chatID] = nil
        try sendChatMessage(chatID, text: Engine.symbolMessage(answer), attachments: [], sender: sender, origin: actor)
        return Empty()
    }

    /// The symbol request `requestID` of a chat without answer: the open one, or one of the
    /// transcript; `conflict` when it has an answer, `notFound` when the chat has none with this id.
    private func symbolRequest(_ requestID: UUID, chatID: ChatID) throws -> SymbolItem {
        if let open = chats.openSymbolRequests[chatID], open.requestID == requestID { return open }
        for item in try loadTranscript(chatID) {
            guard case .symbol(let request) = item, request.requestID == requestID else { continue }
            if request.answer != nil { throw EngineError(.conflict, "This symbol request was already answered.") }
            return request
        }
        throw EngineError.notFound("Symbol request", requestID.uuidString)
    }

    /// `chats.postColor` (docs/chats.md › Posting a color request).
    func chatsPostColor(_ params: ChatsPostColor.Params, _ actor: Actor) async throws -> ColorRequest {
        try ActorRules.requireOwnChat(params.chatID, actor)
        try ActorRules.requireQuestionsAllowed(domain.chat(params.chatID), actor)
        let suggestions = params.suggestions.map(\.trimmed)
        let recommended = params.recommended.trimmed
        let lightAndDark = params.lightAndDark ?? false
        try Engine.validated {
            try ModelRules.colorRequest(question: params.question, suggestions: suggestions, recommended: recommended,
                                        lightAndDark: lightAndDark)
        }
        _ = try requireChat(params.chatID)
        try ensureChatScanned(params.chatID)
        try requireNoWaitingRequest(params.chatID)
        let requestID = UUID()
        let question = ModelRules.normalizedLineBreaks(params.question)
        let item = ColorItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: question,
                             lightAndDark: lightAndDark, suggestions: suggestions, recommended: recommended)
        try appendChatItem(.color(item), chatID: params.chatID, origin: actor)
        chats.openColorRequests[params.chatID] = item
        emitChatUpdated(params.chatID, origin: actor)
        return ColorRequest(requestID: requestID, chatID: params.chatID, question: question, lightAndDark: lightAndDark,
                            suggestions: suggestions, recommended: recommended)
    }

    /// `chats.answerColor` (docs/chats.md › Answering a color request).
    func chatsAnswerColor(_ params: ChatsAnswerColor.Params, _ actor: Actor) async throws -> Empty {
        let chatID = params.chatID
        let answer = ModelRules.normalizedLineBreaks(params.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (1...10_000).contains(answer.count) else {
            throw EngineError.invalid("answer", "use 1 to 10,000 characters")
        }
        func check() throws -> ColorItem {
            _ = try requireChat(chatID)
            try ensureChatScanned(chatID)
            return try colorRequest(params.requestID, chatID: chatID)
        }
        _ = try check()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        var request = try check()
        recordDrivingDevice(chatID, actor)
        request.answer = answer
        try appendChatItem(.color(request), chatID: chatID, op: .update, origin: actor)
        chats.openColorRequests[chatID] = nil
        try sendChatMessage(chatID, text: Engine.colorMessage(answer), attachments: [], sender: sender, origin: actor)
        return Empty()
    }

    /// The color request `requestID` of a chat without answer: the open one, or one of the
    /// transcript; `conflict` when it has an answer, `notFound` when the chat has none with this id.
    private func colorRequest(_ requestID: UUID, chatID: ChatID) throws -> ColorItem {
        if let open = chats.openColorRequests[chatID], open.requestID == requestID { return open }
        for item in try loadTranscript(chatID) {
            guard case .color(let request) = item, request.requestID == requestID else { continue }
            if request.answer != nil { throw EngineError(.conflict, "This color request was already answered.") }
            return request
        }
        throw EngineError.notFound("Color request", requestID.uuidString)
    }

    /// `chats.postSound` (docs/chats.md › Posting a sound request): the actor, the chat, the type
    /// of its project, the rules, then the waiting request.
    func chatsPostSound(_ params: ChatsPostSound.Params, _ actor: Actor) async throws -> SoundRequest {
        try ActorRules.requireOwnChat(params.chatID, actor)
        try ActorRules.requireQuestionsAllowed(domain.chat(params.chatID), actor)
        let meta = try requireChat(params.chatID)
        try requireSwiftApplication(meta.projectID,
                                    else: EngineError(.forbidden, "ask_sound is only available in Swift application projects."))
        let catalog = try await soundCatalog(meta.projectID)
        let suggestions = params.suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let recommended = params.recommended.trimmingCharacters(in: .whitespacesAndNewlines)
        try Engine.validated {
            try ModelRules.soundRequest(question: params.question, suggestions: suggestions, recommended: recommended,
                                        isSound: catalog.contains)
        }
        _ = try requireChat(params.chatID)
        try ensureChatScanned(params.chatID)
        try requireNoWaitingRequest(params.chatID)
        let requestID = UUID()
        let question = ModelRules.normalizedLineBreaks(params.question)
        let item = SoundItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: question,
                             suggestions: suggestions, recommended: recommended)
        try appendChatItem(.sound(item), chatID: params.chatID, origin: actor)
        chats.openSoundRequests[params.chatID] = item
        emitChatUpdated(params.chatID, origin: actor)
        return SoundRequest(requestID: requestID, chatID: params.chatID, question: question, suggestions: suggestions,
                            recommended: recommended)
    }

    /// `chats.answerSound` (docs/chats.md › Answering a sound request).
    func chatsAnswerSound(_ params: ChatsAnswerSound.Params, _ actor: Actor) async throws -> Empty {
        let chatID = params.chatID
        let answer = ModelRules.normalizedLineBreaks(params.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (1...10_000).contains(answer.count) else {
            throw EngineError.invalid("answer", "use 1 to 10,000 characters")
        }
        func check() throws -> SoundItem {
            _ = try requireChat(chatID)
            try ensureChatScanned(chatID)
            return try soundRequest(params.requestID, chatID: chatID)
        }
        _ = try check()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        var request = try check()
        recordDrivingDevice(chatID, actor)
        request.answer = answer
        try appendChatItem(.sound(request), chatID: chatID, op: .update, origin: actor)
        chats.openSoundRequests[chatID] = nil
        try sendChatMessage(chatID, text: Engine.soundMessage(answer), attachments: [], sender: sender, origin: actor)
        return Empty()
    }

    /// The sound request `requestID` of a chat without answer: the open one, or one of the
    /// transcript; `conflict` when it has an answer, `notFound` when the chat has none with this id.
    private func soundRequest(_ requestID: UUID, chatID: ChatID) throws -> SoundItem {
        if let open = chats.openSoundRequests[chatID], open.requestID == requestID { return open }
        for item in try loadTranscript(chatID) {
            guard case .sound(let request) = item, request.requestID == requestID else { continue }
            if request.answer != nil { throw EngineError(.conflict, "This sound request was already answered.") }
            return request
        }
        throw EngineError.notFound("Sound request", requestID.uuidString)
    }

    /// `chats.postFont` (docs/chats.md › Posting a font request): the rules are checked against the
    /// font catalogue of this device for the chat's project.
    func chatsPostFont(_ params: ChatsPostFont.Params, _ actor: Actor) async throws -> FontRequest {
        try ActorRules.requireOwnChat(params.chatID, actor)
        try ActorRules.requireQuestionsAllowed(domain.chat(params.chatID), actor)
        let sample = ModelRules.normalizedLineBreaks(params.sample.trimmingCharacters(in: .whitespacesAndNewlines))
        let suggestions = params.suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let recommended = params.recommended.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = try requireChat(params.chatID)
        let project = await projectFontFamilies(meta.projectID)
        let catalog = FontCatalog(installed: FontCatalog.installed, project: project)
        try Engine.validated {
            try ModelRules.fontRequest(question: params.question, sample: sample, suggestions: suggestions,
                                       recommended: recommended, isFont: catalog.contains)
        }
        _ = try requireChat(params.chatID)
        try ensureChatScanned(params.chatID)
        try requireNoWaitingRequest(params.chatID)
        let requestID = UUID()
        let question = ModelRules.normalizedLineBreaks(params.question)
        let item = FontItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: question,
                            sample: sample, suggestions: suggestions, recommended: recommended)
        try appendChatItem(.font(item), chatID: params.chatID, origin: actor)
        chats.openFontRequests[params.chatID] = item
        emitChatUpdated(params.chatID, origin: actor)
        return FontRequest(requestID: requestID, chatID: params.chatID, question: question, sample: sample,
                           suggestions: suggestions, recommended: recommended)
    }

    /// `chats.answerFont` (docs/chats.md › Answering a font request).
    func chatsAnswerFont(_ params: ChatsAnswerFont.Params, _ actor: Actor) async throws -> Empty {
        let chatID = params.chatID
        let answer = ModelRules.normalizedLineBreaks(params.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (1...10_000).contains(answer.count) else {
            throw EngineError.invalid("answer", "use 1 to 10,000 characters")
        }
        func check() throws -> FontItem {
            _ = try requireChat(chatID)
            try ensureChatScanned(chatID)
            return try fontRequest(params.requestID, chatID: chatID)
        }
        _ = try check()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        var request = try check()
        recordDrivingDevice(chatID, actor)
        request.answer = answer
        try appendChatItem(.font(request), chatID: chatID, op: .update, origin: actor)
        chats.openFontRequests[chatID] = nil
        try sendChatMessage(chatID, text: Engine.fontMessage(answer), attachments: [], sender: sender, origin: actor)
        return Empty()
    }

    /// The font request `requestID` of a chat without answer: the open one, or one of the
    /// transcript; `conflict` when it has an answer, `notFound` when the chat has none with this id.
    private func fontRequest(_ requestID: UUID, chatID: ChatID) throws -> FontItem {
        if let open = chats.openFontRequests[chatID], open.requestID == requestID { return open }
        for item in try loadTranscript(chatID) {
            guard case .font(let request) = item, request.requestID == requestID else { continue }
            if request.answer != nil { throw EngineError(.conflict, "This font request was already answered.") }
            return request
        }
        throw EngineError.notFound("Font request", requestID.uuidString)
    }

    /// `chats.postAnimation` (docs/chats.md › Posting an animation request): the actor, the chat,
    /// the project type, the rules, then the waiting request.
    func chatsPostAnimation(_ params: ChatsPostAnimation.Params, _ actor: Actor) async throws -> AnimationRequest {
        try ActorRules.requireOwnChat(params.chatID, actor)
        try ActorRules.requireQuestionsAllowed(domain.chat(params.chatID), actor)
        let meta = try requireChat(params.chatID)
        try requireSwiftApplication(meta.projectID,
                                    else: EngineError(.forbidden, "ask_animation is available only in Swift application projects."))
        let suggestions = params.suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let recommended = params.recommended.trimmingCharacters(in: .whitespacesAndNewlines)
        try Engine.validated {
            try ModelRules.animationRequest(question: params.question, suggestions: suggestions, recommended: recommended)
        }
        try ensureChatScanned(params.chatID)
        try requireNoWaitingRequest(params.chatID)
        let requestID = UUID()
        let question = ModelRules.normalizedLineBreaks(params.question)
        let item = AnimationItem(id: requestID.uuidString, created: ISODate.now(), requestID: requestID, question: question,
                                 suggestions: suggestions, recommended: recommended)
        try appendChatItem(.animation(item), chatID: params.chatID, origin: actor)
        chats.openAnimationRequests[params.chatID] = item
        emitChatUpdated(params.chatID, origin: actor)
        return AnimationRequest(requestID: requestID, chatID: params.chatID, question: question, suggestions: suggestions,
                                recommended: recommended)
    }

    /// `chats.answerAnimation` (docs/chats.md › Answering an animation request).
    func chatsAnswerAnimation(_ params: ChatsAnswerAnimation.Params, _ actor: Actor) async throws -> Empty {
        let chatID = params.chatID
        let answer = ModelRules.normalizedLineBreaks(params.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (1...10_000).contains(answer.count) else {
            throw EngineError.invalid("answer", "use 1 to 10,000 characters")
        }
        func check() throws -> AnimationItem {
            _ = try requireChat(chatID)
            try ensureChatScanned(chatID)
            return try animationRequest(params.requestID, chatID: chatID)
        }
        _ = try check()
        _ = try await requireClaudeCLI()
        let sender = senderName(actor)
        var request = try check()
        recordDrivingDevice(chatID, actor)
        request.answer = answer
        try appendChatItem(.animation(request), chatID: chatID, op: .update, origin: actor)
        chats.openAnimationRequests[chatID] = nil
        try sendChatMessage(chatID, text: Engine.animationMessage(answer), attachments: [], sender: sender, origin: actor)
        return Empty()
    }

    /// The animation request `requestID` of a chat without answer: the open one, or one of the
    /// transcript; `conflict` when it has an answer, `notFound` when the chat has none with this id.
    private func animationRequest(_ requestID: UUID, chatID: ChatID) throws -> AnimationItem {
        if let open = chats.openAnimationRequests[chatID], open.requestID == requestID { return open }
        for item in try loadTranscript(chatID) {
            guard case .animation(let request) = item, request.requestID == requestID else { continue }
            if request.answer != nil { throw EngineError(.conflict, "This animation request was already answered.") }
            return request
        }
        throw EngineError.notFound("Animation request", requestID.uuidString)
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

    // MARK: Shown images

    /// `chats.postImages` (docs/chats.md › Shown images): checks the image rules of
    /// docs/mcp.md › Image rules, copies the images into the chat's attachment folder and adds an
    /// `images` item. It asks the user nothing, so neither `questionsBlocked` nor a waiting request
    /// refuses it.
    func chatsPostImages(_ params: ChatsPostImages.Params, _ actor: Actor) async throws -> [Attachment] {
        try ActorRules.requireOwnChat(params.chatID, actor, else: ActorRules.ownChatImagesOnly)
        guard (1...10).contains(params.paths.count) else {
            throw EngineError(.invalid, "show_image needs 1 to 10 images.")
        }
        let meta = try requireChat(params.chatID)
        let folder = try chatFolder(meta)
        var images: [PreparedUpload] = []
        var total = 0
        for path in params.paths {
            // A readable regular file of at most 20 MB, as an upload with `sourcePath`.
            let upload = AttachmentUpload(name: MCPToolHandlers.attachmentName(path: path), contentType: "", sourcePath: path)
            guard var image = try AttachmentUploads.prepare([upload], projectRoot: folder.root, param: "paths").first else { continue }
            total += image.data.count
            guard total <= AttachmentUploads.maximumSize else {
                throw EngineError(.invalid, "The attachments of one request exceed 20 MB.")
            }
            guard let contentType = ChatAttachments.imageContentType(image.data) else {
                throw EngineError(.invalid, "\(path) is not a PNG, JPEG, GIF or WebP image.")
            }
            image.contentType = contentType
            images.append(image)
        }
        let caption = params.caption
            .map { ModelRules.normalizedLineBreaks($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let stored: [Attachment]
        do {
            stored = try AttachmentUploads.store(images, in: folder.chatAttachmentsFolder(params.chatID),
                                                 pathPrefix: "chats/\(params.chatID.uuidString)", ownWrites: ownWrites)
        } catch {
            throw storageFailure(error)
        }
        let item = ImagesItem(id: RandomIDs.uuidString(), created: ISODate.now(), caption: caption, images: stored)
        do {
            try appendChatItem(.images(item), chatID: params.chatID, origin: actor)
        } catch {
            AttachmentUploads.remove(stored.map { folder.attachmentFile(path: $0.path) }, ownWrites: ownWrites)
            throw error
        }
        return stored
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
