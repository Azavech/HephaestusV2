// OWNER: ui-shell — the main window: its root and state, its layout and empty states
// (docs/ui.md › Main window layout, › Empty states, › Persistence).
import AppKit
import HephaestusCore
import SwiftUI

/// The root of a main window: creates or restores its `WindowState`, registers it with the app
/// and keeps its persisted properties in `@SceneStorage` (docs/ui.md › Persistence).
struct MainWindowRoot: View {
    let requestID: UUID?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
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
            if let newState = app.mainWindowRootAppeared(requestID: requestID, restoredJSON: storedState) {
                state = newState
            } else {
                // A restart whose saved windows hold no main window: SwiftUI still opens one at
                // launch, which closes at once (docs/ui.md › Windows, windowsAtRestart).
                dismiss()
            }
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
        // One plain band across the window: SwiftUI lays the split views and their panes out under
        // the toolbar, so its opaque background covers them (docs/ui.md › Main window layout).
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .navigationTitle(title(workspace))
        .registersWindow(.main(state.id), in: app)
        .focusedSceneValue(\.windowState, state)
        // The composers of the window open its search panel to add a resource.
        .environment(\.searchPanelWindow, state)
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
/// state, the welcome view, or the three columns; the search panel over them.
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
                // The Global Memories view, the Internal Skills view, the detail of a virtual
                // machine and the setup view of an image take the welcome view's place (docs/ui.md
                // › Welcome view).
                if let vmID = state.shownVirtualMachineID {
                    VirtualMachineDetailView(window: state, workspace: workspace, vmID: vmID)
                        .id("\(workspace.deviceID)/vm/\(vmID.uuidString)")
                } else if let imageID = state.shownImageSetupID {
                    // The image's Auto Setup chat without a project shows beside the setup view
                    // (docs/ui.md › Welcome view).
                    ImageSetupWithChat(window: state, workspace: workspace, imageID: imageID)
                        .id("\(workspace.deviceID)/setup/\(imageID.uuidString)")
                } else if state.showsGlobalMemories {
                    GlobalMemoriesView(window: state, workspace: workspace)
                        .id("\(workspace.deviceID)/global")
                } else if state.showsInternalSkills {
                    InternalSkillsView(window: state, workspace: workspace)
                        .id("\(workspace.deviceID)/internalSkills")
                } else {
                    WelcomeView(window: state, workspace: workspace)
                }
            } else if let projectID = state.projectID, let project = workspace.project(projectID) {
                ProjectColumns(state: state, workspace: workspace, project: project)
            } else {
                // The window has not chosen its project yet (docs/ui.md › Empty states).
                LoadingStateView(text: "Loading \(workspace.deviceName)…")
            }
        }
        .overlay(alignment: .top) {
            if state.searchVisible {
                SearchPanel(window: state, workspace: workspace)
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
        .onChange(of: buildsVisibility, initial: true) {
            state.reconcileBuildsSection(with: workspace)
        }
    }

    /// What decides whether the window may show Builds (docs/builds.md › Visibility).
    private var buildsVisibility: [String] {
        let projectID = state.projectID ?? ""
        return [workspace.deviceID, projectID, String(workspace.loadedProjectIDs.contains(projectID)),
                workspace.details[projectID]?.githubPage ?? "", state.section.rawValue]
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
                    .frame(minWidth: PaneWidthMemory.minimumSidebarWidth, idealWidth: PaneWidthMemory.defaultSidebarWidth,
                           maxWidth: 280, maxHeight: .infinity)
            }
            SectionContent(state: state, workspace: workspace, project: project)
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                .background(PaneWidths(state: state, sidebarVisible: state.sidebarVisible,
                                       inspectorVisible: state.inspectorVisible))
            if state.inspectorVisible {
                ProjectChatPanel(window: state, workspace: workspace, projectID: project.id)
                    .frame(minWidth: PaneWidthMemory.minimumInspectorWidth, maxWidth: 600, maxHeight: .infinity)
            }
        }
        // An item unlinked from the inspector chat is linked again once it is no longer open,
        // whether the inspector is shown or not (docs/ui.md › Inspector).
        .onChange(of: state.viewState.openItems(in: state.shownSection, virtualMachineID: state.shownVirtualMachineID,
                                                imageSetupID: state.shownImageSetupID)) {
            state.updateViewState(of: project.id) {
                $0.forgetClosedUnlinkedItems(in: state.shownSection, virtualMachineID: state.shownVirtualMachineID,
                                             imageSetupID: state.shownImageSetupID)
            }
        }
        // The descendants' tickets, for the Tickets section: loaded at once, then for each
        // descendant added or opened, and again once the device is connected (docs/ui.md ›
        // DeviceWorkspace, Loading step 3).
        .task(id: DescendantsLoad(projectIDs: workspace.descendants(of: project.id).map(\.project.id),
                                  isConnected: workspace.isConnected)) {
            workspace.ensureDescendantsLoaded(of: project.id)
        }
        // The workspace follows the contract of a Go service, and the window leaves the API
        // Explorer where its row is not shown (docs/openapi.md › Availability).
        .task(id: APIExplorerFollow(deviceID: workspace.deviceID, projectID: project.id, type: project.type)) {
            workspace.followAPIContract(of: project.id)
        }
        .onChange(of: APIExplorerState(deviceID: workspace.deviceID, projectID: project.id, section: state.section,
                                       isShown: workspace.showsAPIExplorer(project.id)), initial: true) {
            state.leaveHiddenAPIExplorer(in: workspace)
        }
        // The window leaves the Graph of a project whose graph is not enabled (docs/graph.md ›
        // Enabling).
        .onChange(of: GraphRowState(deviceID: workspace.deviceID, projectID: project.id, section: state.section,
                                    isShown: workspace.details[project.id].map(\.graphEnabled)), initial: true) {
            state.leaveHiddenGraph(in: workspace)
        }
    }
}

