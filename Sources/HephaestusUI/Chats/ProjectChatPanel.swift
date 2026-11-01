// OWNER: ui-chats — the project chat panel of the inspector (docs/ui.md › Inspector; docs/chats.md › Where chats appear).
import HephaestusCore
import SwiftUI

/// The inspector: the picker of project chats, New Chat, Open in New Window and the selected chat's view or a draft (`ProjectViewState.inspectorChatID`, `inspectorShowsDraft`). It consumes `SectionCommand.focusInspectorComposer`.
// STUB: ui-chats
struct ProjectChatPanel: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "ProjectChatPanel")
    }
}
