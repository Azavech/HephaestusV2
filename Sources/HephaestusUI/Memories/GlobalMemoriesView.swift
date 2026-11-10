// OWNER: ui-memories — the Global Memories view (docs/memories.md › Global Memories view).
import HephaestusCore
import SwiftUI

/// View ▸ Global Memories: the list and the editors of the Memories section, or its empty state,
/// on the global memories folder of the window's device; the list's title row reads `Global
/// Memories` (docs/memories.md › Global Memories view).
struct GlobalMemoriesView: View {
    let window: WindowState
    let workspace: DeviceWorkspace

    var body: some View {
        MemoriesSectionView(window: window, workspace: workspace, scope: .global)
    }
}
