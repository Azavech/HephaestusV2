// OWNER: ui-code-docs — the file tree and its context menu (docs/code-editor.md › File tree).
import HephaestusCore
import SwiftUI

/// The file tree of the active project (`ProjectViewState.expandedCodeFolders`, `selectedTreePath`).
// STUB: ui-code-docs
struct FileTreeView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "FileTreeView")
    }
}
