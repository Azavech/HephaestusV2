import Foundation

// The HephaestusV2 project of the device: recognition, the launch check and the clone, the
// reserved identifier, the removal refusal and the hiding (docs/projects.md › HephaestusV2
// project).

/// The result of one attempt of the launch check, run outside the actor.
enum HephaestusCloneOutcome: Sendable, Equatable {
    /// The folder holds a clone of the repository.
    case ready(root: String)
    case failed(reason: String)
}

extension Engine {
    /// Time allowed to `git clone` of the HephaestusV2 repository (docs/architecture.md › Child
    /// processes).
    static let hephaestusCloneTimeout: Duration = .seconds(600)

    // MARK: Recognition

    /// `HEPH` when the HephaestusV2 project is on and loaded: the engine loads a project `HEPH`
    /// only for a clone of the repository (docs/projects.md › Recognition).
    var hephaestusProjectID: ProjectID? {
        guard configuration.hephaestusProject != nil, domain.isLoaded(HephaestusRepository.identifier) else { return nil }
        return HephaestusRepository.identifier
    }

    /// True when a project file read at `rootPath` must not load: its identifier is `HEPH` and
    /// its origin does not name the repository (docs/projects.md › Recognition).
    func isReservedIdentifierRefused(_ project: Project, rootPath: String) -> Bool {
        configuration.hephaestusProject != nil && project.id == HephaestusRepository.identifier
            && !HephaestusRepository.isClone(root: rootPath)
    }

    /// `invalid` `HEPH is reserved for HephaestusV2.`
    static var reservedIdentifier: EngineError {
        EngineError(.invalid, "\(HephaestusRepository.identifier) is reserved for HephaestusV2.")
    }

    /// `forbidden` when `id` is the HephaestusV2 project or one of its ancestors
    /// (docs/projects.md › Removing a project).
    func refuseHephaestusRemoval(_ id: ProjectID) throws {
        guard let hephaestus = hephaestusProjectID,
              id == hephaestus || domain.ancestors(of: hephaestus).contains(id) else { return }
        let name = loaded(hephaestus).project.name
        throw EngineError(.forbidden, "“\(name)” cannot be removed: it is the HephaestusV2 project. Hide it in Settings ▸ General instead.")
    }

    // MARK: Hiding (docs/projects.md › Hiding the HephaestusV2 project)

    /// The HephaestusV2 project and its loaded descendants while `showHephaestusProject` is false.
    var hiddenProjectIDs: Set<ProjectID> {
        guard !settings.showHephaestusProject, let id = hephaestusProjectID else { return [] }
        return Set([id] + domain.descendants(of: id))
    }

    /// `conflict` `HephaestusV2 is hidden. Show it in Settings ▸ General.`
    static var hiddenProjectOpened: EngineError {
        EngineError(.conflict, "HephaestusV2 is hidden. Show it in Settings ▸ General.")
    }

