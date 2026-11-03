// OWNER: ui-shell — the window actions behind the toolbar and the Project menu: Run, Build, Test,
// Stop, New Chat, the inspector and the search panel (docs/ui.md › Toolbar; docs/projects.md › Run
// commands).
import Foundation
import HephaestusCore

extension RunKind {
    /// `Run`, `Build` or `Test`.
    var title: String {
        switch self {
        case .run: return "Run"
        case .build: return "Build"
        case .test: return "Test"
        }
    }
}

extension WindowState {
    /// True when the window's device is connected.
    var isConnected: Bool {
        workspace?.isConnected ?? false
    }

    /// The active project on a connected device (the **project** condition of docs/ui.md › Menus
    /// and keyboard shortcuts).
    var hasActiveProject: Bool {
        isConnected && projectID != nil
    }

    /// The commands of the active project, once its detail is loaded.
    var projectCommands: ProjectCommands? {
        guard let projectID else { return nil }
        return workspace?.details[projectID]?.project.commands
    }

    func command(_ kind: RunKind) -> String? {
        guard let commands = projectCommands else { return nil }
        let command: String?
        switch kind {
        case .run: command = commands.run
        case .build: command = commands.build
        case .test: command = commands.test
        }
        return command?.isEmpty == false ? command : nil
    }

    /// The running runs of the active project.
    var runningRuns: [RunState] {
        guard let projectID else { return [] }
        return workspace?.runs(of: projectID).filter(\.isRunning) ?? []
    }

    /// The running runs of the active project in its root; the runs of orchestrated ticket chats
    /// in their worktrees are left out (docs/projects.md › Run commands).
    var rootRunningRuns: [RunState] {
        runningRuns.filter { $0.info.worktree == nil }
    }

    /// Run, Build or Test: `projects.run` with `wait` false, then the console drawer of this window
    /// shows the new run. When a run of the same kind is running in the project root, it is
    /// stopped first and the new run starts after its `run.finished`; a run in a worktree keeps
    /// running (docs/projects.md › Run commands).
    func startRun(_ kind: RunKind) {
        guard let projectID, let workspace, command(kind) != nil else { return }
        Task {
            do {
                if let previous = rootRunningRuns.first(where: { $0.info.kind == kind }) {
                    let events = workspace.events()
                    _ = try await workspace.call(ProjectsStopRun.self, ProjectsStopRun.Params(runID: previous.info.runID))
                    if workspace.runs[previous.id]?.isRunning == true {
                        for await event in events {
                            if case .runFinished(let payload) = event.event, payload.runID == previous.info.runID { break }
                        }
                    }
                }
                let result = try await workspace.call(ProjectsRun.self, ProjectsRun.Params(projectID: projectID, kind: kind, wait: false))
                consoleVisible = true
                updateViewState(of: projectID) { $0.consoleRunID = result.run.runID.uuidString }
            } catch {
                alert = .failure(kind.title, error)
            }
        }
    }

    /// Stop (⌘.): `projects.stopRun` for every running run of the active project in its root.
    func stopRuns() {
        guard let workspace else { return }
        let runs = rootRunningRuns
        Task {
            for run in runs {
                do {
                    _ = try await workspace.call(ProjectsStopRun.self, ProjectsStopRun.Params(runID: run.info.runID))
                } catch {
                    alert = .failure("Stop", error)
                }
            }
        }
    }

    /// New Chat: shows the inspector, a new draft chat in it and the focus in its composer
    /// (docs/ui.md › Inspector).
    func newChat() {
        guard projectID != nil else { return }
        inspectorVisible = true
        updateViewState { $0.inspectorShowsDraft = true }
        pendingSectionCommand = .focusInspectorComposer
    }

    /// Search (⇧⌘F): opens the search panel, or closes it when it is open.
    func toggleSearch() {
        searchVisible.toggle()
    }
}
