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
        if self.projectID != projectID {
            // docs/builds.md › Visibility: Builds is checked once the new project is loaded.
            buildsCheckPending = true
        }
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
            leaveSubProjectDashboard(ifGoneFrom: workspace)
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

    /// Leaves the Dashboard of a sub project that is no longer a loaded descendant of the active
    /// project: removed, hidden, no longer loaded or moved, or after a restore (docs/ui.md ›
    /// WindowState).
    func leaveSubProjectDashboard(ifGoneFrom workspace: DeviceWorkspace) {
        guard let shown = subProjectDashboardID else { return }
        let isDescendant = projectID.map { projectID in
            workspace.descendants(of: projectID).contains { $0.project.id == shown }
        } ?? false
        if !isDescendant {
            subProjectDashboardID = nil
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

        // An internal skill resolves no project: the window shows the Internal Skills view of its
        // device, keeping its project and section, and leaves a sub project's Dashboard
        // (docs/skills.md › Search and navigation).
        if case .skill(let name) = target, InternalSkills.isInternal(name) {
            await showInternalSkill(name, in: workspace)
            return
        }

        // A virtual machine resolves no project either: the window shows its detail, keeping its
        // project and section (docs/virtual-machines.md › Detail).
        if case .virtualMachine(let vmID) = target {
            await showVirtualMachine(vmID, in: workspace)
            return
        }

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
            // Without the chat's metadata, the active project, else the default one; the Chats
            // section then shows the not-found text (docs/ui.md › Resolving a target).
            resolvedProjectID = workspace.chats[chatID.uuidString]?.projectID ?? projectID ?? defaultProjectID(in: workspace)
        case .skill:
            resolvedProjectID = projectID ?? defaultProjectID(in: workspace)
            guard resolvedProjectID != nil else { return }
        case .virtualMachine:
            return
        }
        guard let resolvedProjectID, workspace.project(resolvedProjectID) != nil else {
            let name = resolvedProjectID ?? ""
            alert = WindowAlert(title: "Project \(name) was not found on \(workspace.deviceName).", message: "")
            return
        }

        // Step 4: the project and the section; every target leaves a sub project's Dashboard.
        subProjectDashboardID = nil
        if projectID != resolvedProjectID || needsDefaultProject {
            activate(projectID: resolvedProjectID)
        } else {
            workspace.ensureProjectLoaded(resolvedProjectID)
        }
        // A chat target shows the chat where it is listed: the Chats tab of its ticket or bundle,
        // or the Chats section (docs/ui.md › Resolving a target).
        var chatPlace = ChatListPlace.chatsSection
        if case .chat(let chatID) = target {
            chatPlace = await ChatNavigator.place(ofChat: chatID.uuidString, in: workspace)
        }
        switch target {
        case .project: break
        case .ticket: section = .tickets
        case .bundle: section = .bundles
        case .chat:
            switch chatPlace {
            case .ticket: section = .tickets
            case .bundle: section = .bundles
            case .chatsSection: section = .chats
            }
        case .doc: section = .docs
        case .file: section = .code
        case .skill: section = .skills
        case .webTab: section = .web
        case .section(_, let targetSection): section = targetSection
        case .virtualMachine: break
        }
        if section == .builds {
            // docs/builds.md › Visibility: Builds gives way to Dashboard for a project without
            // GitHub page, at once when the project is loaded, else once it is.
            buildsCheckPending = true
            reconcileBuildsSection(with: workspace)
        }

        // Step 5: the selection, after the unsaved changes prompt of a doc buffer or a skill form.
        switch target {
        case .project, .section, .virtualMachine:
            break
        case .ticket(let ticketID):
            selectTicket(ticketID, projectID: resolvedProjectID, workspace: workspace)
        case .bundle(let bundleID):
            selectBundle(bundleID, projectID: resolvedProjectID, workspace: workspace)
        case .chat(let chatID):
            switch chatPlace {
            case .ticket(let ticketID):
                // The ticket as by a ticket target, its Chats tab and the chat's view in it.
                let ticketProjectID = Identifiers.projectID(of: ticketID) ?? resolvedProjectID
                selectTicket(ticketID, projectID: ticketProjectID, workspace: workspace)
                updateViewState(of: ticketProjectID) { $0.ticketTab = .chats }
                LinkedChatsView.select(chatID.uuidString, draft: false, owner: .ticket(ticketID), window: self,
                                       projectID: ticketProjectID)
            case .bundle(let bundleID):
                let bundleProjectID = Identifiers.projectID(of: bundleID) ?? resolvedProjectID
                selectBundle(bundleID, projectID: bundleProjectID, workspace: workspace)
                updateViewState(of: bundleProjectID) { $0.bundleTab = .chats }
                LinkedChatsView.select(chatID.uuidString, draft: false, owner: .bundle(bundleID), window: self,
                                       projectID: bundleProjectID)
            case .chatsSection:
                updateViewState {
                    $0.selectedChatIDs = [chatID.uuidString]
                    $0.selectedChatAgent = nil
                }
            }
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

    /// A `virtualMachine` target: the centre column shows the detail of the virtual machine. The
    /// screen of a virtual machine shows only on the Mac that runs it, so the target is ignored in
    /// a window that shows a remote device; it is ignored too when the device has no virtual
    /// machine with this id, once the workspace has read them (docs/ui.md › Resolving a target).
    func showVirtualMachine(_ vmID: UUID, in workspace: DeviceWorkspace) async {
        guard workspace.isLocal else { return }
        if workspace.virtualMachine(vmID) == nil {
            await workspace.loadVirtualMachines()
        }
        guard workspace.deviceID == deviceID, workspace.virtualMachine(vmID) != nil else { return }
        shownVirtualMachineID = vmID
    }

    /// Leaves the detail of a virtual machine that left the workspace's list: deleted, or Claude's
    /// that stopped. The window shows its section again (docs/virtual-machines.md › Detail).
    func leaveVirtualMachineDetail(ifGoneFrom workspace: DeviceWorkspace) {
        guard let shown = shownVirtualMachineID, workspace.deviceID == deviceID, let list = workspace.virtualMachines else { return }
        if !list.machines.contains(where: { $0.id == shown }) {
            shownVirtualMachineID = nil
        }
    }

    /// Selects a ticket in the Tickets section, clearing the list filters that hide it.
    private func selectTicket(_ ticketID: String, projectID: String, workspace: DeviceWorkspace) {
        let ticket = workspace.tickets[projectID]?[ticketID]
        let projectName = workspace.project(projectID)?.name ?? ""
        updateViewState(of: projectID) {
            $0.selectedTicketIDs = [ticketID]
            $0.ticketList.clearFilters(hiding: ticket, projectName: projectName)
        }
    }

    /// Selects a bundle in the Bundles section, turning the done filter off when it hides it.
    private func selectBundle(_ bundleID: String, projectID: String, workspace: DeviceWorkspace) {
        let bundle = workspace.bundles[projectID]?[bundleID]
        updateViewState(of: projectID) {
            $0.selectedBundleID = bundleID
            $0.bundleList.clearFilter(hiding: bundle)
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