/// What makes a main window load the descendants of its project again.
private struct DescendantsLoad: Hashable {
    var projectIDs: [String]
    var isConnected: Bool
}

/// What makes the workspace follow the contract of the window's project.
private struct APIExplorerFollow: Hashable {
    var deviceID: String
    var projectID: String
    var type: ProjectType
}

/// What makes the window check that its API Explorer section still has its row.
private struct APIExplorerState: Hashable {
    var deviceID: String
    var projectID: String
    var section: ProjectSection
    var isShown: Bool?
}

/// What makes the window check that its project's Graph row is shown: nil `isShown` while the
/// project's detail is loading.
private struct GraphRowState: Hashable {
    var deviceID: String
    var projectID: String
    var section: ProjectSection
    var isShown: Bool?
}

/// The centre column: the section the sidebar selects, once the project's data is loaded, the
/// Global Memories view, the Internal Skills view, the detail of a virtual machine or the setup
/// view of an image, which need no project data (docs/memories.md › Global Memories view,
/// docs/skills.md › Internal Skills view, docs/virtual-machines.md › Detail, › Setup view), or the Dashboard of a sub project shown from the
/// sidebar, once its data is loaded (docs/dashboard.md › Section). The tests of the pane titles
/// host it.
struct SectionContent: View {
    let state: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary

    var body: some View {
        if let vmID = state.shownVirtualMachineID {
            VirtualMachineDetailView(window: state, workspace: workspace, vmID: vmID)
                .id("\(workspace.deviceID)/vm/\(vmID.uuidString)")
        } else if let imageID = state.shownImageSetupID {
            ImageSetupView(window: state, imageID: imageID)
                .id("\(workspace.deviceID)/setup/\(imageID.uuidString)")
        } else if state.showsGlobalMemories {
            GlobalMemoriesView(window: state, workspace: workspace)
                .id("\(workspace.deviceID)/global")
        } else if state.showsInternalSkills {
            InternalSkillsView(window: state, workspace: workspace)
                .id("\(workspace.deviceID)/internalSkills")
        } else if let subProjectID = state.subProjectDashboardID, let subProject = workspace.project(subProjectID) {
            loaded(subProject) {
                DashboardView(window: state, workspace: workspace, projectID: subProjectID, showsHeader: true)
            }
        } else {
            loaded(project) {
                section(project.id)
            }
        }
    }