    /// The dispatcher check: a call of a user or of Claude whose params name a hidden project, or
    /// a ticket, bundle or chat of one, fails with `notFound` as for a project that is not
    /// registered. The params `projectID`, `parentID`, `ticketID`, `ticketIDs`, `bundleID` and
    /// `chatID` are read at the top level and inside `target`.
    func rejectHiddenNames(in params: Data, actor: Actor) throws {
        guard actor.kind != .system else { return }
        let hidden = hiddenProjectIDs
        guard !hidden.isEmpty, let object = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] else { return }
        try rejectHiddenNames(in: object, hidden: hidden)
        if let target = object["target"] as? [String: Any] {
            try rejectHiddenNames(in: target, hidden: hidden)
        }
    }

    private func rejectHiddenNames(in object: [String: Any], hidden: Set<ProjectID>) throws {
        for key in ["projectID", "parentID"] {
            if let value = object[key] as? String, let id = Identifiers.normalizedProjectID(value), hidden.contains(id) {
                throw EngineError.notFound("Project", id)
            }
        }
        var itemIDs: [(kind: String, id: String)] = []
        if let value = object["ticketID"] as? String {
            itemIDs.append(("Ticket", value))
        }
        for value in object["ticketIDs"] as? [Any] ?? [] {
            if let value = value as? String {
                itemIDs.append(("Ticket", value))
            }
        }
        if let value = object["bundleID"] as? String {
            itemIDs.append(("Bundle", value))
        }
        for item in itemIDs {
            let id = item.id.uppercased()
            if let projectID = Identifiers.projectID(of: id), hidden.contains(projectID) {
                throw EngineError.notFound(item.kind, id)
            }
        }
        if let value = object["chatID"] as? String, let chatID = UUID(uuidString: value),
           let projectID = domain.chat(chatID)?.projectID, hidden.contains(projectID) {
            throw EngineError.notFound("Chat", chatID.uuidString)
        }
    }

    /// The project an event is about, for the events of hidden projects that are not emitted;
    /// nil for an event about no project.
    func eventProjectID(_ payload: Any) -> ProjectID? {
        func ofChat(_ chatID: ChatID) -> ProjectID? { domain.chat(chatID)?.projectID }
        switch payload {
        case let detail as ProjectDetail:
            return detail.project.id
        case let ticket as Ticket:
            return ticket.projectID ?? Identifiers.projectID(of: ticket.id)
        case let event as TicketDeletedEvent.Payload:
            return event.projectID
        case let bundle as TicketBundle:
            return bundle.projectID ?? Identifiers.projectID(of: bundle.id)
        case let event as BundleDeletedEvent.Payload:
            return event.projectID
        case let meta as ChatMeta:
            return meta.projectID
        case let event as ChatDeletedEvent.Payload:
            return event.projectID
        case let event as ChatItemEvent.Payload:
            return ofChat(event.chatID)
        case let event as ChatDeltaEvent.Payload:
            return ofChat(event.chatID)
        case let agents as ChatAgents:
            return agents.projectID
        case let event as ChatAgentItemEvent.Payload:
            return ofChat(event.chatID)
        case let event as FilesChangedEvent.Payload:
            return event.projectID
        case let event as WebTabsUpdatedEvent.Payload:
            return event.projectID
        case let folder as MemoryFolder:
            return folder.projectID
        case let event as ChatNotificationEvent.Payload:
            return event.projectID
        case let event as UIOpenEvent.Payload:
            switch event.target {
            case .project(let projectID), .doc(let projectID, _, _), .file(let projectID, _, _), .webTab(let projectID, _),
                 .section(let projectID, _):
                return projectID
            case .ticket(let ticketID):
                return Identifiers.projectID(of: ticketID)
            case .bundle(let bundleID):
                return Identifiers.projectID(of: bundleID)
            case .chat(let chatID):
                return ofChat(chatID)
            case .skill:
                return nil
            }
        default:
            return nil
        }
    }

    /// `showHephaestusProject` changed (docs/engine-api.md › settings.update). Hidden: the chat
    /// processes and comment answers of the projects stop as when a project is removed,
    /// `project.removed` is emitted for each of them, depth first, then `projects.changed`.
    /// Shown: `projects.changed` lists them again.
    func hephaestusVisibilityDidChange(shown: Bool, origin: Actor) {
        guard let id = hephaestusProjectID else { return }
        if shown {
            log.info(.engine, "the HephaestusV2 project \(id) is shown")
            emitProjectsChanged(origin: origin)
            return
        }
        let ids = [id] + domain.descendants(of: id)
        log.info(.engine, "the HephaestusV2 project \(id) is hidden with \(ids.count - 1) sub project(s)")
        stopCommentAnswers(projectIDs: Set(ids))
        emitProjectsRemoved(ids, origin: origin)
        emitProjectsChanged(origin: origin)
        terminateChatProcesses(inProjects: ids)
    }

    // MARK: Launch check and clone (docs/projects.md › Launch check and clone)

    /// Starts an attempt when the HephaestusV2 project is on, not loaded, no attempt runs and the
    /// tools are known; returns at once. Called once the tools are looked up and by
    /// `projects.ensureHephaestus`.
    func ensureHephaestusProject() {
        guard let configuration = configuration.hephaestusProject, !hasStopped, hephaestusProjectID == nil,
              hephaestusAttempt == nil, files.tools != FileTools.notLookedUp else { return }
        let root = dataDirectory.url.appendingPathComponent(HephaestusRepository.name, isDirectory: true).path
        let temporary = dataDirectory.url.appendingPathComponent(".\(HephaestusRepository.name).clone", isDirectory: true).path
        let git = files.tools.git
        var environment = files.tools.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let log = self.log
        log.info(.engine, "the HephaestusV2 project is not loaded: preparing \(root)")
        let process = hephaestusCloneProcess
        hephaestusAttempt = Task {
            let outcome = await Engine.prepareHephaestusClone(git: git, cloneURL: configuration.cloneURL, root: root,
                                                              temporary: temporary, environment: environment) { process.set($0) }
            process.set(nil)
            self.hephaestusAttemptEnded(outcome)
        }
    }

    /// Shutdown: a running `git clone` gets SIGTERM on its process group, then SIGKILL 3 s later
    /// (docs/architecture.md › Shutdown).
    func stopHephaestusClone() async {
        guard let attempt = hephaestusAttempt else { return }
        hephaestusCloneProcess.process?.signalGroup(SIGTERM)
        let killer = Task { [process = hephaestusCloneProcess] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            process.process?.signalGroup(SIGKILL)
        }
        await attempt.value
        killer.cancel()
    }

    /// Waits for the running attempt, for tests.
    func waitForHephaestusAttempt() async {
        await hephaestusAttempt?.value
    }

    /// Steps 1 and 2: an existing clone is used; otherwise the repository is cloned into the
    /// temporary folder, which is renamed to `root` once the clone succeeded.
    static func prepareHephaestusClone(git: String?, cloneURL: String, root: String, temporary: String,
                                       environment: [String: String],
                                       started: (@Sendable (ChildProcess) -> Void)? = nil) async -> HephaestusCloneOutcome {
        let manager = FileManager.default
        if manager.fileExists(atPath: root) {
            guard HephaestusRepository.isClone(root: root) else {
                return .failed(reason: "\(root) exists and is not a clone of \(HephaestusRepository.path)")
            }
            return .ready(root: root)
        }
        guard let git else {
            return .failed(reason: "git was not found")
        }
        if manager.fileExists(atPath: temporary) {
            do {
                try manager.removeItem(atPath: temporary)
            } catch {
                return .failed(reason: "\(temporary) cannot be deleted: \(error.localizedDescription)")
            }
        }
        let directory = (root as NSString).deletingLastPathComponent
        let request = ChildProcessRequest(executable: git, arguments: ["clone", "--quiet", "--", cloneURL, temporary],
                                          environment: environment, currentDirectory: directory)
        let failure: String?
        do {
            let result = try await ChildProcessRunner.run(request, timeout: hephaestusCloneTimeout, started: started)
            if result.timedOut {
                failure = "git clone timed out"
            } else if !result.termination.isSuccess {
                let message = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
                failure = "git clone failed: \(message.isEmpty ? "\(result.termination)" : message)"
            } else if cloneURL != HephaestusRepository.url,
                      await GitTool.run(git, ["remote", "set-url", "origin", HephaestusRepository.url], in: temporary,
                                        environment: environment)?.status != 0 {
                failure = "the origin of \(temporary) cannot be set"
            } else {
                failure = nil
            }
        } catch {
            failure = "git clone cannot start: \(error)"
        }
        if let failure {
            try? manager.removeItem(atPath: temporary)
            return .failed(reason: failure)
        }
        do {
            try manager.moveItem(atPath: temporary, toPath: root)
        } catch {
            try? manager.removeItem(atPath: temporary)
            return .failed(reason: "\(temporary) cannot be renamed to \(root): \(error.localizedDescription)")
        }
        return .ready(root: root)
    }

    /// Steps 3 and 4: the project file when missing, then the registration as a top-level
    /// project. A failure is logged; the next launch or `projects.ensureHephaestus` tries again.
    private func hephaestusAttemptEnded(_ outcome: HephaestusCloneOutcome) {
        hephaestusAttempt = nil
        guard !hasStopped else { return }
        switch outcome {
        case .failed(let reason):
            log.warn(.engine, "the HephaestusV2 project is not available: \(reason); it is tried again at the next launch and when feedback starts")
        case .ready(let root):
            guard hephaestusProjectID == nil else {
                log.info(.engine, "a HephaestusV2 project was loaded meanwhile; \(root) is not registered")
                return
            }
            do {
                try registerHephaestusClone(root: DomainPaths.standardize(root))
            } catch let error as EngineError {
                log.warn(.engine, "the HephaestusV2 project at \(root) cannot be registered: \(error.message)")
            } catch {
                log.warn(.engine, "the HephaestusV2 project at \(root) cannot be registered: \(error)")
            }
        }
    }

    private func registerHephaestusClone(root: String) throws {
        if let other = domain.projectID(atRoot: root) {
            log.warn(.engine, "\(root) is loaded as \(other), not as the HephaestusV2 project")
            return
        }
        let folder = ProjectFolder(root: URL(fileURLWithPath: root, isDirectory: true))
        if !FileManager.default.fileExists(atPath: folder.projectFile.path) {
            let project = Project(id: HephaestusRepository.identifier, name: HephaestusRepository.name, created: ISODate.now(),
                                  type: .swiftApplication)
            try writeProjectFile(project, in: folder)
            log.info(.engine, "created \(folder.projectFile.path)")
        }
        try ensureGitignore(in: folder)
        try register(rootPath: root, parentID: nil)
        loadTree(rootPath: root, parentID: nil)
        guard let id = domain.projectID(atRoot: root) else {
            log.warn(.engine, "\(root) is registered but its project does not load")
            return
        }
        log.info(.engine, "the HephaestusV2 project \(id) is loaded from \(root)")
        emitProjectUpdated(id, origin: .system)
        emitProjectsChanged(origin: .system)
        updateFileWatching()
        keepGitHubTabs(origin: .system)
    }
}

/// The `git clone` process of the running attempt, read by the shutdown.
final class HephaestusCloneProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ChildProcess?

    var process: ChildProcess? {
        lock.withLock { current }
    }

    func set(_ process: ChildProcess?) {
        lock.withLock { current = process }
    }
}
