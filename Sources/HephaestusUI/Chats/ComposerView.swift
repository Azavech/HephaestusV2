// OWNER: ui-chats — the composer (docs/chats.md › Composer).
import HephaestusCore
import SwiftUI

/// The composer of a chat, or of a draft chat when `chatID` is nil; unsent text of an existing chat lives in `DeviceWorkspace.drafts`.
// STUB: ui-chats
struct ComposerView: View {
    let chatID: String?
    let workspace: DeviceWorkspace

    var body: some View {
        PlaceholderView(name: "ComposerView")
    }
}
