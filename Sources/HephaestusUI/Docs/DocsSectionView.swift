// OWNER: ui-code-docs — the Docs section: docs tree and viewer in Preview, Edit or Split mode (docs/documentation-viewer.md › Layout, › Modes).
import HephaestusCore
import SwiftUI

/// The Docs section of the active project (`ProjectViewState.selectedDocPath`, `docMode`, `docBuffer`); a selected doc that does not exist shows `NotFoundView(kind: "Doc", id:)`.
// STUB: ui-code-docs
struct DocsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "DocsSectionView")
    }
}
