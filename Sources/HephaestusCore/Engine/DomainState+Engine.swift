import Darwin
import Foundation

// Lookups, writes, Trash moves and events of the project data engine, shared by the project,
// ticket, bundle, web tab and UI handlers (docs/engine-api.md › Writes and consistency).

extension Engine {
    // MARK: Validation

    /// Runs a write rule and turns its `ValidationError` into the EngineError of the call.
    func validated<T>(_ rule: () throws -> T) throws -> T {
        do {
            return try rule()
        } catch let error as ValidationError {
            throw EngineError(error)
        }
    }

    // MARK: Lookups (docs/engine-api.md › Identifiers)

    /// A project identifier received from a client or Claude, uppercased: `invalid` when it is
    /// not 2 to 8 letters.
    func normalizedProjectID(_ value: String, param: String = "projectID") throws -> ProjectID {
        guard let id = Identifiers.normalizedProjectID(value) else {
            throw EngineError.invalid(param, "use 2 to 8 letters A–Z")
        }
        return id
    }

    /// A loaded project named by a param: `invalid` when malformed, `notFound` when no loaded
    /// project has the identifier.
    func loadedProjectID(_ value: String, param: String = "projectID") throws -> ProjectID {
        let id = try normalizedProjectID(value, param: param)
        guard domain.isLoaded(id) else {
            throw EngineError.notFound("Project", id)
        }
        return id
    }

    /// The loaded project, which `loadedProjectID` found.
    func loaded(_ id: ProjectID) -> LoadedProject {
        domain.projects[id]!
    }

    /// A ticket id received from a client or Claude, uppercased (docs/tickets.md › Errors).
    func normalizedTicketID(_ value: String) throws -> TicketID {
        try validated { try ModelRules.ticketID(value) }
    }

    /// A loaded ticket: `invalid` for a malformed id, `notFound` when its project or file does
    /// not exist, `internal` when its file exists but never loaded, in every method
    /// (docs/tickets.md › Errors, docs/engine-api.md › Tickets).
    func existingTicket(_ value: String) throws -> Ticket {
        let id = try normalizedTicketID(value)
        if let ticket = domain.ticket(id) {
            return ticket
        }
        if let reason = domain.invalidTicketReason(id) {
            throw Self.unreadableTicket(id, reason: reason)
        }
        throw EngineError.notFound("Ticket", id)
    }

    /// `internal` `Ticket file <ID>.yml cannot be read: <reason>.`
    static func unreadableTicket(_ id: TicketID, reason: String) -> EngineError {
        var text = reason
        while text.hasSuffix(".") { text.removeLast() }
        return EngineError(.internal, "Ticket file \(id).yml cannot be read: \(text).")
    }

    /// A bundle id received from a client or Claude, uppercased (docs/tickets.md › Errors).
    func normalizedBundleID(_ value: String) throws -> BundleID {
        try validated { try ModelRules.bundleID(value) }
    }

    /// A loaded bundle: `invalid` for a malformed id, `notFound` when its project or file does
    /// not exist.
    func existingBundle(_ value: String) throws -> TicketBundle {
        let id = try normalizedBundleID(value)
        guard let bundle = domain.bundle(id) else {
            throw EngineError.notFound("Bundle", id)
        }
        return bundle
    }

    // MARK: Writes (docs/data-model.md › Atomic writes)

    /// Writes a value atomically and records the SHA-256 of the written bytes for its path.
    private func record(_ url: URL, _ write: () throws -> String) throws {
        do {
            let digest = try write()
            ownWrites.recordWrite(path: url.standardizedFileURL.path, sha256: digest)
        } catch let error as StorageError {
            log.error(.storage, error.description)
            throw EngineError.storage(error)
        }
    }

    /// Writes the project.yml of a loaded project and keeps it in memory.
    func saveProject(_ project: Project) throws {
        guard let loaded = domain.projects[project.id] else { return }
        let folder = loaded.folder
        try record(folder.projectFile) { try ProjectFileStore.write(project, to: folder) }
        domain.setProject(project)
    }

    /// Writes the project.yml of a loaded project, keeps it in memory and emits
    /// `project.updated` with `origin`; returns the new ProjectDetail. For the methods of other
    /// areas that change a project file (skills.setEnabled, skill renames and deletes).
    /// Fails with `notFound` when the project is not loaded.
    @discardableResult
    func saveProject(_ project: Project, origin: Actor) throws -> ProjectDetail {
        guard domain.isLoaded(project.id) else {
            throw EngineError.notFound("Project", project.id)
        }
        try saveProject(project)
        emitProjectUpdated(project.id, origin: origin)
        return projectDetail(project.id)!
    }

