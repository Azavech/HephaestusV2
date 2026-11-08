// OWNER: ui-memories — selecting rows, Move to Trash and the paths of the Memories section
// (docs/memories.md › Saving, › Move to Trash, › Remote windows).
import AppKit
import HephaestusCore
import SwiftUI

/// The actions of the Memories section that outlive a view: selection with the unsaved changes
/// prompt, the Move to Trash confirmation and the paths shown.
@MainActor
enum MemoryActions {
    /// The index file of a memory folder, also the tag of its row.
    static let indexFileName = "MEMORY.md"

    /// The file name without `.md`.
    static func stem(of file: String) -> String {
        file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    }

    /// Selects a row of a project's Memories section in a window, or clears the selection with
    /// nil. When the shown memory or `MEMORY.md` has unsaved changes,
    /// `Do you want to save the changes to “<name>”?` asks first; Cancel keeps the current
    /// selection and returns false (docs/memories.md › Saving). `startEditing` opens the memory's
    /// body in Edit mode with the keyboard focus (New Memory sheet).
    @discardableResult
    static func select(_ file: String?, window: WindowState, workspace: DeviceWorkspace, projectID: String,
                       startEditing: Bool = false) async -> Bool {
        let key = ProjectKey(deviceID: workspace.deviceID, projectID: projectID)
        let current = window.projectStates[key]
        if current?.selectedMemoryFile == file, !startEditing { return true }
        if let editor = current?.memoryEditor, editor.selection != file {
            let unsaved = editor.unsavedEditors
            if !unsaved.isEmpty {
                guard await UnsavedChangesPrompt.confirm(unsaved, in: window) else { return false }
            }
        }
        var state = window.projectStates[key] ?? ProjectViewState()
        state.selectedMemoryFile = file
        if startEditing {
            state.memoryBodyMode = .edit
        }
        if let file {
            if startEditing || state.memoryEditor?.selection != file {
                let editor = MemoryEditorState(target: target(of: file), projectID: projectID, bodyMode: state.memoryBodyMode)
                editor.attach(window: window, workspace: workspace)
                if startEditing {
                    editor.bodyFocusRequest += 1
                }
                state.memoryEditor = editor
                Task {
                    await editor.refresh()
                }
            }
        } else {
            state.memoryEditor = nil
        }
        window.projectStates[key] = state
        return true
    }

    /// `+` and `New Memory…`: when the shown memory or `MEMORY.md` has unsaved changes, its prompt
    /// asks first, so that Save writes it before Create changes `MEMORY.md`; Cancel opens no
    /// sheet (docs/memories.md › New Memory sheet).
    static func openNewMemorySheet(window: WindowState, workspace: DeviceWorkspace, projectID: String) async {
        let key = ProjectKey(deviceID: workspace.deviceID, projectID: projectID)
        if let editor = window.projectStates[key]?.memoryEditor, !editor.unsavedEditors.isEmpty {
            guard await UnsavedChangesPrompt.confirm(editor.unsavedEditors, in: window) else { return }
            if editor.hasUnsavedChanges {
                editor.discardChanges()
            }
        }
        window.sheet = .newMemory(projectID: projectID)
    }

    /// The tag and the selection of an inherited memory's row: `<ancestor id>/<file name>`; a file
    /// name holds no `/` (docs/memories.md › Memories section).
    static func inheritedTag(projectID: String, file: String) -> String {
        projectID + "/" + file
    }

    /// The editor target of a selected row: `MEMORY.md`, an inherited memory or a memory of the
    /// project's own folder.
    static func target(of selection: String) -> MemoryEditorState.Target {
        if selection == indexFileName { return .index }
        if let slash = selection.firstIndex(of: "/") {
            return .inherited(projectID: String(selection[..<slash]), file: String(selection[selection.index(after: slash)...]))
        }
        return .memory(file: selection)
    }

    /// True for an inherited memory whose folder the listed project no longer inherits: it shows
    /// `Memory <name> was not found.` (docs/memories.md › Saving).
    static func isNoLongerInherited(_ target: MemoryEditorState.Target, in folder: MemoryFolder?) -> Bool {
        guard case .inherited(let ancestorID, _) = target, let folder else { return false }
        return !folder.inherited.contains { $0.projectID == ancestorID }
    }

    /// The memory of the project's own folder that a selection names, for `−`, ⌫ and ⌘⌫; nil for
    /// `MEMORY.md`, an inherited memory or no selection (docs/memories.md › List).
    static func ownMemoryFile(of selection: String?) -> String? {
        guard let selection, case .memory(let file) = target(of: selection) else { return nil }
        return file
    }

