import Foundation

extension Engine {
    /// docs/engine-api.md › Bundles.
    func registerBundleHandlers() {
        register(BundlesList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesList(params, actor)
        }
        register(BundlesGet.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesGet(params, actor)
        }
        register(BundlesCreate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesCreate(params, actor)
        }
        register(BundlesUpdate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesUpdate(params, actor)
        }
        register(BundlesSetStatus.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesSetStatus(params, actor)
        }
        register(BundlesDelete.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesDelete(params, actor)
        }
    }

    /// docs/engine-api.md › bundles.list: the project's bundles by bundle number.
    func bundlesList(_ params: BundlesList.Params, _ actor: Actor) async throws -> [TicketBundle] {
        let id = try loadedProjectID(params.projectID)
        return domain.bundles(of: id)
    }

    /// docs/engine-api.md › bundles.get.
    func bundlesGet(_ params: BundlesGet.Params, _ actor: Actor) async throws -> TicketBundle {
        try existingBundle(params.bundleID)
    }

    /// docs/engine-api.md › bundles.create and docs/tickets.md › Bundle rules.
    func bundlesCreate(_ params: BundlesCreate.Params, _ actor: Actor) async throws -> TicketBundle {
        // 1. Validate.
        let projectID = try loadedProjectID(params.projectID)
        guard !params.ticketIDs.isEmpty else {
            throw EngineError(.invalid, "A bundle needs at least one ticket.")
        }
        let ticketIDs = try bundleTicketIDs(params.ticketIDs, projectID: projectID, alreadyListed: [])
        var title: String?
        if let given = params.title, !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = try validated { try ModelRules.bundleTitle(given) }
        }
        // 2. Allocate the number.
        let folder = loaded(projectID).folder
        var project = loaded(projectID).project
        let number = ProjectFileStore.freeBundleNumber(for: project, in: folder)
        project.nextBundleNumber = number + 1
        try saveProject(project)
        let bundleID = Identifiers.bundleID(project: projectID, number: number)
        // 3. Write the bundle file.
        let tickets = ticketIDs.compactMap { domain.ticket($0) }
        // Cut to 60 characters, then trimmed (docs/tickets.md › Bundle rules).
        let provisional = TicketTemplate.provisionalBundleTitle(ticketTitles: tickets.map(\.title))
            .trimmingCharacters(in: .whitespaces)
        let now = ISODate.now()
        var bundle = TicketBundle(id: bundleID, title: title ?? provisional, created: now, updated: now,
                                  ticketIDs: ticketIDs, chatIDs: [])
        if let status = automaticBundleStatus(bundle) {
            bundle.status = status
        }
        do {
            try saveBundle(bundle)
        } catch {
            emitProjectUpdated(projectID, origin: actor)
            throw error
        }
        emitProjectUpdated(projectID, origin: actor)
        emit(BundleUpdatedEvent.self, bundle, origin: actor)
        // 4. Haiku names a bundle created without a title.
        if title == nil {
            startBundleNaming(bundleID, provisional: provisional,
                              tickets: tickets.map { NamingSubject.TicketTitle(id: $0.id, title: $0.title) })
        }
        return bundle
    }

    /// docs/engine-api.md › bundles.update.
    func bundlesUpdate(_ params: BundlesUpdate.Params, _ actor: Actor) async throws -> TicketBundle {
        let old = try existingBundle(params.bundleID)
        let projectID = old.projectID!
        var new = old
        if let ticketIDs = params.ticketIDs {
            new.ticketIDs = try bundleTicketIDs(ticketIDs, projectID: projectID, alreadyListed: Set(old.ticketIDs))
        }
        if let title = params.title {
            new.title = try validated { try ModelRules.bundleTitle(title) }
            domain.pendingBundleNames[old.id] = nil
        }
        // Tickets added or removed apply the automatic status rules in the same write; a reorder
        // alone does not (docs/tickets.md › Bundle status rules).
        if Set(new.ticketIDs) != Set(old.ticketIDs), let status = automaticBundleStatus(new) {
            new.status = status
        }
        guard new != old else { return old }
        new.updated = ISODate.now()
        try saveBundle(new)
        emit(BundleUpdatedEvent.self, new, origin: actor)
        return new
    }

    /// docs/engine-api.md › bundles.setStatus and docs/tickets.md › Bundle status rules.
    func bundlesSetStatus(_ params: BundlesSetStatus.Params, _ actor: Actor) async throws -> TicketBundle {
        let id = try normalizedBundleID(params.bundleID)
        guard let status = BundleStatus(rawValue: params.status) else {
            throw EngineError(.invalid, "Unknown status \"\(params.status)\". Use todo, in_progress or done.")
        }
        let old = try existingBundle(id)
        try ActorRules.requireBundleStatusChange(old, to: status, actor)
        guard old.status != status else { return old }
        var new = old
        new.status = status
        new.updated = ISODate.now()
        try saveBundle(new)
        emit(BundleUpdatedEvent.self, new, origin: actor)
        return new
    }

    /// docs/engine-api.md › bundles.delete: the bundle file moves to the Trash; its tickets and
    /// chats are kept.
    func bundlesDelete(_ params: BundlesDelete.Params, _ actor: Actor) async throws -> Empty {
        let bundle = try existingBundle(params.bundleID)
        let projectID = bundle.projectID!
        try moveToTrash(loaded(projectID).folder.bundleFile(bundle.id))
        domain.removeBundle(bundle.id)
        emit(BundleDeletedEvent.self, BundleDeletedEvent.Payload(projectID: projectID, bundleID: bundle.id), origin: actor)
        return Empty()
    }

    // MARK: Automatic status (docs/tickets.md › Bundle status rules)

    /// The status the automatic rules give a bundle, or nil when they keep its status. Complete:
    /// a bundle that lists tickets, all `done`, becomes `done`. Reopened: a `done` bundle that
    /// lists a ticket that is not `done` becomes `in_progress`; `reopen` false leaves it out, as
    /// at load. A listed id without a loaded ticket counts as not done.
    func automaticBundleStatus(_ bundle: TicketBundle, reopen: Bool = true) -> BundleStatus? {
        guard !bundle.ticketIDs.isEmpty else { return nil }
        if bundle.ticketIDs.allSatisfy({ domain.ticket($0)?.status == .done }) {
            return bundle.status == .done ? nil : .done
        }
        return reopen && bundle.status == .done ? .inProgress : nil
    }

    /// Applies the automatic rules to a loaded bundle: a status change writes the bundle file and
    /// emits `bundle.updated` with `origin`.
    func applyAutomaticBundleStatus(_ bundleID: BundleID, reopen: Bool = true, origin: Actor) throws {
        guard var bundle = domain.bundle(bundleID), let status = automaticBundleStatus(bundle, reopen: reopen) else { return }
        bundle.status = status
        bundle.updated = ISODate.now()
        try saveBundle(bundle)
        emit(BundleUpdatedEvent.self, bundle, origin: origin)
    }

    /// The bundles of a project that list one of `ticketIDs`, in bundle number order.
    func bundleIDs(listing ticketIDs: Set<TicketID>, in projectID: ProjectID) -> [BundleID] {
        domain.bundles(of: projectID).filter { $0.ticketIDs.contains(where: ticketIDs.contains) }.map(\.id)
    }

    /// The load rule of docs/data-model.md › Loading: the Complete rule alone on every bundle of a
    /// project that was just loaded, with the actor `system`. A bundle that cannot be written
    /// keeps its status and is logged.
    func completeBundlesAtLoad(_ projectID: ProjectID) {
        for bundle in domain.bundles(of: projectID) {
            do {
                try applyAutomaticBundleStatus(bundle.id, reopen: false, origin: .system)
            } catch {
                log.error(.storage, "\(bundle.id) cannot be set to done: \(error)")
            }
        }
    }

    // MARK: Helpers

    /// The ticket ids of a bundle, uppercased and checked by the rules of docs/tickets.md ›
    /// Bundle rules: a well-formed id (`invalid`), of this project (`invalid`), listed once
    /// (`invalid`), then an existing ticket (`notFound`); an id in `alreadyListed` is accepted
    /// without its ticket (docs/engine-api.md › bundles.update).
    func bundleTicketIDs(_ values: [TicketID], projectID: ProjectID, alreadyListed: Set<TicketID>) throws -> [TicketID] {
        var result: [TicketID] = []
        var seen = Set<TicketID>()
        for value in values {
            let id = try normalizedTicketID(value)
            guard Identifiers.projectID(of: id) == projectID else {
                throw EngineError(.invalid, "\(id) does not belong to project \(projectID).")
            }
            guard seen.insert(id).inserted else {
                throw EngineError(.invalid, "\(id) is listed more than once.")
            }
            result.append(id)
        }
        for id in result where domain.ticket(id) == nil && !alreadyListed.contains(id) {
            throw EngineError.notFound("Ticket", id)
        }
        return result
    }

    // MARK: Haiku naming (docs/tickets.md › Bundle rules)

    /// Asks the title namer in the background for a bundle created without a title; the answer
    /// is applied only while the bundle still has its provisional title.
    func startBundleNaming(_ bundleID: BundleID, provisional: String, tickets: [NamingSubject.TicketTitle],
                           namer: (any TitleNamer)? = nil) {
        domain.pendingBundleNames[bundleID] = provisional
        let namer = namer ?? titleNamer
        Task { [weak self] in
            let title = await namer.title(for: .bundle(tickets: tickets))
            await self?.applyBundleName(bundleID, provisional: provisional, title: title)
        }
    }

    /// Stores a Haiku title when the bundle still exists, its naming is still pending and its
    /// title still equals the provisional title; emits `bundle.updated` with origin `system`.
    func applyBundleName(_ bundleID: BundleID, provisional: String, title: String?) {
        guard domain.pendingBundleNames.removeValue(forKey: bundleID) == provisional, !domain.isStopped,
              let title, var bundle = domain.bundle(bundleID), bundle.title == provisional, title != provisional
        else { return }
        guard let valid = try? ModelRules.bundleTitle(title) else {
            log.warn(.claude, "the Haiku title of \(bundleID) is not a valid title and is ignored")
            return
        }
        bundle.title = valid
        bundle.updated = ISODate.now()
        do {
            try saveBundle(bundle)
        } catch {
            log.error(.storage, "the Haiku title of \(bundleID) cannot be written: \(error)")
            return
        }
        emit(BundleUpdatedEvent.self, bundle, origin: .system)
    }
}
