import Darwin
import Foundation

/// The comment answers at runtime (docs/chats.md › Comment answers): the answer state of each
/// comment and the running calls. Engine state, lost when the app quits.
final class CommentAnswers {
    /// One running call.
    struct Call {
        var ticketID: TicketID
        var commentID: UUID
        var projectID: ProjectID
        /// Ends the call's process early (deletion of its comment, ticket or project).
        let stopper: CommentAnswerStopper
    }

    /// The answer state of each comment, by comment id: `replying` while its call runs, `failed`
    /// after it failed.
    var states: [UUID: CommentAnswerState] = [:]
    /// The running calls, by answer id.
    var calls: [UUID: Call] = [:]
    /// A call still running this long after its start is stopped (docs/chats.md › Answer command).
    var timeout: Duration = .seconds(300)
    /// The SIGKILL that follows the SIGTERM of a call ended early or by its timeout.
    var killGrace: Duration = .seconds(5)

    /// The number of calls running for the tickets of a project.
    func runningCount(projectID: ProjectID) -> Int {
        calls.values.filter { $0.projectID == projectID }.count
    }

    /// The answer ids of the running calls that satisfy `predicate`.
    func callIDs(where predicate: (Call) -> Bool) -> [UUID] {
        calls.filter { predicate($0.value) }.map(\.key)
    }
}

/// Ends the process of a comment answer call, from the engine, before or after the process
/// started: SIGTERM to its process group, then SIGKILL `killGrace` later when it is still alive
/// (docs/chats.md › Signals).
final class CommentAnswerStopper: @unchecked Sendable {
    private let lock = NSLock()
    private var process: (any ClaudeProcess)?
    private var stopRequested = false
    private let killGrace: Duration

    init(killGrace: Duration) {
        self.killGrace = killGrace
    }

    /// True once `stop()` was called.
    var isStopped: Bool { lock.withLock { stopRequested } }

    /// The call's process started; a stop requested before ends it at once.
    func started(_ process: any ClaudeProcess) {
        let stopNow = lock.withLock { () -> Bool in
            self.process = process
            return stopRequested
        }
        if stopNow { terminate(process) }
    }

    /// Ends the process, or the process that starts later.
    func stop() {
        let process = lock.withLock { () -> (any ClaudeProcess)? in
            guard !stopRequested else { return nil }
            stopRequested = true
            return self.process
        }
        if let process { terminate(process) }
    }

    private func terminate(_ process: any ClaudeProcess) {
        guard !process.hasExited else { return }
        process.signalGroup(SIGTERM)
        let grace = killGrace
        Task.detached {
            try? await Task.sleep(for: grace)
            guard !process.hasExited else { return }
            process.signalGroup(SIGKILL)
        }
    }
}

/// The outcome of a comment answer call read from its process (docs/chats.md › Answer output).
struct CommentAnswerOutcome: Equatable {
    /// `total_cost_usd` of the output when it is a JSON object with a number of at least 0.
    var costUSD: Double?
    /// The trimmed `result` of a successful call.
    var answer: String?
    /// Why the call failed, for `engine.log`; nil on success.
    var failure: String?

    /// Steps 1, 2 and 4 of docs/chats.md › Answer output.
    static func read(_ result: HelperResult) -> CommentAnswerOutcome {
        if result.timedOut { return CommentAnswerOutcome(failure: "timeout") }
        if let spawnError = result.spawnError { return CommentAnswerOutcome(failure: "could not start: \(spawnError)") }
        let object = (try? JSONDecoder().decode(JSONValue.self, from: result.standardOutput))?.objectValue
        var outcome = CommentAnswerOutcome()
        if let cost = object?["total_cost_usd"]?.claudeDouble, cost >= 0, cost.isFinite {
            outcome.costUSD = cost
        }
        switch result.termination {
        case .exited(0)?:
            break
        case .exited(let code)?:
            outcome.failure = "exit code \(code)"
            return outcome
        case .signaled(let signal)?:
            outcome.failure = "exit code \(128 + signal)"
            return outcome
        case nil:
            outcome.failure = "no exit status"
            return outcome
        }
        guard let object else {
            outcome.failure = "the output is not a JSON object"
            return outcome
        }
        if object["is_error"]?.claudeBool == true {
            outcome.failure = "is_error is true"
            return outcome
        }
        let answer = object["result"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !answer.isEmpty else {
            outcome.failure = "the result is empty"
            return outcome
        }
        outcome.answer = answer
        return outcome
    }
}

extension Engine {
    // MARK: Starting

