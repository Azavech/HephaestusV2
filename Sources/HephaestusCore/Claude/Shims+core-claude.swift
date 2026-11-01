import Foundation

// SHIM(core-domain): delete at integration. The cross-key contract of DomainState and the chat
// links (parallel-rules › Cross-key contracts) is implemented by core-domain; these minimal
// bodies read the top-level projects of the registry from disk, so that the chat engine can be
// tested before integration. Sub projects, caching and the in-memory maps are core-domain's.
extension DomainState {
    private func shimRoots() -> [(project: Project, root: URL)] {
        registry.projects.compactMap { path in
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard let project = try? ProjectFileStore.readProject(ProjectFolder(root: root)) else { return nil }
            return (project, root)
        }
    }

    func project(_ id: ProjectID) -> Project? {
        shimRoots().first { $0.project.id == id }?.project
    }

    func projectRoot(_ id: ProjectID) -> URL? {
        shimRoots().first { $0.project.id == id }?.root
    }

    func loadedProjectIDs() -> [ProjectID] {
        shimRoots().map(\.project.id)
    }

    func ticket(_ id: TicketID) -> Ticket? {
        guard let projectID = Identifiers.projectID(of: id), let root = projectRoot(projectID) else { return nil }
        return try? ProjectFileStore.readTicket(at: ProjectFolder(root: root).ticketFile(id), projectID: projectID)
    }

    func tickets(of projectID: ProjectID) -> [Ticket] {
        guard let root = projectRoot(projectID) else { return [] }
        return ProjectFileStore.loadContents(of: ProjectFolder(root: root), projectID: projectID, log: nil).tickets
    }

    func bundle(_ id: BundleID) -> TicketBundle? {
        guard let projectID = Identifiers.projectID(of: id), let root = projectRoot(projectID) else { return nil }
        return try? ProjectFileStore.readBundle(at: ProjectFolder(root: root).bundleFile(id), projectID: projectID)
    }

    func bundles(of projectID: ProjectID) -> [TicketBundle] {
        guard let root = projectRoot(projectID) else { return [] }
        return ProjectFileStore.loadContents(of: ProjectFolder(root: root), projectID: projectID, log: nil).bundles
    }

    func chat(_ id: ChatID) -> ChatMeta? {
        for (project, root) in shimRoots() {
            let url = ProjectFolder(root: root).chatMetaFile(id)
            if let meta = try? ProjectFileStore.readChatMeta(at: url, projectID: project.id) { return meta }
        }
        return nil
    }

    func chats(of projectID: ProjectID) -> [ChatMeta] {
        guard let root = projectRoot(projectID) else { return [] }
        let folder = ProjectFolder(root: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.chatsFolder.path)) ?? []
        return names.sorted().compactMap { name in
            guard let id = ProjectFolder.chatID(fromMetaFileName: name) else { return nil }
            return try? ProjectFileStore.readChatMeta(at: folder.chatMetaFile(id), projectID: projectID)
        }
    }

    /// The shim reads the files, which the chat engine writes before calling this.
    mutating func upsertChat(_ meta: ChatMeta) {}

    mutating func removeChat(_ id: ChatID) {}
}

// SHIM(core-domain): delete at integration.
extension Engine {
    func linkChat(_ chatID: ChatID, toTicket ticketID: TicketID) throws {
        guard let projectID = Identifiers.projectID(of: ticketID), let root = domain.projectRoot(projectID),
              var ticket = domain.ticket(ticketID) else { throw EngineError.notFound("Ticket", ticketID) }
        guard !ticket.chatIDs.contains(chatID) else { return }
        ticket.chatIDs.append(chatID)
        ticket.updated = ISODate.now()
        do {
            try ProjectFileStore.write(ticket, to: ProjectFolder(root: root))
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        emit(TicketUpdatedEvent.self, ticket, origin: .system)
    }

    func linkChat(_ chatID: ChatID, toBundle bundleID: BundleID) throws {
        guard let projectID = Identifiers.projectID(of: bundleID), let root = domain.projectRoot(projectID),
              var bundle = domain.bundle(bundleID) else { throw EngineError.notFound("Bundle", bundleID) }
        guard !bundle.chatIDs.contains(chatID) else { return }
        bundle.chatIDs.append(chatID)
        bundle.updated = ISODate.now()
        do {
            try ProjectFileStore.write(bundle, to: ProjectFolder(root: root))
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        emit(BundleUpdatedEvent.self, bundle, origin: .system)
    }

    func unlinkChat(_ chatID: ChatID) {
        guard let meta = domain.chat(chatID), let root = domain.projectRoot(meta.projectID) else { return }
        let folder = ProjectFolder(root: root)
        if let ticketID = meta.ticketID, var ticket = domain.ticket(ticketID), ticket.chatIDs.contains(chatID) {
            ticket.chatIDs.removeAll { $0 == chatID }
            ticket.updated = ISODate.now()
            if (try? ProjectFileStore.write(ticket, to: folder)) != nil {
                emit(TicketUpdatedEvent.self, ticket, origin: .system)
            }
        }
        if let bundleID = meta.bundleID, var bundle = domain.bundle(bundleID), bundle.chatIDs.contains(chatID) {
            bundle.chatIDs.removeAll { $0 == chatID }
            bundle.updated = ISODate.now()
            if (try? ProjectFileStore.write(bundle, to: folder)) != nil {
                emit(BundleUpdatedEvent.self, bundle, origin: .system)
            }
        }
    }
}

// SHIM(core-files): delete at integration. The tools lookup of docs/architecture.md › Child
// processes, rule 5, implemented by core-files in Files/; called once after the login-shell
// environment capture.
extension Engine {
    func lookUpFileTools(environment: [String: String]) async {}
}
