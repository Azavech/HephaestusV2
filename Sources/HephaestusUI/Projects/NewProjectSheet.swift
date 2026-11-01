// OWNER: ui-shell — the New Project and New Sub Project sheets (docs/projects.md › Creating a project, › Sub projects).
import HephaestusCore
import SwiftUI

/// The New Project sheet, or the New Sub Project sheet when `parentID` is set; Create calls `projects.create`.
// STUB: ui-shell
struct NewProjectSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    /// The parent preselected by New Sub Project…; nil for New Project.
    let parentID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "NewProjectSheet") { dismiss() }
    }
}
