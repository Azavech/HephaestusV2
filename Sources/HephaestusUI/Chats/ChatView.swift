// OWNER: ui-chats — the chat view: header, transcript, pinned cards, status line and composer (docs/chats.md › Chat view).
import HephaestusCore
import SwiftUI

/// One chat of a device; `chats.get` loads its transcript into `DeviceWorkspace.transcripts`.
// STUB: ui-chats
struct ChatView: View {
    /// The chat id, an uppercase UUID string.
    let chatID: String
    let workspace: DeviceWorkspace

    var body: some View {
        PlaceholderView(name: "ChatView")
    }
}
