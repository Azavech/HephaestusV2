// OWNER: ui-code-docs — the selection of a `file` navigation target (docs/ui.md › Resolving a
// target, `file` row; docs/code-editor.md › Opening files).
import Foundation

extension ProjectViewState {
    /// Opens the file in an editor tab or selects its open tab; the cursor goes to the start of
    /// `line`, scrolled to the vertical middle, or to the start of the file without `line`; a
    /// folder path is revealed and selected in the file tree.
    // STUB: ui-code-docs — the folder case, the cursor and the scrolling; a new tab goes right
    // after the selected tab (docs/code-editor.md › Editor tabs).
    @MainActor
    mutating func revealFile(path: String, line: Int?) {
        if !editorTabs.contains(where: { $0.path == path }) {
            editorTabs.append(EditorTabState(path: path))
        }
        selectedEditorPath = path
        selectedTreePath = path
    }
}
