import Foundation

extension Engine {
    /// docs/engine-api.md › Tickets.
    func registerTicketHandlers() {
        register(TicketsList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsList(params, actor)
        }
        register(TicketsGet.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsGet(params, actor)
        }
        register(TicketsCreate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsCreate(params, actor)
        }
        register(TicketsUpdate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsUpdate(params, actor)
        }
        register(TicketsSetStatus.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsSetStatus(params, actor)
        }
        register(TicketsDelete.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsDelete(params, actor)
        }
        register(TicketsAddComment.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsAddComment(params, actor)
        }
        register(TicketsUpdateComment.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsUpdateComment(params, actor)
        }
        register(TicketsDeleteComment.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsDeleteComment(params, actor)
        }
        register(TicketsAddAttachments.self, actors: [.user]) { [unowned self] params, actor in
            try await self.ticketsAddAttachments(params, actor)
        }
        register(TicketsRemoveAttachment.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.ticketsRemoveAttachment(params, actor)
        }
    }

    // STUB: core-domain — docs/engine-api.md › tickets.list.
    func ticketsList(_ params: TicketsList.Params, _ actor: Actor) async throws -> [Ticket] {
        throw EngineError.notImplemented(TicketsList.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.get.
    func ticketsGet(_ params: TicketsGet.Params, _ actor: Actor) async throws -> Ticket {
        throw EngineError.notImplemented(TicketsGet.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.create, with Haiku naming (`titleNamer`);
    // the template rule for claude is `TicketTemplate.validate`.
    func ticketsCreate(_ params: TicketsCreate.Params, _ actor: Actor) async throws -> Ticket {
        try ActorRules.requireNoTicketTitle(params.title, actor)
        try ActorRules.requireNoSourcePath(params.attachments, actor)
        throw EngineError.notImplemented(TicketsCreate.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.update.
    func ticketsUpdate(_ params: TicketsUpdate.Params, _ actor: Actor) async throws -> Ticket {
        throw EngineError.notImplemented(TicketsUpdate.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.setStatus; the rule on a `done` ticket is
    // `ActorRules.requireNotDoneTicket`.
    func ticketsSetStatus(_ params: TicketsSetStatus.Params, _ actor: Actor) async throws -> Ticket {
        try ActorRules.requireNotDone(params.status, actor)
        throw EngineError.notImplemented(TicketsSetStatus.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.delete.
    func ticketsDelete(_ params: TicketsDelete.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(TicketsDelete.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.addComment.
    func ticketsAddComment(_ params: TicketsAddComment.Params, _ actor: Actor) async throws -> Ticket {
        try ActorRules.requireNoSourcePath(params.attachments, actor)
        throw EngineError.notImplemented(TicketsAddComment.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.updateComment.
    func ticketsUpdateComment(_ params: TicketsUpdateComment.Params, _ actor: Actor) async throws -> Ticket {
        throw EngineError.notImplemented(TicketsUpdateComment.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.deleteComment.
    func ticketsDeleteComment(_ params: TicketsDeleteComment.Params, _ actor: Actor) async throws -> Ticket {
        throw EngineError.notImplemented(TicketsDeleteComment.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.addAttachments.
    func ticketsAddAttachments(_ params: TicketsAddAttachments.Params, _ actor: Actor) async throws -> Ticket {
        try ActorRules.requireNoSourcePath(params.attachments, actor)
        throw EngineError.notImplemented(TicketsAddAttachments.name)
    }

    // STUB: core-domain — docs/engine-api.md › tickets.removeAttachment.
    func ticketsRemoveAttachment(_ params: TicketsRemoveAttachment.Params, _ actor: Actor) async throws -> Ticket {
        throw EngineError.notImplemented(TicketsRemoveAttachment.name)
    }
}