    /// Starts a comment answer call for a comment of a loaded ticket: the comment's state becomes
    /// `replying` and the call runs in the background (docs/chats.md › Comment answers). The caller
    /// emits the `ticket.updated` and the `projects.changed` that show it.
    func startCommentAnswer(ticketID: TicketID, projectID: ProjectID, commentID: UUID) {
        let answerID = UUID()
        commentAnswers.states[commentID] = .replying
        commentAnswers.calls[answerID] = CommentAnswers.Call(
            ticketID: ticketID, commentID: commentID, projectID: projectID,
            stopper: CommentAnswerStopper(killGrace: commentAnswers.killGrace))
        Task { await self.runCommentAnswer(answerID) }
    }

    /// docs/engine-api.md › tickets.retryAnswer.
    func ticketsRetryAnswer(_ params: TicketsRetryAnswer.Params, _ actor: Actor) async throws -> Ticket {
        let ticket = try existingTicket(params.ticketID)
        guard ticket.comments.contains(where: { $0.id == params.commentID }) else {
            throw EngineError.notFound("Comment", params.commentID.uuidString)
        }
        guard commentAnswers.states[params.commentID] == .failed else {
            throw EngineError(.conflict, "Comment \(params.commentID.uuidString) has no failed answer to retry.")
        }
        startCommentAnswer(ticketID: ticket.id, projectID: ticket.projectID!, commentID: params.commentID)
        emitTicketUpdated(ticket, origin: actor)
        emitProjectsChanged(origin: actor)
        return ticket
    }

    // MARK: Stopping

    /// Stops the calls running for the comments that satisfy `predicate` and drops their states;
    /// a stopped call posts nothing (docs/tickets.md › Comment answers).
    func stopCommentAnswers(where predicate: (CommentAnswers.Call) -> Bool) {
        for answerID in commentAnswers.callIDs(where: predicate) {
            commentAnswers.calls[answerID]?.stopper.stop()
        }
    }

    /// Deleting a comment stops its call and drops its state.
    func stopCommentAnswer(commentID: UUID) {
        stopCommentAnswers { $0.commentID == commentID }
        commentAnswers.states[commentID] = nil
    }

    /// Deleting a ticket stops the calls of its comments and drops their states.
    func stopCommentAnswers(of ticket: Ticket) {
        stopCommentAnswers { $0.ticketID == ticket.id }
        for comment in ticket.comments {
            commentAnswers.states[comment.id] = nil
        }
    }

    /// Removing projects stops the calls of their tickets.
    func stopCommentAnswers(projectIDs: Set<ProjectID>) {
        stopCommentAnswers { projectIDs.contains($0.projectID) }
    }

    // MARK: The call

    /// Runs one call (docs/chats.md › Answer command): the CLI, the answer token and its MCP
    /// configuration file, the prompt and the input, the process, then its outcome.
    private func runCommentAnswer(_ answerID: UUID) async {
        let context: ClaudeLaunchContext
        do {
            guard !claudeCLI.stopped else { return }
            context = try await requireClaudeCLI()
        } catch {
            await finishCommentAnswer(answerID, outcome: CommentAnswerOutcome(failure: "the Claude CLI is not available"))
            return
        }
        guard let call = commentAnswers.calls[answerID], !call.stopper.isStopped else {
            await finishCommentAnswer(answerID, outcome: CommentAnswerOutcome(failure: "stopped"))
            return
        }
        guard let ticket = domain.ticket(call.ticketID), let comment = ticket.comments.first(where: { $0.id == call.commentID }),
              let project = domain.project(call.projectID), let root = domain.projectRoot(call.projectID)
        else {
            await finishCommentAnswer(answerID, outcome: CommentAnswerOutcome(failure: "the comment no longer exists"))
            return
        }
        let mcpState = await mcpServer.state
        let port: Int
        if case .listening(let listening) = mcpState { port = listening } else { port = effectiveMCPPort }
        let token = await tokens.issueAnswerToken(answerID: answerID, ticketID: ticket.id)
        let configURL = dataDirectory.mcpAnswerConfigFile(answerID: answerID)
        defer { try? FileManager.default.removeItem(at: configURL) }
        do {
            try FileManager.default.createDirectory(at: dataDirectory.mcpConfigFolder, withIntermediateDirectories: true)
            try AtomicFile.write(ClaudeCommandLine.mcpConfiguration(port: port, token: token), to: configURL,
                                 newFileMode: AtomicFile.privateMode)
        } catch {
            await tokens.revokeAnswerToken(answerID: answerID)
            await finishCommentAnswer(answerID, outcome: CommentAnswerOutcome(failure: "could not start: \(error)"))
            return
        }
        let defaults = project.chatDefaults ?? settings.defaultChatSettings
        let argv = ClaudeCommandLine.commentAnswer(
            cliPath: context.path, model: defaults.model, effort: defaults.effort.rawValue, mcpConfigPath: configURL.path,
            systemPrompt: commentAnswerPrompt(ticketID: ticket.id, project: project, root: root),
            input: Prompts.commentAnswerInput(ticketRendering: renderTicket(ticket, excluding: nil), comment: comment,
                                              projectRoot: root.path))
        let request = ChildProcessRequest(executable: argv[0], arguments: Array(argv.dropFirst()), environment: context.environment,
                                          currentDirectory: root.path)
        let stopper = call.stopper
        let result = await ClaudeHelperRun.run(request, launcher: configuration.claudeLauncher, registry: claudeCLI.helpers,
                                               timeout: commentAnswers.timeout, killGrace: commentAnswers.killGrace,
                                               started: { stopper.started($0) })
        await tokens.revokeAnswerToken(answerID: answerID)
        await finishCommentAnswer(answerID, outcome: CommentAnswerOutcome.read(result))
    }

