// OWNER: ui-chats — the content of a chat window (docs/ui.md › Windows; docs/chats.md › Chat view).
import HephaestusCore
import SwiftUI

/// The chat view of a chat window, header included; `ChatWindowRoot` adds the status bar, the title and the reconnect view.
// STUB: ui-chats
struct ChatWindowView: View {
    let value: ChatWindowValue
    let workspace: DeviceWorkspace

    var body: some View {
        ChatView(chatID: value.chatID, workspace: workspace)
    }
}
