// OWNER: ui-shell — the main window's toolbar (docs/ui.md › Toolbar).
import SwiftUI

/// The Sidebar button leading, the breadcrumb selector and the Virtual Machines bubble as
/// principal items, Search, New Chat and Project Chat trailing. The toolbar shows no window title
/// and cannot be customised.
struct MainToolbar: ToolbarContent {
    let state: WindowState
    let workspace: DeviceWorkspace?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                state.sidebarVisible.toggle()
            } label: {
                Label("Sidebar", systemImage: "sidebar.left")
            }
            .help("\(state.sidebarToggleTitle) (⌃⌘S)")
        }
        ToolbarItem(placement: .principal) {
            BreadcrumbSelector(window: state, workspace: workspace)
        }
        // A pill of its own right of the breadcrumb's, in windows that show This Mac only
        // (docs/virtual-machines.md › Bubble).
        if let workspace, workspace.isLocal {
            ToolbarSpacer(.fixed, placement: .principal)
            ToolbarItem(placement: .principal) {
                VirtualMachinesBubble(window: state, workspace: workspace)
            }
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

extension WindowState {
    /// `Hide Sidebar` while the sidebar is shown, `Show Sidebar` while it is hidden: the title of
    /// View ▸ Show Sidebar / Hide Sidebar and the start of the Sidebar button's tooltip.
    var sidebarToggleTitle: String {
        sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
    }
}
