// OWNER: ui-shell — the main window: its root and state, its layout and empty states
// (docs/ui.md › Main window layout, › Empty states, › Persistence).
import HephaestusCore
import SwiftUI

/// The root of a main window: creates or restores its `WindowState`, registers it with the app
/// and keeps its persisted properties in `@SceneStorage` (docs/ui.md › Persistence).
struct MainWindowRoot: View {
    let requestID: UUID?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @SceneStorage("windowState") private var storedState: String?
    @State private var state: WindowState?

    var body: some View {
        Group {
            if let state {
                MainWindowView(state: state)
                    .onChange(of: state.persistedJSON) { _, json in
                        if app.persistsWindowState {
                            storedState = json
                        }
                    }
            } else {
                Color.clear
                    .frame(minWidth: 1000, minHeight: 560)
            }
        }
        .onAppear {
            app.captureWindowActions(openWindow: openWindow, openSettings: openSettings)
            guard state == nil else { return }
            let newState = app.makeMainWindowState(requestID: requestID, restoredJSON: storedState)
            app.registerMainWindow(newState)
            state = newState
        }
        .onDisappear {
            if let state {
                app.unregisterMainWindow(state.id)
            }
        }
    }
}

/// A main window: toolbar, columns and status bar (docs/ui.md › Main window layout).
struct MainWindowView: View {
    @Environment(AppModel.self) private var app
    @Bindable var state: WindowState

    var body: some View {
        let workspace = app.workspaces[state.deviceID]
        VStack(spacing: 0) {
            Group {
                if let workspace {
                    MainWindowColumns(state: state, workspace: workspace)
                } else {
                    LoadingStateView(text: "Loading \(app.deviceName(state.deviceID))…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBarView(context: .main(state), workspace: workspace)
        }
        .frame(minWidth: 1000, minHeight: 560)
        .toolbar {
            MainToolbar(state: state, workspace: workspace)
        }
        .toolbar(removing: .title)
        .navigationTitle(title(workspace))
        .registersWindow(.main(state.id), in: app)
        .focusedSceneValue(\.windowState, state)
        .sheet(item: $state.sheet) { sheet in
            if let workspace {
                WindowSheetView(sheet: sheet, window: state, workspace: workspace)
            }
        }
        .alert(state.alert?.title ?? "", isPresented: alertShown, presenting: state.alert) { _ in
            Button("OK") {}
        } message: { alert in
            if !alert.message.isEmpty {
                Text(alert.message)
            }
        }
        .onChange(of: state.sheet) { _, sheet in
            if sheet == nil {
                state.applyPendingTarget()
            }
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { state.alert != nil }, set: { if !$0 { state.alert = nil } })
    }

    /// The active project's name on This Mac; `<project name> — <device name>` on a remote
    /// device; `HephaestusV2` with no active project.
    private func title(_ workspace: DeviceWorkspace?) -> String {
        guard let workspace, let projectID = state.projectID, let project = workspace.project(projectID) else {
            return "HephaestusV2"
        }
        return workspace.isLocal ? project.name : "\(project.name) — \(workspace.deviceName)"
    }
}

/// Everything between the toolbar and the status bar: the reconnect view, the device's loading
/// state, the welcome view, or the three columns; the search panel and the update-ready banner
/// over them.
private struct MainWindowColumns: View {
    let state: WindowState
    let workspace: DeviceWorkspace

    var body: some View {
        Group {
            if !workspace.isLocal && !workspace.isConnected {
                ReconnectView(workspace: workspace, window: state)
            } else if !workspace.hasSnapshot {
                LoadingStateView(text: "Loading \(workspace.deviceName)…")
            } else if workspace.projects.isEmpty {
                WelcomeView(window: state, workspace: workspace)
            } else if let projectID = state.projectID, let project = workspace.project(projectID) {
                ProjectColumns(state: state, workspace: workspace, project: project)
            } else {
                // DOC-GAP: the docs define no state for the moment between the snapshot and the
                // choice of the default project; the device's loading state stays.
                LoadingStateView(text: "Loading \(workspace.deviceName)…")
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if state.searchVisible {
                    SearchPanel(window: state, workspace: workspace)
                }
                UpdateBanner()
            }
        }
        .onAppear {
            state.reconcileProject(with: workspace)
            state.applyPendingTarget()
        }
        .onChange(of: workspace.hasSnapshot) {
            state.reconcileProject(with: workspace)
            state.applyPendingTarget()
        }
        .onChange(of: workspace.projects) {
            state.reconcileProject(with: workspace)
        }
        .onChange(of: workspace.state) {
            state.applyPendingTarget()
        }
        .onChange(of: state.projectID) { _, projectID in
            if let projectID {
                workspace.ensureProjectLoaded(projectID)
            }
        }
    }
}

/// The sidebar, the centre column and the inspector: the three panes of one split view with plain
/// panes (docs/ui.md › Main window layout).
private struct ProjectColumns: View {
    let state: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary

    var body: some View {
        HSplitView {
            if state.sidebarVisible {
                SidebarView(window: state, workspace: workspace, project: project)
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 280, maxHeight: .infinity)
            }
            CentreColumn(state: state, workspace: workspace, project: project)
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            if state.inspectorVisible {
                ProjectChatPanel(window: state, workspace: workspace, projectID: project.id)
                    .frame(minWidth: 300, idealWidth: state.inspectorWidth, maxWidth: 600, maxHeight: .infinity)
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width in
                        if width >= 300 {
                            state.inspectorWidth = width
                        }
                    }
            }
        }
    }
}

/// The selected section of the active project, with the console drawer under it
/// (docs/ui.md › Console drawer).
private struct CentreColumn: View {
    let state: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary

    var body: some View {
        VSplitView {
            SectionContent(state: state, workspace: workspace, project: project)
                .frame(minHeight: 200, maxHeight: .infinity)
            if state.consoleVisible {
                ConsoleDrawer(window: state, workspace: workspace, projectID: project.id)
                    .frame(minHeight: 120, idealHeight: state.consoleHeight, maxHeight: .infinity)
                    .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { height in
                        if height >= 120 {
                            state.consoleHeight = height
                        }
                    }
            }
        }
    }
}

/// The section the sidebar selects, once the project's data is loaded.
private struct SectionContent: View {
    let state: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary

    var body: some View {
        let projectID = project.id
        if let error = workspace.projectLoadErrors[projectID] {
            ProjectLoadFailedView(projectName: project.name, error: error) {
                workspace.retryProjectLoad(projectID)
            }
        } else if !workspace.loadedProjectIDs.contains(projectID) {
            LoadingStateView(text: "Loading \(project.name)…")
                .onAppear {
                    workspace.ensureProjectLoaded(projectID)
                }
        } else {
            switch state.section {
            case .tickets:
                TicketsSectionView(window: state, workspace: workspace, projectID: projectID)
            case .bundles:
                BundlesSectionView(window: state, workspace: workspace, projectID: projectID)
            case .chats:
                ChatsSectionView(window: state, workspace: workspace, projectID: projectID)
            case .code:
                CodeSectionView(window: state, workspace: workspace, projectID: projectID)
            case .docs:
                DocsSectionView(window: state, workspace: workspace, projectID: projectID)
            case .web:
                WebSectionView(window: state, workspace: workspace, projectID: projectID)
            case .skills:
                SkillsSectionView(window: state, workspace: workspace, projectID: projectID)
            }
        }
    }
}
