import Foundation

/// What a turn of a chat tells its orchestrator chat when it ends (docs/chats.md › Orchestrated
/// ticket chats).
struct TurnReport {
    /// The text of the turn's last assistant item without `parentToolUseID`.
    var reply: String?
    /// The user stopped the turn with Stop.
    var stopped = false
    /// The text of the turn's last error item, else the summary of its last error result.
    var errorText: String?
    var resultError: String?

    mutating func record(_ item: ChatItem) {
        switch item {
        case .assistant(let assistant) where assistant.parentToolUseID == nil:
            reply = assistant.text
        case .system(let system) where system.level == .error:
            errorText = system.text
        case .result(let result):
            if result.isError, result.summary == Engine.stoppedSummary {
                stopped = true
            } else if result.isError {
                resultError = result.summary ?? ""
            } else {
                resultError = nil
            }
        default:
            break
        }
    }

    /// The message to the orchestrator for a turn of the chat of `ticketID` that ended in
    /// `state` (`idle` or `error`).
    func message(ticketID: TicketID, state: ChatState) -> String {
        if stopped { return "Chat of \(ticketID) was stopped." }
        if state == .error || resultError != nil {
            return "Chat of \(ticketID) ended in error: \(errorText ?? resultError ?? "")"
        }
        return "Chat of \(ticketID) finished its turn:\n\n\(reply ?? "")"
    }
}

extension Engine {
    /// The chat states of a turn.
    static let turnStates: Set<ChatState> = [.starting, .running, .waitingPermission]

    /// Records the state reported by `chat.updated`. A turn that starts clears the turn's report;
    /// a change from a state already reported can post a notification (docs/chats.md ›
    /// Notifications); a turn of a chat with an orchestrator that ends in `idle` or `error` sends
    /// the report to the orchestrator chat (docs/chats.md › Orchestrated ticket chats).
    func recordReportedState(_ meta: ChatMeta) {
        let previous = chats.reportedStates[meta.id]
        chats.reportedStates[meta.id] = meta.state
        chats.reportedBackgroundWork[meta.id] = meta.backgroundWork
        let wasInTurn = previous.map { Engine.turnStates.contains($0) } ?? false
        let startsTurn = !wasInTurn && Engine.turnStates.contains(meta.state)
        if startsTurn {
            chats.runtimes[meta.id]?.turnReport = TurnReport()
        }
        if let previous {
            postChatNotification(meta, previous: previous)
        }
        if startsTurn { return }
        guard wasInTurn, meta.state == .idle || meta.state == .error, let orchestratorID = meta.orchestratorChatID,
              let ticketID = meta.ticketID
        else { return }
        let report = chats.runtimes[meta.id]?.turnReport ?? TurnReport()
        let text = report.message(ticketID: ticketID, state: meta.state)
        Task { self.sendOrchestratorReport(text, to: orchestratorID, from: meta.id) }
    }

    /// Sends a ticket chat's report to its orchestrator as the `system` actor; skipped while the
    /// engine stops or when the orchestrator chat is gone.
    func sendOrchestratorReport(_ text: String, to orchestratorID: ChatID, from chatID: ChatID) {
        guard !chats.stopped, !domain.isStopped, !chats.deleting.contains(orchestratorID), domain.chat(orchestratorID) != nil else {
            log.info(.claude, "chat \(chatID.uuidString): the report to the orchestrator chat \(orchestratorID.uuidString) was not sent")
            return
        }
        do {
            try sendChatMessage(orchestratorID, text: text, attachments: [], sender: senderName(.system), origin: .system)
        } catch {
            log.error(.claude, "chat \(chatID.uuidString): the report to the orchestrator chat \(orchestratorID.uuidString) failed: \(error)")
        }
    }
}

