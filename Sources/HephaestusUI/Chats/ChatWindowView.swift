// OWNER: ui-chats — the content of a chat window (docs/ui.md › Windows; docs/chats.md › Chat view).
import HephaestusCore
import SwiftUI

/// The chat view of a chat window, header included; `ChatWindowRoot` adds the status bar, the title and the reconnect view.
/// The window shows one chat of one device; Open in New Window is hidden in it, and closing it
/// does not stop Claude.
struct ChatWindowView: View {
    let value: ChatWindowValue
    let workspace: DeviceWorkspace

    var body: some View {
        ChatView(chatID: value.chatID, workspace: workspace, isInChatWindow: true)
    }
}
