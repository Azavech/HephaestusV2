import Foundation

/// docs/chats.md › Agents: the workflows and agents of the chats. The engine reads each chat's
/// agents file once, applies the task lines and the items of the chat's Claude process to the
/// chat's `ChatAgentTracker`, appends what changed and emits `chat.agents`, follows the folders of
/// running workflows, stores the transcripts of their agents, and stops a workflow on request.
extension Engine {
    // MARK: Records

    /// The chat's workflows and agents, read from its agents file the first time
    /// (docs/chats.md › Storage of agents).
    func agentTracker(_ chatID: ChatID) -> ChatAgentTracker {
        if let tracker = chats.agentTrackers[chatID] { return tracker }
        var tracker = ChatAgentTracker()
        if let meta = domain.chat(chatID), let folder = try? chatFolder(meta) {
            do {
                tracker = ChatAgentTracker(loaded: try ChatAgentsReplay.replay(fileAt: folder.chatAgentsFile(chatID), log: log))
            } catch {
                log.error(.claude, "chat \(chatID.uuidString): the agents file cannot be read: \(error)")
            }
        }
        chats.agentTrackers[chatID] = tracker
        return tracker
    }

    /// The chat's workflows and agents as the API gives them.
    func chatAgents(_ chatID: ChatID, projectID: ProjectID) -> ChatAgents {
        let tracker = agentTracker(chatID)
        return ChatAgents(chatID: chatID, projectID: projectID, workflows: tracker.workflows, agents: tracker.agents)
    }

    /// Runs one step of the chat's tracker and saves what it changed.
    @discardableResult
    private func updateAgents<T>(_ chatID: ChatID, _ step: (inout ChatAgentTracker) -> T,
                                 changes: (T) -> ChatAgentTracker.Changes) -> T {
        var tracker = agentTracker(chatID)
        let result = step(&tracker)
        chats.agentTrackers[chatID] = tracker
        saveAgentChanges(changes(result), chatID: chatID)
        return result
    }

    /// Appends the changed records to the chat's agents file, then emits `chat.agents` with the
    /// chat's complete workflows and agents.
    private func saveAgentChanges(_ changes: ChatAgentTracker.Changes, chatID: ChatID) {
        guard !changes.isEmpty, !chats.deleting.contains(chatID), let meta = domain.chat(chatID), let folder = try? chatFolder(meta) else {
            return
        }
        let url = folder.chatAgentsFile(chatID)
        do {
            for workflow in changes.workflows {
                try chats.transcripts.append(ChatAgentsLine(workflow: workflow), to: url)
            }
            for agent in changes.agents {
                try chats.transcripts.append(ChatAgentsLine(agent: agent), to: url)
            }
        } catch {
            log.error(.claude, "chat \(chatID.uuidString): the agents file cannot be written: \(error)")
        }
        emit(ChatAgentsEvent.self, chatAgents(chatID, projectID: meta.projectID), origin: .system)
    }

    /// Appends items to a workflow agent's transcript file and emits each as `chat.agentItem`.
    private func addWorkflowAgentItems(_ items: [ChatItem], agentID: String, chatID: ChatID) {
        guard !chats.deleting.contains(chatID), let meta = domain.chat(chatID), let folder = try? chatFolder(meta),
              ChatAgent.isWorkflowAgentID(agentID)
        else { return }
        let url = folder.agentTranscriptFile(chatID: chatID, agentID: agentID)
        for item in items {
            do {
                try chats.transcripts.append(TranscriptLine(op: .add, item: item), to: url)
            } catch {
                log.error(.claude, "chat \(chatID.uuidString): an item of agent \(agentID) cannot be written: \(error)")
                continue
            }
            emit(ChatAgentItemEvent.self, .init(chatID: chatID, agentID: agentID, item: item), origin: .system)
        }
    }

    // MARK: Claude output

    /// An item added to the chat's transcript (docs/chats.md › Workflows and agents, › Sub-agent
    /// transcripts). Until a chat has started a workflow or a sub-agent, only such a call is read.
    func trackAgentItem(_ item: ChatItem, chatID: ChatID) {
        if chats.agentTrackers[chatID] == nil {
            guard case .toolUse(let toolUse) = item, toolUse.server == nil,
                  ChatAgentTracker.agentTools.contains(toolUse.name) || toolUse.name == ChatAgentTracker.workflowTool
            else { return }
        }
        let effects = updateAgents(chatID, { $0.itemAdded(item) }, changes: \.changes)
        for (agentID, item) in effects.agentItems {
            emit(ChatAgentItemEvent.self, .init(chatID: chatID, agentID: agentID, item: item), origin: .system)
        }
        if let follow = effects.follow {
            followWorkflowFolder(chatID, workflowID: follow.workflowID, path: follow.folder)
        }
    }