    /// The content once the project's data is loaded; its loading or failure state until then.
    @ViewBuilder
    private func loaded(_ project: ProjectSummary, @ViewBuilder content: () -> some View) -> some View {
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
            content()
        }
    }

    /// The selected section of the active project.
    @ViewBuilder
    private func section(_ projectID: String) -> some View {
        switch state.section {
        case .dashboard:
            DashboardView(window: state, workspace: workspace, projectID: projectID)
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
        case .builds:
            BuildsSectionView(window: state, workspace: workspace, projectID: projectID)
                .id("\(workspace.deviceID)/\(projectID)")
        case .skills:
            SkillsSectionView(window: state, workspace: workspace, scope: .project(projectID))
        case .memories:
            MemoriesSectionView(window: state, workspace: workspace, scope: .project(projectID))
                .id("\(workspace.deviceID)/\(projectID)")
        case .costs:
            CostsSectionView(window: state, workspace: workspace, projectID: projectID)
        case .apiExplorer:
            APIExplorerView(window: state, workspace: workspace, projectID: projectID)
        case .graph:
            GraphSectionView(window: state, workspace: workspace, projectID: projectID)
                .id("\(workspace.deviceID)/\(projectID)")
        case .settings:
            ProjectSettingsView(window: state, workspace: workspace, projectID: projectID)
        }
    }
}

