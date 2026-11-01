// OWNER: ui-code-docs — the selection of a `file` navigation target (docs/ui.md › Resolving a
// target, `file` row; docs/code-editor.md › Opening files).
import Foundation

extension ProjectViewState {
    /// Opens the file in an editor tab or selects its open tab; the cursor goes to the start of
    /// `line`, scrolled to the vertical middle, or to the start of the file without `line`; a
    /// folder path is revealed and selected in the file tree.
    ///
    /// A new tab goes right after the selected tab and is read by the Code section, which the
    /// navigation shows; when the read finds a folder, the tab is replaced by the folder's
    /// selection in the tree (`EditorBuffer`), and a path that does not exist shows
    /// `File <path> was not found.` in the editor area.
    @MainActor
    mutating func revealFile(path: String, line: Int?) {
        let buffer = openEditorTab(path)
        selectedTreePath = path
        buffer.pendingReveal = line.map { .line($0) } ?? .start
    }
}
