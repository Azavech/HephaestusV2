// OWNER: ui-code-docs — the Rename sheet of the file tree (docs/code-editor.md › Rename).
import HephaestusCore
import SwiftUI

/// Rename or move a file or folder.
// STUB: ui-code-docs
struct RenameFileSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let path: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "RenameFileSheet") { dismiss() }
    }
}