/// The widths of the sidebar and the inspector (docs/ui.md › Main window layout): a main window
/// opens with the sidebar at its default width and the inspector at `inspectorWidth`, and a pane
/// shown again takes its width back, the sidebar its last width in this window. Dragging the
/// sidebar's divider to the window edge collapses the sidebar (docs/ui.md › Sidebar): its split
/// view item may collapse, and a collapse that remains when the drag ends hides the sidebar
/// (`sidebarVisible`, persisted per window). `HSplitView` ignores `idealWidth`, so the widths are
/// set on its `NSSplitView`, found from the centre column.
private struct PaneWidths: NSViewRepresentable {
    let state: WindowState
    /// The shown panes: SwiftUI updates this view when they change, and the widths are applied.
    let sidebarVisible: Bool
    let inspectorVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        context.coordinator.state = state
        context.coordinator.update(probe: view)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.update(probe: self)
        }
    }

    @MainActor
    final class Coordinator {
        weak var state: WindowState?
        private weak var probe: NSView?
        private weak var splitView: NSSplitView?
        private var observer: NSObjectProtocol?
        /// The panes (sidebar, inspector) whose widths were last applied.
        private var applied: [Bool]?
        private var memory = PaneWidthMemory()
        private var isApplying = false
        private var applyScheduled = false

        /// Finds the split view and applies the widths when the shown panes changed.
        func update(probe: NSView) {
            self.probe = probe
            guard let state, probe.window != nil else { return }
            var current = probe.superview
            while let candidate = current, !(candidate is NSSplitView) {
                current = candidate.superview
            }
            guard let found = current as? NSSplitView else { return }
            if found !== splitView {
                detach()
                splitView = found
                applied = nil
                observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                                                  object: found, queue: .main) { [weak self] note in
                    let divider = (note.userInfo?["NSSplitViewDividerIndex"] as? NSNumber)?.intValue
                    MainActor.assumeIsolated {
                        self?.resized(divider: divider)
                    }
                }
            }
            if applied != [state.sidebarVisible, state.inspectorVisible] {
                scheduleApply(attempts: 20)
            }
        }

        func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            splitView = nil
        }

        /// The panes in split view order around the centre column, once SwiftUI has added or
        /// removed them and the split view has its width.
        private func panes() -> (sidebar: NSView?, centre: Int, inspector: NSView?)? {
            guard let state, let splitView, let probe, splitView.bounds.width > 0 else { return nil }
            let views = splitView.arrangedSubviews
            guard views.count == 1 + (state.sidebarVisible ? 1 : 0) + (state.inspectorVisible ? 1 : 0),
                  let centre = views.firstIndex(where: { probe.isDescendant(of: $0) }) else { return nil }
            let sidebar = state.sidebarVisible && centre > 0 ? views[centre - 1] : nil
            let inspector = state.inspectorVisible && centre + 1 < views.count ? views[centre + 1] : nil
            return (sidebar, centre, inspector)
        }

        /// The split view item of the sidebar pane: the split view of `HSplitView` is managed by
        /// an `NSSplitViewController`, its delegate, and each pane wraps the view of its item.
        private func sidebarItem(_ sidebar: NSView) -> NSSplitViewItem? {
            (splitView?.delegate as? NSSplitViewController)?.splitViewItems.first { $0.viewController.view.isDescendant(of: sidebar) }
        }

        private func scheduleApply(attempts: Int) {
            guard !applyScheduled else { return }
            applyScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyScheduled = false
                    if !self.apply(), attempts > 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                            MainActor.assumeIsolated {
                                self?.scheduleApply(attempts: attempts - 1)
                            }
                        }
                    }
                }
            }
        }

        /// Sets the sidebar and inspector widths, and makes the sidebar's item collapsible and
        /// expanded; false when the split view is not ready yet.
        @discardableResult
        private func apply() -> Bool {
            guard let state, let splitView, let panes = panes() else { return false }
            isApplying = true
            defer { isApplying = false }
            splitView.layoutSubtreeIfNeeded()
            if let sidebar = panes.sidebar {
                if let item = sidebarItem(sidebar) {
                    item.canCollapse = true
                    if item.isCollapsed && memory.drag == nil {
                        item.isCollapsed = false
                    }
                }
                splitView.setPosition(memory.sidebarWidth, ofDividerAt: panes.centre - 1)
            }
            if panes.inspector != nil {
                let position = splitView.bounds.width - CGFloat(state.inspectorWidth) - splitView.dividerThickness
                splitView.setPosition(position, ofDividerAt: panes.centre)
            }
            applied = [state.sidebarVisible, state.inspectorVisible]
            return true
        }

        /// The split view resized its panes, `divider` the index of the divider it names. Only
        /// while the app handles a drag with the left mouse button in this window is it a divider
        /// dragged by the user: the split view also names a divider when SwiftUI resizes the panes
        /// while it adds or removes one.
        private func resized(divider: Int?) {
            guard !isApplying, let state, let splitView, let panes = panes() else { return }
            let startsDrag = memory.drag == nil
            let sidebarCollapsed = panes.sidebar.map { splitView.isSubviewCollapsed($0) } ?? false
            let sidebar = panes.sidebar.map { PaneWidthMemory.Pane(divider: panes.centre - 1, width: $0.frame.width) }
            let inspector = panes.inspector.map { PaneWidthMemory.Pane(divider: panes.centre, width: $0.frame.width) }
            if let width = memory.splitViewResized(divider: divider, byUser: handlesLeftMouseDrag, sidebar: sidebar,
                                                   sidebarCollapsed: sidebarCollapsed, inspector: inspector) {
                state.inspectorWidth = Double(width)
            }
            if startsDrag && memory.drag != nil {
                waitForDragEnd()
            }
        }

        /// Once the drag is over, a sidebar still collapsed is hidden, and an inspector that a
        /// collapse during the drag widened takes back its width.
        private func waitForDragEnd() {
            guard !handlesLeftMouseDrag else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.waitForDragEnd()
                    }
                }
                return
            }
            let panes = panes()
            let collapsed = panes?.sidebar.map { splitView?.isSubviewCollapsed($0) == true } ?? false
            switch memory.dragEnded(sidebarCollapsed: collapsed) {
            case .hideSidebar:
                state?.sidebarVisible = false
            case .restoreInspector(let width):
                guard let splitView, let panes, panes.inspector != nil else { return }
                isApplying = true
                defer { isApplying = false }
                splitView.setPosition(splitView.bounds.width - width - splitView.dividerThickness, ofDividerAt: panes.centre)
            case .none:
                break
            }
        }

        /// True while the app handles a drag with the left mouse button in this window. The split
        /// view takes the events of a divider drag from the queue, so this holds while it handles
        /// them, even after the button was released, and ends with the mouse up.
        private var handlesLeftMouseDrag: Bool {
            guard let event = NSApp.currentEvent, event.window === splitView?.window else { return false }
            return event.type == .leftMouseDown || event.type == .leftMouseDragged
        }
    }
}

