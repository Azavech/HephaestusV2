// OWNER: ui-shell — the Project Settings sheet (docs/projects.md › Project settings).
import HephaestusCore
import SwiftUI

/// Project Settings of the window's active project; Save calls `projects.update` with the changed fields.
// STUB: ui-shell
struct ProjectSettingsSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "ProjectSettingsSheet") { dismiss() }
    }
}
