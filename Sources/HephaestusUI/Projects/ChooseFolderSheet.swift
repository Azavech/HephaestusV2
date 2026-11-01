// OWNER: ui-shell — the Choose Folder sheet over `fs.browse` (docs/projects.md › Picking a folder on a remote device).
import HephaestusCore
import SwiftUI

/// The folder browser of a window showing a remote device: Open Project… and the folder fields of the New Project sheet.
// STUB: ui-shell
struct ChooseFolderSheet: View {
    /// What the chosen folder is for.
    enum Purpose {
        /// Open Project… on a remote device: the folder is opened with `projects.open`.
        case openProject
        /// A folder field of the New Project or New Sub Project sheet.
        case projectFolder
    }

    let window: WindowState
    let workspace: DeviceWorkspace
    let purpose: Purpose
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "ChooseFolderSheet") { dismiss() }
    }
}
