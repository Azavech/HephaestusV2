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
    /// not exist, `internal` when its file exists but never loaded (docs/tickets.md › Errors).
    // DOC-GAP: docs/engine-api.md lists the `internal` error of a ticket file that never loaded
    // for tickets.get only; docs/tickets.md › Errors gives it without a method, so every method
    // that names such a ticket fails with it.
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
    /// not exist. Fails with `unavailable` and `<path> cannot be moved to the Trash: <reason>.`
    // DOC-GAP: docs/engine-api.md › Writes and consistency does not say which form `<path>` takes;
    // the absolute path of the item on the main device is used.
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

    /// The ProjectDetail of a loaded project; `gitRemoteURL` is read each time.
    func projectDetail(_ id: ProjectID) -> ProjectDetail? {
        guard let loaded = domain.projects[id] else { return nil }
        let subprojects = domain.childIDs(of: id).compactMap { domain.summary($0) }
        return ProjectDetail(project: loaded.project, rootPath: loaded.rootPath, parentID: loaded.parentID,
                             subprojects: subprojects, gitRemoteURL: gitRemoteURL(root: loaded.rootPath))
    }

    /// `project.updated` with the current ProjectDetail.
    func emitProjectUpdated(_ id: ProjectID, origin: Actor) {
        guard let detail = projectDetail(id) else { return }
        emit(ProjectUpdatedEvent.self, detail, origin: origin)
    }

    /// `projects.changed` with the complete `projects.list` result.
    func emitProjectsChanged(origin: Actor) {
        emit(ProjectsChangedEvent.self, domain.projectSummaries(), origin: origin)
    }

    /// `webTabs.updated` with every tab of the project.
    func emitWebTabsUpdated(_ id: ProjectID, origin: Actor) {
        guard let project = domain.project(id) else { return }
        emit(WebTabsUpdatedEvent.self, WebTabsUpdatedEvent.Payload(projectID: id, tabs: project.webTabs), origin: origin)
    }

    /// A ChatMeta as the API returns it: with `projectID` and the runtime `state`.
    func apiChatMeta(_ meta: ChatMeta) -> ChatMeta {
        var copy = meta
        copy.state = chats.state(of: meta.id)
        return copy
    }

    /// `git config --get remote.origin.url` run in the root with the `git` and the environment of
    /// the tools lookup (docs/architecture.md › Child processes, rule 5); nil without git (or
    /// before the lookup ran), outside a git work tree or without an `origin` remote
    /// (docs/engine-api.md › ProjectDetail).
    func gitRemoteURL(root: String) -> String? {
        guard let git = files.tools.git else { return nil }
        guard let result = GitTool.run(git, ["config", "--get", "remote.origin.url"], in: root,
                                       environment: files.tools.environment),
              result.status == 0 else { return nil }
        let url = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }
}

/// The `git` tool of docs/architecture.md › Child processes, rule 5, run synchronously on the
/// engine actor so that a ProjectDetail is built in one step with the change it describes.
enum GitTool {
    /// Time allowed to one git call before it is killed.
    // DOC-GAP: the docs give no timeout for `git config`; 5 s.
    static let timeout: TimeInterval = 5

    /// Time between SIGTERM and SIGKILL for a call that timed out (docs/architecture.md › Child
    /// processes, the sequence of the other children).
    static let killGrace: TimeInterval = 2

    /// Runs a tool with standard output piped and returns its exit status and output; nil when
    /// it cannot start or times out. A call that times out gets SIGTERM, then SIGKILL 2 s later.
    static func run(_ executable: String, _ arguments: [String], in directory: String, environment: [String: String],
                    timeout: TimeInterval = GitTool.timeout) -> (status: Int32, output: Data)? {
        let request = ChildProcessRequest(executable: executable, arguments: arguments, environment: environment,
                                          currentDirectory: directory, standardInput: .null, standardOutput: .pipe,
                                          standardError: .null)
        guard let process = try? ChildProcess.spawn(request), let handle = process.standardOutput else { return nil }
        let box = OutputBox()
        let done = DispatchSemaphore(value: 0)
        // The reading thread keeps the handle until end of file, so its descriptor stays open
        // while it reads.
        Thread.detachNewThread {
            box.set(handle.readDataToEndOfFile())
            done.signal()
        }
        func waitForExit(until deadline: Date) -> Bool {
            while !process.hasExited, Date() < deadline {
                usleep(1000)
            }
            return process.hasExited
        }
        func stop() {
            guard !process.hasExited else { return }
            process.signalGroup(SIGTERM)
            if !waitForExit(until: Date().addingTimeInterval(killGrace)) {
                process.signalGroup(SIGKILL)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        guard done.wait(timeout: .now() + timeout) == .success, waitForExit(until: deadline),
              case .exited(let status)? = process.termination else {
            stop()
            return nil
        }
        return (status, box.value)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.withLock { data = value } }
        var value: Data { lock.withLock { data } }
    }
}
