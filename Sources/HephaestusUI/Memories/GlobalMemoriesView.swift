// OWNER: ui-memories — the Global Memories view (docs/memories.md › Global Memories view).
import HephaestusCore
import SwiftUI

/// View ▸ Global Memories: the header `Global Memories`, then the list and the editors of the
/// Memories section, or its empty state, on the global memories folder of the window's device
/// (docs/memories.md › Global Memories view).
struct GlobalMemoriesView: View {
    let window: WindowState
    let workspace: DeviceWorkspace

    var body: some View {
        VStack(spacing: 0) {
            // The view's pane header, 36 pt like every header of the centre column (docs/ui.md ›
            // Pane headers).
            HStack {
                Text("Global Memories")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 12)
            .paneHeaderBar()
            Divider()
            MemoriesSectionView(window: window, workspace: workspace, scope: .global)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