    /// Move to Trash of a memory: the alert `Move “<name>” to the Trash?`, then `memories.delete`;
    /// the memory's selection is cleared in this window (docs/memories.md › Move to Trash).
    static func trashMemory(_ file: String, window: WindowState, workspace: DeviceWorkspace, projectID: String) async {
        let name = workspace.memoryFolders[projectID]?.memories.first { $0.file == file }?.name ?? stem(of: file)
        let alert = NSAlert()
        alert.messageText = "Move “\(name)” to the Trash?"
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let response = await AlertPresenter.present(alert, on: window.app?.windowRegistry.window(forMain: window.id))
        guard response == .alertFirstButtonReturn else { return }
        do {
            _ = try await workspace.call(MemoriesDelete.self, .init(projectID: projectID, file: file))
        } catch {
            window.alert = .failure("Move to Trash", error)
            return
        }
        let key = ProjectKey(deviceID: workspace.deviceID, projectID: projectID)
        guard var state = window.projectStates[key], state.selectedMemoryFile == file else { return }
        state.selectedMemoryFile = nil
        state.memoryEditor = nil
        window.projectStates[key] = state
    }

    /// The selected item of the feedback context: the selected memory's name, or `MEMORY.md`
    /// (docs/feedback.md › Feedback context).
    static func selectedItemName(of view: ProjectViewState, in workspace: DeviceWorkspace, projectID: String) -> String? {
        guard let selection = view.selectedMemoryFile else { return nil }
        let folder = workspace.memoryFolders[projectID]
        let listed: MemorySummary?
        let file: String
        switch target(of: selection) {
        case .index:
            return indexFileName
        case .memory(let name):
            file = name
            listed = folder?.memories.first { $0.file == name }
        case .inherited(let ancestorID, let name):
            file = name
            listed = folder?.inherited.first { $0.projectID == ancestorID }?.memories.first { $0.file == name }
        }
        if let listed {
            return listed.name
        }
        if let editor = view.memoryEditor, editor.selection == selection, editor.hasLoaded {
            return editor.form.savedName
        }
        return stem(of: file)
    }

    // MARK: Paths (docs/memories.md › Remote windows)

    /// A path of the main device with its home folder written `~`: This Mac's home folder in a
    /// local window; in a remote window, whose snapshot carries no home folder, a path under
    /// `/Users/<name>`.
    static func displayPath(_ path: String, in workspace: DeviceWorkspace) -> String {
        displayPath(path, isLocal: workspace.isLocal, home: NSHomeDirectory())
    }

    /// `displayPath(_:in:)` with the window's device and This Mac's home folder given.
    nonisolated static func displayPath(_ path: String, isLocal: Bool, home: String) -> String {
        if isLocal {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
            return path
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if path.hasPrefix("/"), components.count >= 2, components[0] == "Users" {
            return (["~"] + components.dropFirst(2).map(String.init)).joined(separator: "/")
        }
        return path
    }

    /// The file an editor target shows: the memory's file name, or `MEMORY.md`.
    static func fileName(of target: MemoryEditorState.Target) -> String {
        switch target {
        case .memory(let file), .inherited(_, let file): return file
        case .index: return indexFileName
        }
    }

    /// The folder that holds what a target shows: the project's own memory folder, or the
    /// inherited folder of the memory's ancestor; nil while it is not listed.
    static func folderPath(of target: MemoryEditorState.Target, in workspace: DeviceWorkspace, projectID: String) -> String? {
        guard let folder = workspace.memoryFolders[projectID] else { return nil }
        if case .inherited(let ancestorID, _) = target {
            return folder.inherited.first { $0.projectID == ancestorID }?.path
        }
        return folder.path
    }

    /// The path of the file a target shows, home folder written `~`.
    static func displayPath(of target: MemoryEditorState.Target, in workspace: DeviceWorkspace, projectID: String) -> String {
        let file = fileName(of: target)
        guard let folder = folderPath(of: target, in: workspace, projectID: projectID) else { return file }
        return displayPath((folder as NSString).appendingPathComponent(file), in: workspace)
    }

    /// Reveal in Finder of the file a target shows, on This Mac only.
    static func reveal(_ target: MemoryEditorState.Target, in workspace: DeviceWorkspace, projectID: String) {
        guard workspace.isLocal, let folder = folderPath(of: target, in: workspace, projectID: projectID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder).appendingPathComponent(fileName(of: target))])
    }
}
