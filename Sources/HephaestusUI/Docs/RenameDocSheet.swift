// OWNER: ui-code-docs — the Rename sheet of the docs tree (docs/documentation-viewer.md › Rename).
import HephaestusCore
import SwiftUI

/// Rename a doc or a folder of the docs tree.
// STUB: ui-code-docs
struct RenameDocSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let path: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "RenameDocSheet") { dismiss() }
    }
}