/// What a main window remembers of its pane widths (docs/ui.md › Main window layout): the
/// sidebar's last width in this window, and the inspector width that its window stores in
/// `inspectorWidth`. Only a divider dragged by the user changes them, and a drag that collapses
/// the sidebar does not change its last width.
struct PaneWidthMemory {
    /// Wider than the toolbar's Sidebar button, which ends inside it, and wide enough for Project
    /// Settings on one line.
    static let minimumSidebarWidth: CGFloat = 190
    static let defaultSidebarWidth: CGFloat = 200
    static let minimumInspectorWidth: CGFloat = 300

    /// A pane beside the centre column: the index of the divider between them, and its width.
    struct Pane: Equatable {
        var divider: Int
        var width: CGFloat
    }

    /// A divider drag in progress.
    struct Drag: Equatable {
        /// The dragged divider: the first one the split view names during the drag. When the
        /// sidebar collapses, the split view widens the inspector and names its divider too.
        var divider: Int
        /// The sidebar's last width when the drag started.
        var sidebarWidth: CGFloat
        /// The inspector's width when the drag started, when it is shown.
        var inspectorWidth: CGFloat?
        /// Whether the sidebar collapsed during the drag.
        var sidebarCollapsed = false
    }

    /// What the end of a drag asks for.
    enum DragEnd: Equatable {
        case none
        /// The sidebar is still collapsed: it is hidden.
        case hideSidebar
        /// The sidebar collapsed during the drag and is shown again: the inspector, which the
        /// collapse widened, takes back this width.
        case restoreInspector(CGFloat)
    }

    /// The sidebar's last width in this window.
    private(set) var sidebarWidth = PaneWidthMemory.defaultSidebarWidth
    /// The divider drag in progress; nil while no divider is dragged.
    private(set) var drag: Drag?

    /// The split view resized its panes, naming `divider`; `byUser` when the app was handling a
    /// drag with the left mouse button then. `sidebar` and `inspector` are the shown panes.
    /// Returns the inspector width to store when the user drags the inspector's divider.
    mutating func splitViewResized(divider: Int?, byUser: Bool, sidebar: Pane?, sidebarCollapsed: Bool,
                                   inspector: Pane?) -> CGFloat? {
        guard let divider, byUser else { return nil }
        if drag == nil {
            drag = Drag(divider: divider, sidebarWidth: sidebarWidth, inspectorWidth: inspector?.width)
        }
        if sidebarCollapsed {
            drag?.sidebarCollapsed = true
        }
        guard divider == drag?.divider else { return nil }
        if let sidebar, !sidebarCollapsed, sidebar.divider == divider, sidebar.width >= Self.minimumSidebarWidth {
            sidebarWidth = sidebar.width
        }
        if let inspector, inspector.divider == divider, inspector.width >= Self.minimumInspectorWidth {
            return inspector.width
        }
        return nil
    }

    /// The drag is over, `sidebarCollapsed` when it left the sidebar collapsed, which keeps then
    /// the last width it had before the drag.
    mutating func dragEnded(sidebarCollapsed: Bool) -> DragEnd {
        guard let drag else { return .none }
        self.drag = nil
        if sidebarCollapsed {
            sidebarWidth = drag.sidebarWidth
            return .hideSidebar
        }
        if drag.sidebarCollapsed, let width = drag.inspectorWidth {
            return .restoreInspector(width)
        }
        return .none
    }
}
