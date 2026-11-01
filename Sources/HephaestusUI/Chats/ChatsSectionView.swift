// OWNER: ui-chats — the Chats section (docs/chats.md › Where chats appear).
import HephaestusCore
import SwiftUI

/// The chats of the active project grouped by kind, and the selected chat's view (`ProjectViewState.selectedChatID`).
// STUB: ui-chats
struct ChatsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "ChatsSectionView")
    }
}
