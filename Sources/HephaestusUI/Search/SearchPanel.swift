// OWNER: ui-web-search — the search panel drawn over the columns (docs/search.md › Search panel).
import HephaestusCore
import SwiftUI

/// The search panel of a main window (`WindowState.searchVisible`, `WindowState.search`); opening a result calls `WindowState.navigate(to:)`.
// STUB: ui-web-search
struct SearchPanel: View {
    let window: WindowState
    let workspace: DeviceWorkspace

    var body: some View {
        PlaceholderView(name: "SearchPanel")
            .frame(width: 720, height: 200)
            .padding(.top, 8)
    }
}
