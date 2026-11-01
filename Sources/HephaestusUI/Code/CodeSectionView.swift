// OWNER: ui-code-docs — the Code section: file tree, editor tabs and editor (docs/code-editor.md › Layout).
import HephaestusCore
import SwiftUI

/// The Code section of the active project; its tabs are `ProjectViewState.editorTabs`. It sets itself or a controller as `WindowState.sectionCommands`.
// STUB: ui-code-docs
struct CodeSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "CodeSectionView")
    }
}
