// OWNER: ui-code-docs — the selection of a `file` navigation target (docs/ui.md › Resolving a
// target, `file` row; docs/code-editor.md › Opening files).
import Foundation
import HephaestusCore

extension WindowState {
    /// docs/code-editor.md › Opening files, step 1: a path that no tab of the project has is
    /// looked up in its parent folder's listing first. A folder is revealed and selected in the
    /// tree and the editor tabs stay as they are; anything else opens as a file.
    func revealFileTarget(path: String, line: Int?, projectID: String) async {
        let key = ProjectKey(deviceID: deviceID, projectID: projectID)
        let hasTab = projectStates[key]?.editorTabs.contains { $0.path == path } ?? false
        if !hasTab, !path.isEmpty, let workspace {
            let parent = ProjectPaths.parent(of: path)
            let entries = try? await workspace.call(FilesList.self, FilesList.Params(projectID: projectID, path: parent))
            // The window may show another device once the listing is back.
            guard deviceID == key.deviceID else { return }
            if entries?.contains(where: { $0.path == path && $0.isDirectory }) == true {
                updateViewState(of: projectID) { $0.revealFolder(path) }
                return
            }
        }
        updateViewState(of: projectID) { $0.revealFile(path: path, line: line) }
    }
}

extension ProjectViewState {
    /// Opens the file in an editor tab or selects its open tab, with the folders above it expanded
    /// and the file selected in the tree; the cursor goes to the start of `line`, scrolled to the
    /// vertical middle, or to the start of the file without `line`.
    ///
    /// A new tab goes right after the selected tab and is read by the Code section, which the
    /// navigation shows; when the read finds a folder, the tab is replaced by the folder's
    /// selection in the tree and the tab selected before it is selected again (`EditorBuffer`), and
    /// a path that does not exist shows `File <path> was not found.` in the editor area.
    @MainActor
    mutating func revealFile(path: String, line: Int?) {
        let previous = selectedEditorPath
        let isNew = !editorTabs.contains { $0.path == path }
        let buffer = openEditorTab(path)
        if isNew {
            buffer.tabSelectedBeforeOpening = previous
        }
        expandedCodeFolders.formUnion(ProjectPaths.ancestors(of: path))
        selectedTreePath = path
        buffer.pendingReveal = line.map { .line($0) } ?? .start
    }

    /// A folder revealed in the tree: the folders above it expanded, the folder selected.
    mutating func revealFolder(_ path: String) {
        expandedCodeFolders.formUnion(ProjectPaths.ancestors(of: path))
        selectedTreePath = path
    }
}
