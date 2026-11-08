// OWNER: ui-shell — the event handling table of docs/ui.md › Event handling.
import Foundation
import HephaestusCore

extension DeviceWorkspace {
    /// Applies one event to the workspace's data (docs/ui.md › Event handling). An event of a
    /// project that is not loaded changes only device-level data and chat metadata. Window
    /// reactions (selections, chat windows, `ui.open`) belong to `AppModel`, which receives the
    /// event afterwards.
    func apply(_ event: inout WorkspaceEvent) {
        switch event.event {
        case .projectsChanged(let list):
            event.removedChatIDs = replaceProjects(list)
        case .projectUpdated(let detail):
            if details[detail.project.id] != nil {
                details[detail.project.id] = detail
            }
        case .projectRemoved(let payload):
            event.removedChatIDs = dropProjects([payload.projectID])
            projects.removeAll { $0.id == payload.projectID }
        case .ticketUpdated(let ticket):
            if let projectID = ticket.projectID, tickets[projectID] != nil {
                tickets[projectID]?[ticket.id] = ticket
            }
        case .ticketDeleted(let payload):
            tickets[payload.projectID]?[payload.ticketID] = nil
        case .bundleUpdated(let bundle):
            if let projectID = bundle.projectID, bundles[projectID] != nil {
                bundles[projectID]?[bundle.id] = bundle
            }
        case .bundleDeleted(let payload):
            bundles[payload.projectID]?[payload.bundleID] = nil
        case .chatUpdated(let meta):
            chats[meta.id.uuidString] = meta
        case .chatDeleted(let payload):
            chats[payload.chatID.uuidString] = nil
            transcripts[payload.chatID.uuidString] = nil
            drafts[payload.chatID.uuidString] = nil
            dropAgents(of: payload.chatID.uuidString)
        case .chatItem(let payload):
            transcripts[payload.chatID.uuidString]?.upsert(payload.item)
        case .chatDelta(let payload):
            transcripts[payload.chatID.uuidString]?.append(payload)
        case .chatAgents(let payload):
            agents[payload.chatID.uuidString] = payload.isEmpty ? nil : payload
        case .chatAgentItem(let payload):
            agentTranscripts[DeviceWorkspace.agentKey(chatID: payload.chatID.uuidString, agentID: payload.agentID)]?.upsert(payload.item)
        case .filesChanged:
            // Passed to the open editors, file trees and doc lists through `events()`.
            break
        case .webTabsUpdated(let payload):
            if webTabs[payload.projectID] != nil {
                webTabs[payload.projectID] = payload.tabs
            }
        case .skillsChanged(let list):
            skills = list
        case .memoriesChanged(let folder):
            if memoryFolders[folder.projectID] != nil {
                memoryFolders[folder.projectID] = folder
            }
        case .runStarted(let info):
            let id = info.runID.uuidString
            if runs[id] == nil {
                runs[id] = RunState(info: info, starter: event.origin)
                forgetOldRuns(of: info.projectID)
            }
        case .runOutput(let payload):
            runs[payload.runID.uuidString]?.append(payload.text)
        case .runFinished(let payload):
            runs[payload.runID.uuidString]?.finish(exitCode: payload.exitCode)
        case .settingsUpdated(let newSettings):
            settings = newSettings
        case .claudeUpdated(let payload):
            claudeStatus = payload.status
            models = payload.models
        case .planUsageUpdated(let usage):
            planUsage = usage
            planUsageStored?()
        case .uiOpen, .chatNotification, .unknown:
            // `ui.open` is routed and `chat.notification` posted by AppModel (docs/ui.md ›
            // Choosing the window, › Status bar); unknown events are handled by the document that
            // defines them.
            break
        }
    }

    /// `projects.changed` and the snapshot: replaces `projects`; a project that disappeared is
    /// dropped with its loaded data, its chats and its runs; a new project gets its `chats.list`
    /// call. Returns the ids of the dropped chats.
    @discardableResult
    func replaceProjects(_ list: [ProjectSummary]) -> [String] {
        let oldIDs = Set(projects.map(\.id))
        let newIDs = Set(list.map(\.id))
        for summary in list {
            if let parentID = summary.parentID {
                knownParents[summary.id] = parentID
            }
        }
        projects = list
        let removed = dropProjects(oldIDs.subtracting(newIDs))
        if hasSnapshot {
            for projectID in list.map(\.id) where !oldIDs.contains(projectID) {
                Task { [weak self] in
                    await self?.loadChats(of: projectID)
                }
            }
        }
        return removed
    }

    /// Drops projects with their loaded data, chats, transcripts, drafts and runs; returns the ids
    /// of the dropped chats.
    @discardableResult
    func dropProjects(_ projectIDs: Set<String>) -> [String] {
        guard !projectIDs.isEmpty else { return [] }
        for projectID in projectIDs {
            details[projectID] = nil
            tickets[projectID] = nil
            bundles[projectID] = nil
            webTabs[projectID] = nil
            memoryFolders[projectID] = nil
            loadedProjectIDs.remove(projectID)
            loadingProjectIDs.remove(projectID)
            projectLoadErrors[projectID] = nil
            seededParts[projectID] = nil
        }
        let chatIDs = chats.values.filter { projectIDs.contains($0.projectID) }.map(\.id.uuidString)
        for chatID in chatIDs {
            chats[chatID] = nil
            transcripts[chatID] = nil
            drafts[chatID] = nil
            dropAgents(of: chatID)
        }
        runs = runs.filter { !projectIDs.contains($0.value.info.projectID) }
        return chatIDs
    }

    /// The workspace keeps the 20 newest runs of each project; older finished runs are forgotten
    /// (docs/projects.md › Console).
    func forgetOldRuns(of projectID: String) {
        let projectRuns = runs(of: projectID)
        guard projectRuns.count > 20 else { return }
        for run in projectRuns.dropFirst(20) where !run.isRunning {
            runs[run.info.runID.uuidString] = nil
        }
    }

    /// The nearest ancestor of a removed project that is still a project of the device.
    func nearestRemainingAncestor(of projectID: String) -> String? {
        var parentID = knownParents[projectID]
        while let current = parentID {
            if project(current) != nil { return current }
            parentID = knownParents[current]
        }
        return nil
    }
}
