// OWNER: ui-shell — the main window's toolbar (docs/ui.md › Toolbar).
import SwiftUI

/// The breadcrumb selector as principal item, Search, New Chat and Project Chat trailing. The
/// toolbar shows no window title and no sidebar toggle, and cannot be customised.
struct MainToolbar: ToolbarContent {
    let state: WindowState
    let workspace: DeviceWorkspace?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            BreadcrumbSelector(window: state, workspace: workspace)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.toggleSearch()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search (⇧⌘F)")
            .disabled(!state.isConnected)
            Button {
                state.newChat()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
            }
            .help("New Chat (⌥⌘N)")
            .disabled(!state.hasActiveProject)
            Button {
                state.inspectorVisible.toggle()
            } label: {
                Label("Project Chat", systemImage: "sidebar.right")
            }
            .help(state.inspectorVisible ? "Hide Project Chat (⌥⌘0)" : "Show Project Chat (⌥⌘0)")
            .disabled(state.projectID == nil)
        }
    }
}