    /// The rendered comment-answer prompt of a ticket (docs/chats.md › Prompt: comment-answer).
    func commentAnswerPrompt(ticketID: TicketID, project: Project, root: URL) -> String {
        Prompts.render(Prompts.text(.commentAnswer), [
            "projectName": project.name,
            "projectID": project.id,
            "projectRoot": root.path,
            "deviceName": deviceInfo.name,
            "docsPath": project.docsPath,
            "ticketID": ticketID,
        ])
    }

    /// Steps 1, 3, 4 and 5 of docs/chats.md › Answer output: the cost is stored, then the answer
    /// is posted, or the comment's state becomes `failed`; a stopped call posts nothing.
    private func finishCommentAnswer(_ answerID: UUID, outcome: CommentAnswerOutcome) async {
        guard !hasStopped, !domain.isStopped, let call = commentAnswers.calls.removeValue(forKey: answerID) else { return }
        let ticket = domain.ticket(call.ticketID)
        if let cost = outcome.costUSD {
            recordCommentAnswerCost(call, title: ticket?.title, costUSD: cost)
        }
        defer { emitProjectsChanged(origin: .system) }
        guard !call.stopper.isStopped, let ticket, ticket.comments.contains(where: { $0.id == call.commentID }) else {
            commentAnswers.states[call.commentID] = nil
            return
        }
        var failure = outcome.failure ?? "the result is empty"
        if let answer = outcome.answer {
            commentAnswers.states[call.commentID] = nil
            do {
                _ = try await ticketsAddComment(TicketsAddComment.Params(ticketID: ticket.id, text: answer),
                                                .claude(chatID: Actor.answerChatID))
                return
            } catch {
                failure = "the answer cannot be posted: \(Engine.message(of: error))"
            }
        }
        log.warn(.claude, "comment answer for \(ticket.id) failed: \(failure)")
        commentAnswers.states[call.commentID] = .failed
        emitTicketUpdated(domain.ticket(ticket.id) ?? ticket, origin: .system)
    }

    /// Appends the cost of a call to `commentAnswers` of its project's project.yml and emits
    /// `project.updated` (docs/costs.md › Comment answers).
    private func recordCommentAnswerCost(_ call: CommentAnswers.Call, title: String?, costUSD: Double) {
        guard var project = domain.project(call.projectID) else { return }
        let lastTitle = title ?? project.commentAnswers.last(where: { $0.ticketID == call.ticketID })?.title ?? ""
        project.commentAnswers.append(CommentAnswerCost(ticketID: call.ticketID, title: lastTitle, costUSD: costUSD, date: ISODate.now()))
        do {
            try saveProject(project)
            emitProjectUpdated(project.id, origin: .system)
        } catch {
            log.error(.storage, "the cost of a comment answer for \(call.ticketID) cannot be written: \(Engine.message(of: error))")
        }
    }
}
