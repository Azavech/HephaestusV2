// OWNER: ui-shell — the main window's toolbar (docs/ui.md › Toolbar).
import HephaestusCore
import SwiftUI

/// Run and Stop leading, the breadcrumb selector as principal item, Search, New Chat and Project
/// Chat trailing. The toolbar shows no window title and no sidebar toggle, and cannot be
/// customised.
struct MainToolbar: ToolbarContent {
    let state: WindowState
    let workspace: DeviceWorkspace?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            RunToolbarButton(state: state)
            Button {
                state.stopRuns()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop (⌘.)")
            .disabled(state.rootRunningRuns.isEmpty)
        }
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

/// Run: a click starts the `run` command; without one, the click opens the menu of Run, Build and
/// Test, where an item whose command is not set is disabled (docs/ui.md › Toolbar).
private struct RunToolbarButton: View {
    let state: WindowState

    var body: some View {
        let enabled = state.hasActiveProject && RunKind.allCases.contains { state.command($0) != nil }
        Group {
            if state.command(.run) != nil {
                Menu {
                    items
                } label: {
                    Label("Run", systemImage: "play.fill")
                } primaryAction: {
                    state.startRun(.run)
                }
            } else {
                Menu {
                    items
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
            }
        }
        .help("Run (⌘R)")
        .disabled(!enabled)
    }

    @ViewBuilder
    private var items: some View {
        ForEach([RunKind.run, .build, .test], id: \.self) { kind in
            Button(kind.title) {
                state.startRun(kind)
            }
            .disabled(state.command(kind) == nil)
            .help(state.command(kind) == nil ? "No \(kind.rawValue) command. Set one in Project Settings." : "")
        }
    }
}