    /// Writes a project.yml that is not loaded yet.
    func writeProjectFile(_ project: Project, in folder: ProjectFolder) throws {
        try record(folder.projectFile) { try ProjectFileStore.write(project, to: folder) }
    }

    /// Writes a ticket file of a loaded project and keeps the ticket in memory.
    func saveTicket(_ ticket: Ticket) throws {
        guard let projectID = ticket.projectID, let loaded = domain.projects[projectID] else { return }
        let folder = loaded.folder
        try record(folder.ticketFile(ticket.id)) { try ProjectFileStore.write(ticket, to: folder) }
        domain.setTicket(ticket)
    }

    /// Writes a bundle file of a loaded project and keeps the bundle in memory.
    func saveBundle(_ bundle: TicketBundle) throws {
        guard let projectID = bundle.projectID, let loaded = domain.projects[projectID] else { return }
        let folder = loaded.folder
        try record(folder.bundleFile(bundle.id)) { try ProjectFileStore.write(bundle, to: folder) }
        domain.setBundle(bundle)
    }

    /// Writes the metadata file of a loaded chat and keeps it in memory.
    func saveChatMeta(_ meta: ChatMeta) throws {
        guard let loaded = domain.projects[meta.projectID] else { return }
        let folder = loaded.folder
        try record(folder.chatMetaFile(meta.id)) { try ProjectFileStore.write(meta, to: folder) }
        domain.upsertChat(meta)
    }

    /// Writes registry.yml and keeps it in memory.
    func saveRegistry(_ registry: Registry) throws {
        let directory = dataDirectory
        try record(directory.registryFile) { try DeviceFileStore.write(registry, to: directory) }
        domain.registry = registry
    }

    /// Writes current-environments.yml and keeps it in memory (docs/data-model.md › Current
    /// environments file).
    func saveCurrentEnvironments(_ value: CurrentEnvironments) throws {
        let directory = dataDirectory
        try record(directory.currentEnvironmentsFile) { try DeviceFileStore.write(value, to: directory) }
        currentEnvironments = value
    }

    /// Writes `.hephaestus/.gitignore` with the line `chats/`, or appends the line when the file
    /// lacks it (docs/data-model.md › Project folder layout).
    func ensureGitignore(in folder: ProjectFolder) throws {
        do {
            if let digest = try folder.ensureGitignore() {
                ownWrites.recordWrite(path: folder.gitignoreFile.standardizedFileURL.path, sha256: digest)
            }
        } catch let error as StorageError {
            log.error(.storage, error.description)
            throw EngineError.storage(error)
        }
    }

    /// Moves a file or folder to the Trash and records the removal; nothing happens when it does
    /// not exist. Fails with `unavailable` and `<path> cannot be moved to the Trash: <reason>.`,
    /// `<path>` being the item's absolute path (docs/engine-api.md › Writes and consistency).
    func moveToTrash(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var status = stat()
        guard lstat(path, &status) == 0 else { return }
        let isFolder = (status.st_mode & S_IFMT) == S_IFDIR
        let files = isFolder ? Self.regularFiles(in: url) : [path]
        do {
            try moveItemToTrash(url, path: path)
        } catch {
            log.error(.storage, (error as? EngineError)?.message ?? "\(path) cannot be moved to the Trash")
            throw error
        }
        ownWrites.recordRemoval(path: path)
        for file in files {
            ownWrites.recordRemoval(path: file)
        }
    }

