// OWNER: ui-web-search — the Web section: tab strip, address bar, web views, downloads (docs/web-tabs.md › Web section layout).
import HephaestusCore
import SwiftUI

/// The Web section of the active project (`ProjectViewState.selectedWebTabID`); it consumes `SectionCommand.newWebTab` and `.openLocation`.
// STUB: ui-web-search
struct WebSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "WebSectionView")
    }
}
