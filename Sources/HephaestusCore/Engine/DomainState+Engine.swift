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
            try domain.trash.trashItem(at: url)
        } catch {
            var reason = error.localizedDescription
            while reason.hasSuffix(".") { reason.removeLast() }
            log.error(.storage, "\(path) cannot be moved to the Trash: \(reason)")
            throw EngineError(.unavailable, "\(path) cannot be moved to the Trash: \(reason).")
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

    // MARK: Child process environment

    /// The environment of project runs and tools: the login-shell environment without any
    /// `HEPHAESTUS_*` variable (docs/architecture.md › Child processes, rule 1).
    // DEPENDENCY(core-claude): the login-shell environment is captured by the Claude CLI
    // background tasks (`startClaudeBackgroundTasks`), which expose no accessor yet; until
    // integration the app's own environment, without `HEPHAESTUS_*`, is used.
    func childProcessEnvironment() -> [String: String] {
        ProcessEnvironment.withoutHephaestusVariables(ProcessInfo.processInfo.environment)
    }

    /// `git config --get remote.origin.url` run in the root; nil without git, outside a git work
    /// tree or without an `origin` remote (docs/engine-api.md › ProjectDetail).
    func gitRemoteURL(root: String) -> String? {
        if domain.gitExecutable == .notLookedUp {
            domain.gitExecutable = GitTool.lookUp(environment: childProcessEnvironment())
        }
        guard case .found(let git) = domain.gitExecutable else { return nil }
        guard let result = GitTool.run(git, ["config", "--get", "remote.origin.url"], in: root,
                                       environment: childProcessEnvironment()),
              result.status == 0 else { return nil }
        let url = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }
}

/// The `git` tool of docs/architecture.md › Child processes, rule 5, run synchronously on the
/// engine actor so that a ProjectDetail is built in one step with the change it describes.
// DEPENDENCY(core-claude): the tools are looked up by the Claude CLI background tasks after the
// environment capture; until integration the lookup runs here once, with the same rule.
enum GitTool {
    /// Time allowed to one git call before it is killed.
    // DOC-GAP: the docs give no timeout for `git config`; 5 s.
    static let timeout: TimeInterval = 5

    /// The first executable `git` in the `PATH` of `environment`; `/usr/bin/git` only when
    /// `/usr/bin/xcode-select -p` exits with status 0.
    static func lookUp(environment: [String: String]) -> GitExecutable {
        for folder in (environment["PATH"] ?? "").split(separator: ":") where !folder.isEmpty {
            let candidate = (String(folder) as NSString).appendingPathComponent("git")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if candidate == "/usr/bin/git" {
                guard let result = run("/usr/bin/xcode-select", ["-p"], in: "/", environment: environment, timeout: 10),
                      result.status == 0 else { return .missing }
            }
            return .found(candidate)
        }
        return .missing
    }

    /// Runs a tool with standard output piped and returns its exit status and output; nil when
    /// it cannot start or times out.
    static func run(_ executable: String, _ arguments: [String], in directory: String, environment: [String: String],
                    timeout: TimeInterval = GitTool.timeout) -> (status: Int32, output: Data)? {
        let request = ChildProcessRequest(executable: executable, arguments: arguments, environment: environment,
                                          currentDirectory: directory, standardInput: .null, standardOutput: .pipe,
                                          standardError: .null)
        guard let process = try? ChildProcess.spawn(request), let handle = process.standardOutput else { return nil }
        let box = OutputBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(handle.readDataToEndOfFile())
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.signalGroup(SIGKILL)
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !process.hasExited, Date() < deadline {
            usleep(1000)
        }
        guard case .exited(let status)? = process.termination else {
            process.signalGroup(SIGKILL)
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
