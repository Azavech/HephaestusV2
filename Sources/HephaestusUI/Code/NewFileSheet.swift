// OWNER: ui-code-docs — the New File and New Folder sheets of the file tree (docs/code-editor.md › New File and New Folder).
import HephaestusCore
import SwiftUI

/// New File or New Folder in `folder`.
// STUB: ui-code-docs
struct NewFileSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    /// The location, a project path; `/` for the root.
    let folder: String
    let isFolder: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "NewFileSheet") { dismiss() }
    }
}