    /// The standardized paths of the regular files inside a folder, recursively.
    private static func regularFiles(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result.append(url.standardizedFileURL.path)
        }
        return result
    }

    // MARK: Events

    /// The ProjectDetail of a loaded project, with the last `gitRemoteURL` read and the GitHub
    /// pages it gives, and its environments as they apply; starts a new read, and one of the root
    /// whose origin gives the page of a sub project that uses its parent's settings
    /// (docs/engine-api.md › ProjectDetail).
    func projectDetail(_ id: ProjectID) -> ProjectDetail? {
        guard let loaded = domain.projects[id] else { return nil }
        let hidden = hiddenProjectIDs
        let subprojects = domain.childIDs(of: id).filter { !hidden.contains($0) }.compactMap { projectSummary($0) }
        let remoteURL = gitRemoteURL(root: loaded.rootPath)
        if let source = githubPageSource(of: id), source != id, let sourceRoot = domain.projects[source]?.rootPath {
            refreshGitRemoteURL(root: sourceRoot)
        }
        let environments = resolvedEnvironments(of: id)
        return ProjectDetail(project: loaded.project, rootPath: loaded.rootPath, parentID: loaded.parentID,
                             subprojects: subprojects, gitRemoteURL: remoteURL, githubPage: githubPage(of: id),
                             originGithubPage: originGithubPage(root: loaded.rootPath),
                             environments: environments.environments, inheritedEnvironments: environments.inherited,
                             currentEnvironment: currentEnvironment(of: id, in: environments.environments))
    }

    /// `project.updated` with the current ProjectDetail.
    func emitProjectUpdated(_ id: ProjectID, origin: Actor) {
        guard let detail = projectDetail(id) else { return }
        emit(ProjectUpdatedEvent.self, detail, origin: origin)
    }

    /// `projects.changed` with the complete `projects.list` result.
    func emitProjectsChanged(origin: Actor) {
        emit(ProjectsChangedEvent.self, projectSummaries(), origin: origin)
    }

    /// The `projects.list` result: every loaded project, depth first, with its costs, without the
    /// hidden projects (docs/projects.md › Hiding the HephaestusV2 project).
    func projectSummaries() -> [ProjectSummary] {
        let hidden = hiddenProjectIDs
        guard !hidden.isEmpty else { return domain.loadedProjectIDs().compactMap(projectSummary) }
        return domain.loadedProjectIDs().filter { !hidden.contains($0) }.compactMap { id in
            guard var summary = projectSummary(id) else { return nil }
            summary.subprojectIDs.removeAll { hidden.contains($0) }
            return summary
        }
    }

    /// The ProjectSummary of a loaded project with its own cost and its total
    /// (docs/costs.md › Project totals).
    func projectSummary(_ id: ProjectID) -> ProjectSummary? {
        guard var summary = domain.summary(id) else { return nil }
        summary.ownCostUSD = ownCostUSD(id)
        summary.costUSD = domain.descendants(of: id).reduce(summary.ownCostUSD) { $0 + ownCostUSD($1) }
        summary.commentAnswersRunning = commentAnswers.runningCount(projectID: id)
        return summary
    }

    /// A project's own cost: the sum of its amounts per cost source (docs/costs.md › Cost sources).
    func ownCostUSD(_ id: ProjectID) -> Double {
        CostSource.allCases.reduce(0) { $0 + ownCostUSD(id, source: $1) }
    }

    /// A project's amount of one cost source, its sub projects excluded.
    func ownCostUSD(_ id: ProjectID, source: CostSource) -> Double {
        switch source {
        case .claudeChats:
            // Its chats, a chat without a cost counting 0, plus its deleted chats.
            let chatsCost = domain.chats(of: id).reduce(0) { $0 + (chats.costs[$1.id]?.costUSD ?? 0) }
            return chatsCost + (domain.project(id)?.deletedChatsCostUSD ?? 0)
        case .commentAnswers:
            // Its `commentAnswers` entries, those of deleted tickets included.
            return domain.project(id)?.commentAnswersCostUSD ?? 0
        }
    }

    /// A chat's cost changed: `chat.updated`, then `projects.changed` for the new totals
    /// (docs/costs.md › Live updates).
    func emitChatCostChanged(_ chatID: ChatID, origin: Actor) {
        emitChatUpdated(chatID, origin: origin)
        emitProjectsChanged(origin: origin)
    }

    /// `webTabs.updated` with every tab of the project.
    func emitWebTabsUpdated(_ id: ProjectID, origin: Actor) {
        guard let project = domain.project(id) else { return }
        emit(WebTabsUpdatedEvent.self, WebTabsUpdatedEvent.Payload(projectID: id, tabs: project.webTabs), origin: origin)
    }

    /// A ChatMeta as the API returns it: with `projectID` and the runtime `state`,
    /// `backgroundWork`, `costUSD` and `mentionedIDs`.
    func apiChatMeta(_ meta: ChatMeta) -> ChatMeta {
        var copy = meta
        copy.state = chats.state(of: meta.id)
        copy.backgroundWork = chats.backgroundWork(of: meta.id)
        copy.costUSD = chats.costs[meta.id]?.costUSD
        copy.mentionedIDs = chats.mentions[meta.id]?.ids ?? []
        return copy
    }
}
