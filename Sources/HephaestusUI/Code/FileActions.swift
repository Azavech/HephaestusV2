// OWNER: ui-code-docs — actions on project files of the file tree and the editor tabs: closing tabs,
// Move to Trash, renames, Copy Path and Show in Finder (docs/code-editor.md › Context menu, › Move
// to Trash, › Rename, › Closing tabs).
import AppKit
import HephaestusCore

@MainActor
enum FileActions {
    /// The view state of a project of a window.
    static func viewState(_ window: WindowState, _ projectID: String) -> ProjectViewState {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)] ?? ProjectViewState()
    }

    // MARK: Tabs (docs/code-editor.md › Closing tabs)

    /// Closes a tab; a tab with unsaved changes first shows the unsaved changes alert: Save saves
    /// then closes (a failed save keeps the tab open), Don't Save closes, Cancel keeps it.
    static func closeTab(_ buffer: EditorBuffer, window: WindowState, projectID: String) async {
        if buffer.isDirty {
            guard await UnsavedChangesPrompt.confirm([buffer], in: window) else { return }
        }
        window.updateViewState(of: projectID) { $0.removeEditorTab(buffer) }
    }

    /// Close Other Tabs: asks once per tab with unsaved changes, left to right; Cancel stops at
    /// that tab.
    static func closeOtherTabs(keeping buffer: EditorBuffer, window: WindowState, projectID: String) async {
        let others = viewState(window, projectID).editorTabs.map(\.buffer).filter { $0 !== buffer }
        for other in others {
            if other.isDirty {
                guard await UnsavedChangesPrompt.confirm([other], in: window) else { return }
            }
            window.updateViewState(of: projectID) { $0.removeEditorTab(other) }
        }
    }

    /// Opens a file in a tab, or selects its open tab, and reads it when new.
    static func openFile(_ path: String, window: WindowState, workspace: DeviceWorkspace, projectID: String) {
        var buffer: EditorBuffer?
        window.updateViewState(of: projectID) { state in
            buffer = state.openEditorTab(path)
            state.selectedTreePath = path
        }
        buffer?.load(workspace: workspace, projectID: projectID, window: window)
    }

    /// Reveal in File Tree: expands the folders above the file and selects it.
    static func revealInTree(_ path: String, window: WindowState, projectID: String) {
        window.updateViewState(of: projectID) { state in
            state.expandedCodeFolders.formUnion(ProjectPaths.ancestors(of: path))
            state.selectedTreePath = path
        }
    }

    // MARK: Pasteboard and Finder

    /// Copy Path: the project path as plain text.
    static func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    /// Show in Finder: reveals the item; only in windows showing This Mac.
    static func showInFinder(_ path: String, workspace: DeviceWorkspace, projectID: String) {
        guard workspace.isLocal, let root = workspace.project(projectID)?.rootPath else { return }
        let url = path.isEmpty ? URL(fileURLWithPath: root) : URL(fileURLWithPath: root).appendingPathComponent(path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Move to Trash (docs/code-editor.md › Move to Trash)

    /// The tabs of a path and of the files under it.
    static func tabs(under path: String, window: WindowState, projectID: String) -> [EditorBuffer] {
        viewState(window, projectID).editorTabs.map(\.buffer).filter { ProjectPaths.isSameOrDescendant($0.path, of: path) }
    }

    /// Asks, then moves a file or folder to the Trash; the tabs of the trashed files close
    /// without saving.
    static func moveToTrash(_ path: String, isFolder: Bool, window: WindowState, workspace: DeviceWorkspace, projectID: String) async {
        let name = ProjectPaths.name(of: path)
        let affected = tabs(under: path, window: window, projectID: projectID)
        let unsaved = affected.filter(\.isDirty).count
        let alert = NSAlert()
        if isFolder {
            alert.messageText = "Move the folder “\(name)” to the Trash?"
            var text = "Everything in it is moved to the Trash of \(workspace.deviceName)."
            if unsaved > 0 {
                // DOC-GAP: docs/code-editor.md › Move to Trash writes ` Unsaved changes in <n> open
                // files will be lost.`; with one file it reads `1 open file`, as the other counted
                // texts of the docs do.
                text += unsaved == 1 ? " Unsaved changes in 1 open file will be lost." : " Unsaved changes in \(unsaved) open files will be lost."
            }
            alert.informativeText = text
        } else {
            alert.messageText = "Move “\(name)” to the Trash?"
            var text = "It can be restored from the Trash of \(workspace.deviceName)."
            if unsaved > 0 {
                text += " Unsaved changes will be lost."
            }
            alert.informativeText = text
        }
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let nsWindow = window.app?.windowRegistry.window(forMain: window.id)
        guard await AlertPresenter.present(alert, on: nsWindow) == .alertFirstButtonReturn else { return }
        for buffer in affected {
            buffer.holdChecks()
        }
        do {
            _ = try await workspace.call(FilesTrash.self, FilesTrash.Params(projectID: projectID, path: path))
            window.updateViewState(of: projectID) { state in
                for buffer in affected {
                    state.removeEditorTab(buffer)
                }
                if let selected = state.selectedTreePath, ProjectPaths.isSameOrDescendant(selected, of: path) {
                    state.selectedTreePath = nil
                }
            }
        } catch {
            // DOC-GAP: docs/code-editor.md › Move to Trash gives no failure text; the alert of
            // docs/ui.md › Principles names the button pressed, `Move to Trash failed`.
            window.alert = .failure("Move to Trash", error)
        }
        for buffer in affected {
            buffer.releaseChecks()
        }
    }

    // MARK: Renames (docs/code-editor.md › Rename)

    /// Renames or moves an item with `files.rename`; the open tabs of the item and of the files in
    /// it follow the new path with their buffers, unsaved changes included.
    static func rename(_ path: String, to newPath: String, window: WindowState, workspace: DeviceWorkspace, projectID: String) async throws {
        let affected = tabs(under: path, window: window, projectID: projectID)
        for buffer in affected {
            buffer.holdChecks()
        }
        defer {
            for buffer in affected {
                buffer.releaseChecks()
            }
        }
        _ = try await workspace.call(FilesRename.self, FilesRename.Params(projectID: projectID, path: path, newPath: newPath))
        window.updateViewState(of: projectID) { state in
            for index in state.editorTabs.indices {
                if let moved = ProjectPaths.renamed(state.editorTabs[index].path, from: path, to: newPath) {
                    state.editorTabs[index].path = moved
                    state.editorTabs[index].buffer.move(to: moved)
                }
            }
            if let selected = state.selectedEditorPath, let moved = ProjectPaths.renamed(selected, from: path, to: newPath) {
                state.selectedEditorPath = moved
            }
            if let selected = state.selectedTreePath, let moved = ProjectPaths.renamed(selected, from: path, to: newPath) {
                state.selectedTreePath = moved
            }
            state.expandedCodeFolders = Set(state.expandedCodeFolders.map { ProjectPaths.renamed($0, from: path, to: newPath) ?? $0 })
        }
    }
}