    /// `system/task_started`: a workflow starts, a sub-agent gets its task id or is resumed.
    func agentTaskStarted(_ start: TaskStart, chatID: ChatID) {
        guard start.taskType == "local_workflow" || start.taskType == "local_agent" else { return }
        let effects = updateAgents(chatID, { $0.taskStarted(start, now: ISODate.now()) }, changes: \.changes)
        if let follow = effects.follow {
            followWorkflowFolder(chatID, workflowID: follow.workflowID, path: follow.folder)
        }
    }

    /// `system/task_progress`: a workflow's summary and agents.
    func agentTaskProgress(_ progress: TaskProgress, chatID: ChatID) {
        guard chats.agentTrackers[chatID] != nil else { return }
        updateAgents(chatID, { $0.taskProgress(progress, now: ISODate.now()) }, changes: { $0 })
    }

    /// `system/task_updated`: a workflow may end.
    func agentTaskUpdated(_ taskID: String, status: String?, chatID: ChatID) {
        guard chats.agentTrackers[chatID] != nil else { return }
        let (_, ended) = updateAgents(chatID, { $0.taskUpdated(taskID, status: status, now: ISODate.now()) }, changes: \.0)
        if let ended { workflowEnded(chatID, workflowID: ended) }
    }

    /// `system/task_notification`: a workflow or a sub-agent may end.
    func agentTaskNotification(_ taskID: String, toolUseID: String?, status: String?, chatID: ChatID) {
        guard chats.agentTrackers[chatID] != nil else { return }
        let (_, ended) = updateAgents(chatID, {
            $0.taskNotification(taskID, toolUseID: toolUseID, status: status, now: ISODate.now())
        }, changes: \.0)
        if let ended { workflowEnded(chatID, workflowID: ended) }
    }

    /// A `result` line: the sub-agents of the turn that still run stop.
    func agentTurnEnded(_ chatID: ChatID) {
        guard chats.agentTrackers[chatID] != nil else { return }
        updateAgents(chatID, { $0.turnEnded(now: ISODate.now()) }, changes: { $0 })
    }

    /// The chat's process exited: its running workflows and agents stop; the followed folders are
    /// read a last time first.
    func agentProcessExited(_ chatID: ChatID) {
        guard chats.agentTrackers[chatID] != nil else { return }
        let follows = chats.workflowFollows[chatID] ?? [:]
        updateAgents(chatID, { $0.processExited(now: ISODate.now(), followed: Set(follows.keys)) }, changes: { $0 })
        for follow in follows.values {
            follow.ended = true
            follow.task?.cancel()
        }
    }

    /// `chats.delete`: the chat's folders are no longer followed and its records are forgotten.
    func forgetAgents(_ chatID: ChatID) {
        for follow in (chats.workflowFollows.removeValue(forKey: chatID) ?? [:]).values {
            follow.ended = true
            follow.task?.cancel()
        }
        chats.agentTrackers[chatID] = nil
    }

    // MARK: Workflow folders

    /// docs/chats.md › Workflow folder: reads the folder now, then every interval while the
    /// workflow runs, and a last time once it has ended; then its agents that still run stop.
    private func followWorkflowFolder(_ chatID: ChatID, workflowID: String, path: String) {
        guard chats.workflowFollows[chatID]?[workflowID] == nil, agentTracker(chatID).workflow(workflowID)?.state == .running else { return }
        let follow = WorkflowFollow(reader: WorkflowFolderReader(folder: URL(fileURLWithPath: path, isDirectory: true)))
        chats.workflowFollows[chatID, default: [:]][workflowID] = follow
        let interval = chats.timings.workflowFolderInterval
        follow.task = Task {
            while true {
                let last = follow.ended
                await self.readWorkflowFolder(chatID, workflowID: workflowID, follow: follow)
                if last { break }
                // A cancelled task ends its sleep at once: the workflow has ended.
                try? await Task.sleep(for: interval)
            }
            self.workflowFollowFinished(chatID, workflowID: workflowID, follow: follow)
        }
    }