/// The branch and the worktree of an orchestrated ticket chat (docs/chats.md › Branch and
/// worktree).
struct ChatWorktree: Sendable, Equatable {
    /// `<data dir>/Worktrees/<project id>/<ticket id>`.
    var path: URL
    /// `<bundle id>/<ticket id>`.
    var branch: String

    init(path: URL, branch: String) {
        self.path = path
        self.branch = branch
    }

    init(dataDirectory: DataDirectory, projectID: ProjectID, bundleID: BundleID, ticketID: TicketID) {
        self.init(path: dataDirectory.worktree(projectID: projectID, ticketID: ticketID), branch: "\(bundleID)/\(ticketID)")
    }

    /// The folder of the worktree that matches the project root: the worktree itself when the
    /// project root is the top folder of its git repository, else the same subfolder of the
    /// worktree (docs/chats.md › Working directory).
    func projectFolder(projectRoot: URL) -> URL {
        var folder = projectRoot.standardizedFileURL
        var components: [String] = []
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { return path }
            components.insert(folder.lastPathComponent, at: 0)
            folder = parent
        }
        return components.reduce(path) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}

/// The working directory of a chat at a launch (docs/chats.md › Working directory): the
/// project root, or the worktree of an orchestrated ticket chat.
struct ChatWorkingDirectory: Sendable, Equatable {
    var url: URL
    /// The worktree, when the chat works in it.
    var worktree: ChatWorktree?

    /// `{{workingDirectory}}` (docs/chats.md › Rendered blocks).
    var promptSentence: String {
        guard let worktree else { return "It is your working directory." }
        return "Your working directory is the git worktree \(url.path) of this project, on the branch \(worktree.branch): "
            + "read, change, build, test and commit the project's files there, not in the project root."
    }
}

/// Why the branch and the worktree of an orchestrated ticket chat cannot be created: the
/// `<reason>` of docs/chats.md › Branch and worktree.
struct WorktreeFailure: Error, Equatable {
    var reason: String
}

/// The git commands that create the branch and the worktree of an orchestrated ticket chat
/// (docs/chats.md › Branch and worktree), run in the project root.
enum WorktreeGit {
    /// Time allowed to each git command (docs/architecture.md › Child processes, the table of
    /// tool runs).
    static let timeout: Duration = .seconds(60)

