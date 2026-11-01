// OWNER: ui-web-search — the sheet of a page's `alert`, `confirm` and `prompt` (docs/web-tabs.md › Page permissions and dialogs).
import HephaestusCore
import SwiftUI

/// A JavaScript dialog of a web tab.
// STUB: ui-web-search
struct WebPageDialogSheet: View {
    let window: WindowState
    let tabID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "WebPageDialogSheet") { dismiss() }
    }
}