    /// One read of the folder, in a child task; its records and items are saved on the engine.
    private func readWorkflowFolder(_ chatID: ChatID, workflowID: String, follow: WorkflowFollow) async {
        guard chats.workflowFollows[chatID]?[workflowID] === follow, !chats.deleting.contains(chatID) else { return }
        let known = agentTracker(chatID).agentIDs(of: workflowID)
        let reader = follow.reader
        let now = ISODate.now()
        let batch = await Task.detached { reader.read(knownAgentIDs: known, now: now) }.value
        guard chats.workflowFollows[chatID]?[workflowID] === follow, !chats.deleting.contains(chatID) else { return }
        updateAgents(chatID, { $0.folderRead(batch, workflowID: workflowID, now: now) }, changes: { $0 })
        for (agentID, items) in batch.items {
            addWorkflowAgentItems(items, agentID: agentID, chatID: chatID)
        }
    }

    private func workflowFollowFinished(_ chatID: ChatID, workflowID: String, follow: WorkflowFollow) {
        guard chats.workflowFollows[chatID]?[workflowID] === follow else { return }
        chats.workflowFollows[chatID]?[workflowID] = nil
        guard !chats.deleting.contains(chatID) else { return }
        updateAgents(chatID, { $0.stopRemainingAgents(of: workflowID, now: ISODate.now()) }, changes: { $0 })
    }

    /// A workflow ended: the last read of its folder comes before its remaining agents stop.
    private func workflowEnded(_ chatID: ChatID, workflowID: String) {
        if let follow = chats.workflowFollows[chatID]?[workflowID] {
            follow.ended = true
            follow.task?.cancel()
        } else {
            updateAgents(chatID, { $0.stopRemainingAgents(of: workflowID, now: ISODate.now()) }, changes: { $0 })
        }
    }

    // MARK: Stop Workflow

    /// `chats.stopWorkflow` (docs/chats.md › Stopping a workflow): the `stop_task` request to the
    /// chat's live process; its task's end then starts no notification turn.
    func stopWorkflow(_ chatID: ChatID, workflowID: String) throws {
        let tracker = agentTracker(chatID)
        guard let workflow = tracker.workflow(workflowID) else { throw EngineError.notFound("Workflow", workflowID) }
        guard workflow.state == .running, let process = chats.runtimes[chatID]?.liveProcess, !process.handle.hasExited else {
            throw EngineError(.conflict, "This workflow is not running.")
        }
        process.background.taskStopped(workflowID)
        sendControlRequest(.stopWorkflow(workflowID), chatID: chatID, process: process) { ControlLines.stopTask(id: $0, taskID: workflowID) }
    }

    /// An error answer to `stop_task`, or none within 30 s: the warning item, and the workflow's
    /// end may start a notification turn again.
    func workflowStopRefused(_ workflowID: String, description: String, chatID: ChatID, process: ChatProcess) {
        process.background.taskStopped(workflowID, false)
        var description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        while description.hasSuffix(".") { description.removeLast() }
        let summary = agentTracker(chatID).workflow(workflowID)?.summary ?? workflowID
        addSystemItem("The workflow “\(summary)” was not stopped: \(description).", level: .warning, chatID: chatID)
    }

    // MARK: Transcripts

    /// `chats.agentTranscript`: a workflow agent's transcript file, or a sub-agent's items of the
    /// chat's transcript (docs/chats.md › Agent transcript lines, › Sub-agent transcripts).
    func agentTranscript(_ chatID: ChatID, agentID: String) throws -> [ChatItem] {
        let meta = try requireChat(chatID)
        guard let agent = agentTracker(chatID).agent(agentID) else { throw EngineError.notFound("Agent", agentID) }
        switch agent.kind {
        case .workflow:
            let url = try chatFolder(meta).agentTranscriptFile(chatID: chatID, agentID: agent.id)
            do {
                return try TranscriptReplay.replay(fileAt: url, log: log)
            } catch let error as StorageError {
                throw EngineError.storage(error)
            }
        case .subagent:
            return ChatAgentTracker.subAgentTranscript(callID: agent.id, items: try loadTranscript(chatID))
        }
    }
}
