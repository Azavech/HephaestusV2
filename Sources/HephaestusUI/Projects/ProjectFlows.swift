// OWNER: ui-shell — the Open Project and Remove Project flows (docs/projects.md › Opening an
// existing project, › Removing a project).
import AppKit
import Foundation
import HephaestusCore

/// The project flows started from menus, the breadcrumb and the welcome view.
@MainActor
enum ProjectFlows {
    /// Open Project…: an `NSOpenPanel` as a sheet of the window on This Mac, the Choose Folder
    /// sheet (`WindowSheet.openProjectFolder`) on a remote device, then `projects.open`; the
    /// project becomes active in the window.
    static func openProject(window: WindowState, workspace: DeviceWorkspace) {
        guard workspace.isLocal else {
            window.sheet = .openProjectFolder
            return
        }
        let host = window.app?.windowRegistry.window(forMain: window.id)
        Task {
            guard let folder = await ShellPanels.chooseFolder(on: host, prompt: "Open", canCreateDirectories: false,
                                                              message: "Choose a folder that contains .hephaestus/project.yml.",
                                                              directory: defaultParentFolder(window: window, workspace: workspace))
            else { return }
            await open(folder: folder, window: window, workspace: workspace)
        }
    }

    /// The default parent folder of docs/projects.md › Creating a project on This Mac: the folder
    /// that contains the root of the active project's top-level project, else the home folder.
    static func defaultParentFolder(window: WindowState, workspace: DeviceWorkspace) -> String {
        if let active = window.projectID, let top = workspace.topLevelProject(of: active) {
            return ProjectRules.parentFolder(of: top.rootPath)
        }
        return NSHomeDirectory()
    }

    /// `projects.open` with the chosen folder; on success the window activates the returned
    /// project. `notFound` offers `Create Project Here…`; other errors show
    /// `Open Project failed`.
    static func open(folder: String, window: WindowState, workspace: DeviceWorkspace) async {
        do {
            let detail = try await workspace.call(ProjectsOpen.self, ProjectsOpen.Params(rootPath: folder))
            window.activate(projectID: detail.project.id)
        } catch let error as EngineError where error.code == .notFound {
            let host = window.app?.windowRegistry.window(forMain: window.id)
            let create = await ShellPanels.confirm(title: "No project in “\(ProjectRules.lastComponent(of: folder))”",
                                                   message: "The folder has no .hephaestus/project.yml.",
                                                   action: "Create Project Here…", on: host)
            if create {
                window.sheet = .newProjectInFolder(path: folder)
            }
        } catch {
            window.alert = .failure("Open Project", error)
        }
    }

    /// Remove Project…: the unsaved editors check of the project and its descendants, the
    /// confirmation alert, then `projects.remove`.
    static func removeProject(window: WindowState, workspace: DeviceWorkspace) {
        guard let projectID = window.projectID, let project = workspace.project(projectID), let app = window.app else { return }
        let host = app.windowRegistry.window(forMain: window.id)
        Task {
            let descendants = workspace.descendants(of: projectID).map(\.project)
            let removedIDs = Set([projectID] + descendants.map(\.id))
            // 1. The unsaved editors of the project and its sub projects in every window of this app.
            let editors = app.mainWindowsByKeyOrder.flatMap { $0.unsavedEditors(deviceID: workspace.deviceID, projectIDs: removedIDs) }
            guard await UnsavedChangesPrompt.confirm(editors, sheetOn: host) else { return }
            // 2. The confirmation.
            let message = removalMessage(project: project, descendants: descendants, workspace: workspace, removedIDs: removedIDs)
            guard await ShellPanels.confirmDestructive(title: "Remove “\(project.name)” from HephaestusV2?", message: message,
                                                       action: "Remove", on: host) else { return }
            // 3. projects.remove; every window reacts to project.removed.
            do {
                _ = try await workspace.call(ProjectsRemove.self, ProjectsRemove.Params(projectID: projectID))
            } catch {
                window.alert = .failure("Remove Project", error)
            }
        }
    }

    /// `The folder and its files stay on disk: <root path>.`, then the sub projects sentence, then
    /// the running work sentence when the workspace knows running work among the projects.
    static func removalMessage(project: ProjectSummary, descendants: [ProjectSummary], workspace: DeviceWorkspace,
                               removedIDs: Set<String>) -> String {
        var sentences = ["The folder and its files stay on disk: \(project.rootPath)."]
        if descendants.count == 1 {
            sentences.append("Its sub project “\(descendants[0].name)” is removed with it.")
        } else if descendants.count > 1 {
            sentences.append("Its \(descendants.count) sub projects are removed with it.")
        }
        let runningRun = workspace.runs.values.contains { removedIDs.contains($0.info.projectID) && $0.isRunning }
        let runningChat = workspace.chats.values.contains {
            removedIDs.contains($0.projectID) && $0.isWorking
        }
        if runningRun || runningChat {
            sentences.append("Running chats and runs of these projects are stopped.")
        }
        return sentences.joined(separator: " ")
    }
}
