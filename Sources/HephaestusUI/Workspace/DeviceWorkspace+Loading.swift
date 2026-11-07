// OWNER: ui-shell — the loading rules of docs/ui.md › DeviceWorkspace (Loading) and
// docs/remote.md › After a reconnect.
import Foundation
import HephaestusCore

extension DeviceWorkspace {
    /// Loading steps 1, 2 and 6: the snapshot under the replay rule, then `claude.models` and
    /// `chats.list` for every project; after a reconnection, the loaded projects are seeded again.
    func loadDeviceLevelData(afterReconnect: Bool) async {
        do {
            try await seed({ try await call(SnapshotGet.self) },
                           replace: { applySnapshot($0, afterReconnect: afterReconnect) },
                           replay: { event in var event = event; apply(&event) })
        } catch {
            // The window keeps its loading state until the next connection (docs/ui.md › Empty
            // states).
            return
        }
        // `claude.models` and `chats.list` have no failure state (docs/ui.md › DeviceWorkspace,
        // Loading step 2).
        _ = try? await seed({ try await call(ClaudeModels.self) },
                            replace: { models = $0 },
                            replay: { event in var event = event; apply(&event) })
        for projectID in projects.map(\.id) {
            await loadChats(of: projectID)
        }
        if afterReconnect {
            for projectID in loadedProjectIDs.union(loadingProjectIDs) {
                seededParts[projectID] = []
                loadedProjectIDs.remove(projectID)
                await loadProject(projectID)
            }
        }
    }

    /// Stores a snapshot (docs/ui.md › DeviceWorkspace, Loading steps 1 and 6). A run known as
    /// running and absent from the new snapshot is marked as ended while disconnected.
    func applySnapshot(_ snapshot: Snapshot, afterReconnect: Bool) {
        deviceInfo = snapshot.device
        settings = snapshot.settings
        claudeStatus = snapshot.claude
        planUsage = snapshot.planUsage
        skills = snapshot.skills
        replaceProjects(snapshot.projects)
        let running = Set(snapshot.runs.map(\.runID.uuidString))
        for (id, run) in runs where run.isRunning {
            if running.contains(id) {
                if afterReconnect {
                    runs[id]?.noteMissedOutput()
                }
            } else {
                runs[id]?.markEndedWhileDisconnected()
            }
        }
        for info in snapshot.runs where runs[info.runID.uuidString] == nil {
            runs[info.runID.uuidString] = RunState(info: info, starter: nil, knownFromSnapshotAt: Date())
        }
        hasSnapshot = true
        planUsageStored?()
    }

    /// `chats.list` of one project, under the replay rule: its result replaces the chats of the
    /// project. `chats.listAgents` follows, whose result replaces the workflows and agents of the
    /// project's chats (docs/chats.md › UI state).
    func loadChats(of projectID: String) async {
        _ = try? await seed({ try await call(ChatsList.self, ChatsList.Params(projectID: projectID)) },
                            replace: { list in
                                for chatID in chats.values.filter({ $0.projectID == projectID }).map(\.id.uuidString) {
                                    chats[chatID] = nil
                                }
                                for meta in list {
                                    chats[meta.id.uuidString] = meta
                                }
                            },
                            replay: { event in var event = event; apply(&event) })
        _ = try? await seed({ try await call(ChatsListAgents.self, ChatsListAgents.Params(projectID: projectID)) },
                            replace: { list in
                                for chatID in agents.values.filter({ $0.projectID == projectID }).map(\.chatID.uuidString) {
                                    agents[chatID] = nil
                                }
                                for entry in list {
                                    agents[entry.chatID.uuidString] = entry
                                }
                            },
                            replay: { event in var event = event; apply(&event) })
    }

    // MARK: Projects

    /// Loading step 3: a window shows a project that is not loaded. Runs its seeding calls unless
    /// they are loaded or in flight, or failed (Try Again runs them again).
    func ensureProjectLoaded(_ projectID: String) {
        guard isConnected, project(projectID) != nil, !loadedProjectIDs.contains(projectID),
              !loadingProjectIDs.contains(projectID), projectLoadErrors[projectID] == nil else { return }
        Task { [weak self] in
            await self?.loadProject(projectID)
        }
    }

    /// Loading step 3 for the loaded descendants of a project that a main window shows, so that its
    /// Tickets section lists their tickets (docs/tickets.md › Tickets section). A descendant whose
    /// calls failed stays out until Try Again of its own failure state.
    func ensureDescendantsLoaded(of projectID: String) {
        for descendant in descendants(of: projectID) {
            ensureProjectLoaded(descendant.project.id)
        }
    }

    /// Try Again of the failure state: runs the failed seeding calls again.
    func retryProjectLoad(_ projectID: String) {
        projectLoadErrors[projectID] = nil
        ensureProjectLoaded(projectID)
    }

    /// Runs the seeding calls `projects.get`, `tickets.list`, `bundles.list` and `webTabs.list`
    /// that have not succeeded yet, in parallel; the project counts as loaded when all four have
    /// succeeded.
    func loadProject(_ projectID: String) async {
        guard !loadingProjectIDs.contains(projectID) else { return }
        loadingProjectIDs.insert(projectID)
        projectLoadErrors[projectID] = nil
        let missing = Set(ProjectPart.allCases).subtracting(seededParts[projectID] ?? [])
        var failure: EngineError?
        await withTaskGroup(of: EngineError?.self) { group in
            for part in missing {
                group.addTask { @MainActor [weak self] in
                    do {
                        try await self?.seedPart(part, of: projectID)
                        return nil
                    } catch let error as EngineError {
                        return error
                    } catch {
                        return EngineError(.internal, error.localizedDescription)
                    }
                }
            }
            for await error in group where failure == nil {
                failure = error
            }
        }
        loadingProjectIDs.remove(projectID)
        guard project(projectID) != nil else { return }
        if let failure {
            projectLoadErrors[projectID] = failure
        } else if seededParts[projectID]?.count == ProjectPart.allCases.count {
            loadedProjectIDs.insert(projectID)
        }
    }

    private func seedPart(_ part: ProjectPart, of projectID: String) async throws {
        let replay: (WorkspaceEvent) -> Void = { [weak self] event in
            var event = event
            self?.apply(&event)
        }
        switch part {
        case .detail:
            try await seed({ try await call(ProjectsGet.self, ProjectsGet.Params(projectID: projectID)) },
                           replace: { details[projectID] = $0 }, replay: replay)
        case .tickets:
            try await seed({ try await call(TicketsList.self, TicketsList.Params(projectID: projectID)) },
                           replace: { list in tickets[projectID] = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 }) },
                           replay: replay)
        case .bundles:
            try await seed({ try await call(BundlesList.self, BundlesList.Params(projectID: projectID)) },
                           replace: { list in bundles[projectID] = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 }) },
                           replay: replay)
        case .webTabs:
            try await seed({ try await call(WebTabsList.self, WebTabsList.Params(projectID: projectID)) },
                           replace: { webTabs[projectID] = $0 }, replay: replay)
        }
        seededParts[projectID, default: []].insert(part)
    }
}
