import Foundation

extension Engine {
    /// docs/engine-api.md › Tickets.
    func registerTicketHandlers() {
        register(TicketsList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.apiTickets(self.ticketsList(params, actor))
        }
        register(TicketsGet.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsGet(params, actor))
        }
        register(TicketsCreate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsCreate(params, actor))
        }
        register(TicketsUpdate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsUpdate(params, actor))
        }
        register(TicketsSetStatus.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsSetStatus(params, actor))
        }
        register(TicketsDelete.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsDelete(params, actor)
        }
        register(TicketsAddComment.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsAddComment(params, actor))
        }
        register(TicketsUpdateComment.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsUpdateComment(params, actor))
        }
        register(TicketsDeleteComment.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsDeleteComment(params, actor))
        }
        register(TicketsRetryAnswer.self, actors: [.user]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsRetryAnswer(params, actor))
        }
        register(TicketsAddAttachments.self, actors: [.user]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsAddAttachments(params, actor))
        }
        register(TicketsRemoveAttachment.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.apiTicket(self.ticketsRemoveAttachment(params, actor))
        }
    }

    /// docs/engine-api.md › tickets.list: the project's own tickets by ticket number; with
    /// `includeSubprojects`, followed by those of each loaded descendant in `projects.list` order.
    func ticketsList(_ params: TicketsList.Params, _ actor: Actor) async throws -> [Ticket] {
        let id = try loadedProjectID(params.projectID)
        guard params.includeSubprojects == true else { return domain.tickets(of: id) }
        let hidden = actor.kind == .system ? [] : hiddenProjectIDs
        return ([id] + domain.descendants(of: id)).filter { !hidden.contains($0) }.flatMap { domain.tickets(of: $0) }
    }

    /// docs/engine-api.md › tickets.get.
    func ticketsGet(_ params: TicketsGet.Params, _ actor: Actor) async throws -> Ticket {
        try existingTicket(params.ticketID)
    }

    /// docs/engine-api.md › tickets.create and docs/tickets.md › Creation steps.
    func ticketsCreate(_ params: TicketsCreate.Params, _ actor: Actor) async throws -> Ticket {
        try ActorRules.requireNoTicketTitle(params.title, actor)
        try ActorRules.requireNoSourcePath(params.attachments, actor)
        // 1. Validate; a failure uses no number.
        let projectID = try loadedProjectID(params.projectID)
        var title: String?
        if let given = params.title, !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = try validated { try ModelRules.ticketTitle(given) }
        }
        let description = try validated { try ModelRules.ticketDescription(params.description) }
        if actor.kind == .claude {
            try validated { try TicketTemplate.validate(description) }
        }
        let folder = loaded(projectID).folder
        let uploads = try AttachmentUploads.prepare(params.attachments ?? [], projectRoot: folder.root)
        let links = try checkedLinks(params.links ?? [], ticketID: nil, projectID: projectID, declared: [])

        // 2. Allocate the number: project.yml is written with the next number.
        var project = loaded(projectID).project
        let number = ProjectFileStore.freeTicketNumber(for: project, in: folder)
        project.nextTicketNumber = number + 1
        try saveProject(project)
        let ticketID = Identifiers.ticketID(project: projectID, number: number)

        // 3. Copy the attachments.
        let attachments: [Attachment]
        do {
            attachments = try AttachmentUploads.store(uploads, in: folder.ticketAttachmentsFolder(ticketID),
                                                      pathPrefix: "attachments/\(ticketID)", ownWrites: ownWrites)
        } catch {
            emitProjectUpdated(projectID, origin: actor)
            throw storageFailure(error)
        }

        // 4. Write the ticket file, with the feedback chat in `chats` (step 5).
        let now = ISODate.now()
        let feedbackChat = actor.chat.flatMap { domain.chat($0) }.flatMap { $0.kind == .feedback && $0.ticketID == nil ? $0 : nil }
        let provisional = TicketTemplate.provisionalTitle(for: description)
        let ticket = Ticket(id: ticketID, title: title ?? provisional, status: .todo, created: now, updated: now,
                            createdBy: actor.kind == .claude ? .claude : .user, description: description,
                            attachments: attachments, comments: [], chatIDs: feedbackChat.map { [$0.id] } ?? [], links: links,
                            history: [historyEntry(.created, from: nil, to: TicketStatus.todo.rawValue, actor: actor, date: now)])
        do {
            try saveTicket(ticket)
        } catch {
            AttachmentUploads.remove(attachments.map { folder.attachmentFile(path: $0.path) }, ownWrites: ownWrites)
            emitProjectUpdated(projectID, origin: actor)
            throw error
        }

        // 5. Feedback link: the chat's `ticket` is set to the new id.
        var linkFailure: Error?
        var linkedChat: ChatMeta?
        if var chat = feedbackChat {
            chat.ticketID = ticketID
            chat.updated = now
            do {
                try saveChatMeta(chat)
                linkedChat = chat
            } catch {
                linkFailure = error
            }
        }
        emitProjectUpdated(projectID, origin: actor)
        emitTicketUpdated(ticket, origin: actor)
        emitProjectsChanged(origin: actor)
        if let linkedChat {
            emit(ChatUpdatedEvent.self, apiChatMeta(linkedChat), origin: actor)
        }
        emitInverseLinkChanges(of: ticketID, old: [], new: links, origin: actor)
        // 6. Haiku names a ticket created without a title.
        let naming = title == nil ? startTicketNaming(ticketID, provisional: provisional, description: description) : nil
        if let linkFailure {
            throw linkFailure
        }
        // 7. Claude gets the ticket once its naming has ended, as stored; the user at once.
        guard actor.kind == .claude, let naming else { return ticket }
        await naming.value
        return domain.ticket(ticketID) ?? ticket
    }

    /// docs/engine-api.md › tickets.update.
    func ticketsUpdate(_ params: TicketsUpdate.Params, _ actor: Actor) async throws -> Ticket {
        let old = try existingTicket(params.ticketID)
        var new = old
        if let title = params.title {
            new.title = try validated { try ModelRules.ticketTitle(title) }
        }
        if let description = params.description {
            new.description = try validated { try ModelRules.ticketDescription(description) }
            if actor.kind == .claude {
                try validated { try TicketTemplate.validate(new.description) }
            }
        }
        if let links = params.links {
            new.links = try checkedLinks(links, ticketID: old.id, projectID: old.projectID!, declared: old.links)
        }
        if params.title != nil {
            // A title set here is never replaced by a pending Haiku answer.
            domain.pendingTicketNames[old.id] = nil
        }
        guard new != old else { return old }
        let now = ISODate.now()
        // The rename, the description edit, the removed links, then the added links
        // (docs/tickets.md › Ticket history).
        if new.title != old.title {
            new.history.append(historyEntry(.title, from: old.title, to: new.title, actor: actor, date: now))
        }
        if new.description != old.description {
            new.history.append(historyEntry(.description, from: nil, to: "", actor: actor, date: now))
        }
        for link in old.links where !new.links.contains(where: { $0.kind == link.kind && $0.ticketID == link.ticketID }) {
            new.history.append(historyEntry(.linkRemoved, from: nil, to: TicketHistoryEntry.linkValue(link), actor: actor, date: now))
        }
        for link in new.links where !old.links.contains(where: { $0.kind == link.kind && $0.ticketID == link.ticketID }) {
            new.history.append(historyEntry(.linkAdded, from: nil, to: TicketHistoryEntry.linkValue(link), actor: actor, date: now))
        }
        new.updated = now
        try saveTicket(new)
        emitTicketUpdated(new, origin: actor)
        emitInverseLinkChanges(of: new.id, old: old.links, new: new.links, origin: actor)
        return new
    }

    /// docs/engine-api.md › tickets.setStatus and docs/tickets.md › Status rules.
    func ticketsSetStatus(_ params: TicketsSetStatus.Params, _ actor: Actor) async throws -> Ticket {
        let id = try normalizedTicketID(params.ticketID)
        guard let status = TicketStatus(rawValue: params.status) else {
            throw EngineError(.invalid, "Unknown status \"\(params.status)\". Use todo, in_progress, review or done.")
        }
        let old = try existingTicket(id)
        try ActorRules.requireNotDoneTicket(old, actor)
        guard old.status != status else { return old }
        var new = old
        let now = ISODate.now()
        new.status = status
        new.history.append(historyEntry(.status, from: old.status.rawValue, to: status.rawValue, actor: actor, date: now))
        new.updated = now
        try saveTicket(new)
        emitTicketUpdated(new, origin: actor)
        emitProjectsChanged(origin: actor)
        // The bundles that list it, after the ticket file (docs/tickets.md › Bundle status rules).
        for bundleID in bundleIDs(listing: [new.id], in: new.projectID!) {
            try applyAutomaticBundleStatus(bundleID, origin: actor)
        }
        return new
    }

    /// docs/engine-api.md › tickets.delete: the id leaves every bundle and every link to it leaves
    /// the other tickets, then the ticket file and its attachments folder move to the Trash.
    func ticketsDelete(_ params: TicketsDelete.Params, _ actor: Actor) async throws -> Empty {
        let ticket = try existingTicket(params.ticketID)
        let projectID = ticket.projectID!
        let folder = loaded(projectID).folder
        // 1. Every bundle file listing it, with the automatic status rules in the same write.
        for var bundle in domain.bundles(of: projectID) where bundle.ticketIDs.contains(ticket.id) {
            bundle.ticketIDs.removeAll { $0 == ticket.id }
            if let status = automaticBundleStatus(bundle) {
                bundle.status = status
            }
            bundle.updated = ISODate.now()
            try saveBundle(bundle)
            emit(BundleUpdatedEvent.self, bundle, origin: actor)
        }
        // The comment answers of the ticket stop (docs/tickets.md › Comment answers).
        stopCommentAnswers(of: ticket)
        // 2. Every ticket file declaring a link to it.
        try removeLinks(to: ticket.id, projectID: projectID, origin: actor)
        // 3. The ticket file and the folder attachments/<ticketID>/.
        try moveToTrash(folder.ticketFile(ticket.id))
        domain.removeTicket(ticket.id)
        let folderFailure: Error?
        do {
            try moveToTrash(folder.ticketAttachmentsFolder(ticket.id))
            folderFailure = nil
        } catch {
            folderFailure = error
        }
        emit(TicketDeletedEvent.self, TicketDeletedEvent.Payload(projectID: projectID, ticketID: ticket.id), origin: actor)
        emitProjectsChanged(origin: actor)
        emitInverseLinkChanges(of: ticket.id, old: ticket.links, new: [], origin: actor)
        if let folderFailure {
            throw folderFailure
        }
        return Empty()
    }

    /// docs/engine-api.md › tickets.addComment.
    func ticketsAddComment(_ params: TicketsAddComment.Params, _ actor: Actor) async throws -> Ticket {
        try ActorRules.requireNoSourcePath(params.attachments, actor)
        var ticket = try existingTicket(params.ticketID)
        let uploads = params.attachments ?? []
        try validated { try ModelRules.comment(text: params.text, attachmentCount: uploads.count) }
        let folder = loaded(ticket.projectID!).folder
        let prepared = try AttachmentUploads.prepare(uploads, projectRoot: folder.root)
        // 1. The attachment files; 2. the ticket file.
        let attachments: [Attachment]
        do {
            attachments = try AttachmentUploads.store(prepared, in: folder.ticketAttachmentsFolder(ticket.id),
                                                      pathPrefix: "attachments/\(ticket.id)", ownWrites: ownWrites)
        } catch {
            throw storageFailure(error)
        }
        let now = ISODate.now()
        let (model, effort) = commentModel(ticketID: ticket.id, text: params.text, actor)
        let comment = Comment(id: UUID(), author: actor.kind == .claude ? .claude : .user, created: now, updated: nil,
                              text: ModelRules.normalizedLineBreaks(params.text), attachments: attachments, model: model, effort: effort)
        ticket.comments.append(comment)
        ticket.updated = now
        try saveTicket(ticket)
        // A new comment of the user that mentions Claude starts an answer (docs/tickets.md ›
        // Mentioning Claude); its `replying` state goes with this ticket.updated.
        let answering = actor.kind == .user && CommentMentions.mentionsClaude(comment.text)
        if answering {
            startCommentAnswer(ticketID: ticket.id, projectID: ticket.projectID!, commentID: comment.id)
        }
        emitTicketUpdated(ticket, origin: actor)
        if answering {
            emitProjectsChanged(origin: actor)
        }
        return ticket
    }

    /// The model and effort of a comment (docs/engine-api.md › tickets.addComment): for a claude
    /// actor of a chat, the model of the chat's `add_comment` call, else of its latest message,
    /// with the chat's effort; nil for every other actor.
    private func commentModel(ticketID: TicketID, text: String, _ actor: Actor) -> (String?, Effort?) {
        guard case .claude(let id) = actor, let chatID = UUID(uuidString: id), let meta = domain.chat(chatID),
              let process = chats.runtimes[chatID]?.process,
              let model = process.mapper.takeCommentModel(ticketID: ticketID, text: text)
        else { return (nil, nil) }
        return (model, ClaudeModel.effort(meta.settings.effort, of: model, in: claudeCLI.cachedModels))
    }

    /// docs/engine-api.md › tickets.updateComment.
    func ticketsUpdateComment(_ params: TicketsUpdateComment.Params, _ actor: Actor) async throws -> Ticket {
        var ticket = try existingTicket(params.ticketID)
        guard let index = ticket.comments.firstIndex(where: { $0.id == params.commentID }) else {
            throw EngineError.notFound("Comment", params.commentID.uuidString)
        }
        try validated { try ModelRules.comment(text: params.text, attachmentCount: ticket.comments[index].attachments.count) }
        let text = ModelRules.normalizedLineBreaks(params.text)
        guard text != ticket.comments[index].text else { return ticket }
        let now = ISODate.now()
        ticket.comments[index].text = text
        ticket.comments[index].updated = now
        ticket.updated = now
        try saveTicket(ticket)
        emitTicketUpdated(ticket, origin: actor)
        return ticket
    }

    /// docs/engine-api.md › tickets.deleteComment: the comment leaves the ticket file, then its
    /// attachment files move to the Trash.
    func ticketsDeleteComment(_ params: TicketsDeleteComment.Params, _ actor: Actor) async throws -> Ticket {
        var ticket = try existingTicket(params.ticketID)
        guard let index = ticket.comments.firstIndex(where: { $0.id == params.commentID }) else {
            throw EngineError.notFound("Comment", params.commentID.uuidString)
        }
        // Its comment answer stops first (docs/tickets.md › Comment answers).
        stopCommentAnswer(commentID: params.commentID)
        let removed = ticket.comments.remove(at: index)
        ticket.updated = ISODate.now()
        try saveTicket(ticket)
        emitTicketUpdated(ticket, origin: actor)
        try trashAttachmentFiles(removed.attachments, projectID: ticket.projectID!)
        return ticket
    }

    /// docs/engine-api.md › tickets.addAttachments.
    func ticketsAddAttachments(_ params: TicketsAddAttachments.Params, _ actor: Actor) async throws -> Ticket {
        try ActorRules.requireNoSourcePath(params.attachments, actor)
        var ticket = try existingTicket(params.ticketID)
        guard !params.attachments.isEmpty else {
            throw EngineError.invalid("attachments", "add at least one file")
        }
        let folder = loaded(ticket.projectID!).folder
        let prepared = try AttachmentUploads.prepare(params.attachments, projectRoot: folder.root)
        let attachments: [Attachment]
        do {
            attachments = try AttachmentUploads.store(prepared, in: folder.ticketAttachmentsFolder(ticket.id),
                                                      pathPrefix: "attachments/\(ticket.id)", ownWrites: ownWrites)
        } catch {
            throw storageFailure(error)
        }
        ticket.attachments += attachments
        ticket.updated = ISODate.now()
        try saveTicket(ticket)
        emitTicketUpdated(ticket, origin: actor)
        return ticket
    }

    /// docs/engine-api.md › tickets.removeAttachment: only ticket-level attachments.
    func ticketsRemoveAttachment(_ params: TicketsRemoveAttachment.Params, _ actor: Actor) async throws -> Ticket {
        var ticket = try existingTicket(params.ticketID)
        guard let index = ticket.attachments.firstIndex(where: { $0.id == params.attachmentID }) else {
            throw EngineError.notFound("Attachment", params.attachmentID.uuidString)
        }
        let removed = ticket.attachments.remove(at: index)
        ticket.updated = ISODate.now()
        try saveTicket(ticket)
        emitTicketUpdated(ticket, origin: actor)
        try trashAttachmentFiles([removed], projectID: ticket.projectID!)
        return ticket
    }

    // MARK: Helpers

    /// Moves the files of attachments to the Trash; a path of another form than
    /// `attachments/<TICKET-ID>/<file>` is left alone, so that a ticket file cannot point the
    /// engine at other files (docs/data-model.md › Attachments).
    func trashAttachmentFiles(_ attachments: [Attachment], projectID: ProjectID) throws {
        guard let loaded = domain.projects[projectID] else { return }
        var failure: Error?
        for attachment in attachments where ModelRules.isAttachmentPath(attachment.path) && attachment.path.hasPrefix("attachments/") {
            do {
                try moveToTrash(loaded.folder.attachmentFile(path: attachment.path))
            } catch {
                failure = failure ?? error
            }
        }
        if let failure {
            throw failure
        }
    }

    /// The history entry of a change made by `actor` (docs/tickets.md › Ticket history): a user
    /// with the name of its device, Claude with its chat id or `external`, and `automatic` for the
    /// engine itself.
    func historyEntry(_ kind: TicketHistoryKind, from: String?, to: String, actor: Actor, date: Date) -> TicketHistoryEntry {
        switch actor {
        case .user(let deviceID):
            return TicketHistoryEntry(kind: kind, date: date, from: from, to: to, author: .user,
                                      device: userDeviceName(deviceID: deviceID))
        case .claude(let chatID):
            return TicketHistoryEntry(kind: kind, date: date, from: from, to: to, author: .claude,
                                      chat: actor.chat?.uuidString ?? chatID)
        case .system:
            return TicketHistoryEntry(kind: kind, date: date, from: from, to: to, author: .automatic)
        }
    }

    /// The EngineError of a failed attachment write.
    func storageFailure(_ error: Error) -> Error {
        if let error = error as? StorageError {
            log.error(.storage, error.description)
            return EngineError.storage(error)
        }
        return error
    }

    // MARK: Haiku naming (docs/tickets.md › Titles and naming)

    /// Asks the title namer in the background for a ticket created without a title; the answer
    /// is applied only while the ticket still has its provisional title. The task ends once the
    /// answer has been applied or dropped.
    @discardableResult
    func startTicketNaming(_ ticketID: TicketID, provisional: String, description: String,
                           namer: (any TitleNamer)? = nil) -> Task<Void, Never> {
        domain.pendingTicketNames[ticketID] = provisional
        let namer = namer ?? titleNamer
        return Task { [weak self] in
            let title = await namer.title(for: .ticket(description: description))
            await self?.applyTicketName(ticketID, provisional: provisional, title: title)
        }
    }

    /// Stores a Haiku title when the ticket still exists, its naming is still pending and its
    /// title still equals the provisional title; emits `ticket.updated` with origin `system`.
    func applyTicketName(_ ticketID: TicketID, provisional: String, title: String?) {
        guard domain.pendingTicketNames.removeValue(forKey: ticketID) == provisional, !domain.isStopped,
              let title, var ticket = domain.ticket(ticketID), ticket.title == provisional, title != provisional
        else { return }
        guard let valid = try? ModelRules.ticketTitle(title) else {
            log.warn(.claude, "the Haiku title of \(ticketID) is not a valid title and is ignored")
            return
        }
        let now = ISODate.now()
        ticket.history.append(historyEntry(.title, from: ticket.title, to: valid, actor: .system, date: now))
        ticket.title = valid
        ticket.updated = now
        do {
            try saveTicket(ticket)
        } catch {
            log.error(.storage, "the Haiku title of \(ticketID) cannot be written: \(error)")
            return
        }
        emitTicketUpdated(ticket, origin: .system)
    }
}
