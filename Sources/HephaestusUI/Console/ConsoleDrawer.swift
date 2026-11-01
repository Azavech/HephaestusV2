// OWNER: ui-shell — the console drawer of the active project's runs (docs/projects.md › Console; docs/ui.md › Console drawer).
import HephaestusCore
import SwiftUI

/// Run picker, starter, status, Stop, Clear, Hide and the output of the selected run (`ProjectViewState.consoleRunID`).
// STUB: ui-shell
struct ConsoleDrawer: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "ConsoleDrawer")
    }
}
