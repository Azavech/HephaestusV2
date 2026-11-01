// OWNER: ui-code-docs — the New Doc sheet (docs/documentation-viewer.md › New Doc).
import HephaestusCore
import SwiftUI

/// New Doc in `folder`.
// STUB: ui-code-docs
struct NewDocSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    /// The folder the sheet was opened for, relative to the project root.
    let folder: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "NewDocSheet") { dismiss() }
    }
}
