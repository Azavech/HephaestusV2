// OWNER: ui-shell — the project selector rules and WindowState.navigate(to:)
// (docs/projects.md › Project selector; docs/ui.md › Navigation).
import Foundation
import HephaestusCore

extension WindowState {
    /// The workspace of the window's device, once open.
    var workspace: DeviceWorkspace? {
        app?.workspaces[deviceID]
    }

    // MARK: Project selector (docs/projects.md › Project selector)

    /// Activates a project: it becomes `projectID`, its id is stored in `lastProjectByDevice` and in
    /// `AppModel.lastProjectIDByDevice`, and the workspace loads it when needed.
    func activate(projectID: String) {
        self.projectID = projectID
        needsDefaultProject = false
        lastProjectByDevice[deviceID] = projectID
        app?.rememberLastProject(projectID, deviceID: deviceID)
        let key = ProjectKey(deviceID: deviceID, projectID: projectID)
        if projectStates[key] == nil {
            projectStates[key] = ProjectViewState()
        }
        workspace?.ensureProjectLoaded(projectID)
    }

    /// The default project of the window's device: the first project of the device among the
    /// window's `lastProjectByDevice`, `AppModel.lastProjectIDByDevice` and the first top-level
    /// project in `projects.list` order; nil when the device has no project.
    func defaultProjectID(in workspace: DeviceWorkspace) -> String? {
        let remembered = [lastProjectByDevice[deviceID], app?.lastProjectIDByDevice[deviceID]].compactMap { $0 }
        if let projectID = remembered.first(where: { workspace.project($0) != nil }) {
            return projectID
        }
        return workspace.projects.first { $0.parentID == nil }?.id
    }

    /// Checks the active project against the device's projects once they are known: a window
    /// waiting for its default project, a restored project that is not loaded, or an active project
    /// that disappeared gets the nearest remaining ancestor or the default project; with none the
    /// window shows the welcome view.
    func reconcileProject(with workspace: DeviceWorkspace) {
        guard workspace.deviceID == deviceID, workspace.hasSnapshot else { return }
        if let projectID, !needsDefaultProject, workspace.project(projectID) != nil {
            workspace.ensureProjectLoaded(projectID)
            return
        }
        if let projectID, !needsDefaultProject, let ancestor = workspace.nearestRemainingAncestor(of: projectID) {
            activate(projectID: ancestor)
        } else if let projectID = defaultProjectID(in: workspace) {
            activate(projectID: projectID)
        } else {
            projectID = nil
            needsDefaultProject = false
        }
    }

    /// Choosing a device changes only this window: it shows the reconnect view until the device's
    /// workspace is connected, then the device's default project. The section is kept.
    func switchDevice(to newDeviceID: String) {
        guard newDeviceID != deviceID else { return }
        let oldDeviceID = deviceID
        deviceID = newDeviceID
        projectID = nil
        needsDefaultProject = true
        app?.windowDidChangeDevice(self, from: oldDeviceID)
        if let workspace {
            reconcileProject(with: workspace)
        }
    }

    // MARK: Navigation (docs/ui.md › Navigation)

    /// Navigates the window to a target of its device (docs/ui.md › Resolving a target). Returns
    /// once the window's state is updated, or once the target is stored in `pendingTarget`.
    func navigate(to target: NavigationTarget) async {
        // Steps 1 and 2: a disconnected device or a sheet keeps the target for later.
        guard let workspace, workspace.isConnected, workspace.hasSnapshot, sheet == nil else {
            pendingTarget = target
            return
        }
        pendingTarget = nil

        // Step 3: the project.
        let resolvedProjectID: String?
        switch target {
        case .project(let projectID), .doc(let projectID, _, _), .file(let projectID, _, _), .webTab(let projectID, _),
             .section(let projectID, _):
            resolvedProjectID = projectID
        case .ticket(let ticketID):
            resolvedProjectID = Identifiers.projectID(of: ticketID) ?? ticketID
        case .bundle(let bundleID):
            resolvedProjectID = Identifiers.projectID(of: bundleID) ?? bundleID
        case .chat(let chatID):
            // DOC-GAP: docs/ui.md › Resolving a target takes the project of the chat's ChatMeta but
            // does not cover a chat whose metadata the workspace lacks; the active project is
            // used, and the Chats section shows the not-found text.
            resolvedProjectID = workspace.chats[chatID.uuidString]?.projectID ?? projectID ?? defaultProjectID(in: workspace)
        case .skill:
            resolvedProjectID = projectID ?? defaultProjectID(in: workspace)
            guard resolvedProjectID != nil else { return }
        }
        guard let resolvedProjectID, workspace.project(resolvedProjectID) != nil else {
            let name = resolvedProjectID ?? ""
            alert = WindowAlert(title: "Project \(name) was not found on \(workspace.deviceName).", message: "")
            return
        }

        // Step 4: the project and the section.
        if projectID != resolvedProjectID || needsDefaultProject {
            activate(projectID: resolvedProjectID)
        } else {
            workspace.ensureProjectLoaded(resolvedProjectID)
        }
        switch target {
        case .project: break
        case .ticket: section = .tickets
        case .bundle: section = .bundles
        case .chat: section = .chats
        case .doc: section = .docs
        case .file: section = .code
        case .skill: section = .skills
        case .webTab: section = .web
        case .section(_, let targetSection): section = targetSection
        }

        // Step 5: the selection, after the unsaved changes prompt of a doc buffer or a skill form.
        switch target {
        case .project, .section:
            break
        case .ticket(let ticketID):
            let ticket = workspace.tickets[resolvedProjectID]?[ticketID]
            updateViewState {
                $0.selectedTicketIDs = [ticketID]
                $0.ticketList.clearFilters(hiding: ticket)
            }
        case .bundle(let bundleID):
            updateViewState { $0.selectedBundleID = bundleID }
        case .chat(let chatID):
            updateViewState { $0.selectedChatID = chatID.uuidString }
        case .doc(_, let path, let fragment):
            if viewState.selectedDocPath != path {
                if let buffer = viewState.docBuffer, buffer.hasUnsavedChanges {
                    guard await UnsavedChangesPrompt.confirm([buffer], in: self) else { return }
                }
                updateViewState { $0.selectedDocPath = path }
            }
            CodeDocsStore.shared.entry(window: self, projectID: resolvedProjectID).applyDocTarget(path: path, fragment: fragment)
        case .file(_, let path, let line):
            await revealFileTarget(path: path, line: line, projectID: resolvedProjectID)
        case .skill(let name):
            guard viewState.selectedSkillName != name else { return }
            let unsaved = viewState.skillEditor?.unsavedEditors ?? []
            if !unsaved.isEmpty {
                guard await UnsavedChangesPrompt.confirm(unsaved, in: self) else { return }
            }
            updateViewState { $0.selectedSkillName = name }
        case .webTab(_, let tabID):
            WebTabsController.willSelectByNavigation(in: self, projectID: resolvedProjectID)
            updateViewState { $0.selectedWebTabID = tabID.uuidString }
        }
    }

    /// Applies `pendingTarget` once the device is connected and no sheet is shown.
    func applyPendingTarget() {
        guard let target = pendingTarget, sheet == nil, let workspace, workspace.isConnected, workspace.hasSnapshot else { return }
        Task {
            await navigate(to: target)
        }
    }
}