    /// Steps 1 to 4: removes the worktree and the branch an earlier chat of the ticket left, then
    /// creates the branch from `HEAD` of the project root, checked out in the worktree.
    static func prepare(_ worktree: ChatWorktree, root: URL, git: String?, environment: [String: String]) async throws {
        guard let git else { throw WorktreeFailure(reason: "git is not available") }
        func run(_ arguments: [String]) async throws -> ProcessResult {
            let request = ChildProcessRequest(executable: git, arguments: arguments, environment: environment, currentDirectory: root.path)
            let result: ProcessResult
            do {
                result = try await ChildProcessRunner.run(request, timeout: timeout)
            } catch {
                throw WorktreeFailure(reason: "git cannot start: \(error)")
            }
            if result.timedOut { throw WorktreeFailure(reason: "git did not finish within 60 seconds") }
            return result
        }
        func succeed(_ arguments: [String]) async throws -> ProcessResult {
            let result = try await run(arguments)
            guard result.termination == .exited(0) else {
                let error = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
                let output = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
                throw WorktreeFailure(reason: error.isEmpty ? output : error)
            }
            return result
        }
        // 1. A worktree registered at the path is removed.
        let target = Engine.resolvedPath(worktree.path)
        let listed = try await succeed(["worktree", "list", "--porcelain"]).standardOutputText
            .split(separator: "\n")
            .contains { $0.hasPrefix("worktree ") && Engine.resolvedPath(URL(fileURLWithPath: String($0.dropFirst(9)))) == target }
        if listed {
            _ = try await succeed(["worktree", "remove", "--force", "--force", worktree.path.path])
        }
        // 2. A folder left at the path is deleted.
        if FileManager.default.fileExists(atPath: worktree.path.path) {
            do {
                try FileManager.default.removeItem(at: worktree.path)
            } catch {
                throw WorktreeFailure(reason: "\(worktree.path.path) cannot be deleted: \(error.localizedDescription)")
            }
        }
        _ = try await succeed(["worktree", "prune"])
        // 3. The branch left by an earlier chat is deleted.
        if try await run(["show-ref", "--verify", "--quiet", "refs/heads/\(worktree.branch)"]).termination == .exited(0) {
            _ = try await succeed(["branch", "-D", worktree.branch])
        }
        // 4. The new branch from the project root's current commit, checked out in the worktree.
        do {
            try FileManager.default.createDirectory(at: worktree.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw WorktreeFailure(reason: "\(worktree.path.deletingLastPathComponent().path) cannot be created: \(error.localizedDescription)")
        }
        _ = try await succeed(["worktree", "add", "-b", worktree.branch, worktree.path.path, "HEAD"])
    }
}

extension Engine {
    /// Creates the branch and the worktree of an orchestrated ticket chat of `ticketID` started
    /// by a chat of `bundleID`, one preparation at a time (docs/chats.md › Branch and worktree).
    func prepareWorktree(projectID: ProjectID, root: URL, bundleID: BundleID, ticketID: TicketID) async throws {
        let worktree = ChatWorktree(dataDirectory: dataDirectory, projectID: projectID, bundleID: bundleID, ticketID: ticketID)
        let git = files.tools.git
        let environment = files.tools.environment
        let previous = chats.worktreePreparation
        let preparation = Task {
            await previous?.value
            try await WorktreeGit.prepare(worktree, root: root, git: git, environment: environment)
        }
        chats.worktreePreparation = Task { _ = try? await preparation.value }
        do {
            try await preparation.value
            log.info(.claude, "branch \(worktree.branch) created in the worktree \(worktree.path.path)")
        } catch let failure as WorktreeFailure {
            log.warn(.claude, "the branch and worktree of \(ticketID) cannot be created: \(failure.reason)")
            throw EngineError(.unavailable, "Cannot create the branch and worktree of \(ticketID): \(failure.reason)")
        }
    }

    /// The working directory of a chat at a launch (docs/chats.md › Working directory): the
    /// worktree of an orchestrated ticket chat while its orchestrator chat exists, it is its
    /// ticket's newest orchestrated ticket chat and the worktree's folder exists; else the
    /// project root.
    func chatWorkingDirectory(_ meta: ChatMeta, root: URL) -> ChatWorkingDirectory {
        let projectRoot = ChatWorkingDirectory(url: root)
        guard meta.kind == .ticket, let orchestratorID = meta.orchestratorChatID, let ticketID = meta.ticketID,
              let bundleID = domain.chat(orchestratorID)?.bundleID, let ticket = domain.ticket(ticketID),
              ticket.chatIDs.last(where: { domain.chat($0)?.orchestratorChatID != nil }) == meta.id
        else { return projectRoot }
        let worktree = ChatWorktree(dataDirectory: dataDirectory, projectID: meta.projectID, bundleID: bundleID, ticketID: ticketID)
        let folder = worktree.projectFolder(projectRoot: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return projectRoot }
        return ChatWorkingDirectory(url: folder, worktree: worktree)
    }

    /// The working directory of a run of `projectID` started by `actor` (docs/engine-api.md ›
    /// projects.run): the worktree of the calling chat when it works in one, else the project
    /// root.
    func runWorkingDirectory(projectID: ProjectID, actor: Actor) -> ChatWorkingDirectory {
        let root = URL(fileURLWithPath: loaded(projectID).rootPath, isDirectory: true)
        guard let chatID = actor.chat, let meta = domain.chat(chatID), meta.projectID == projectID else {
            return ChatWorkingDirectory(url: root)
        }
        return chatWorkingDirectory(meta, root: root)
    }
}
