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
            app.mainWindowRootAppeared()
            guard state == nil else { return }
            // A restart whose saved windows hold no main window: SwiftUI still opens one at
            // launch, which closes at once (docs/ui.md › Windows, windowsAtRestart).
            if requestID == nil, app.takeSuppressedLaunchWindow() {
                dismiss()
                return
            }
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
                // The window has not chosen its project yet (docs/ui.md › Empty states).
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
                    .background(SidebarCollapseByDragging(state: state))
            }
            CentreColumn(state: state, workspace: workspace, project: project)
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                .background(PaneWidths(state: state))
            if state.inspectorVisible {
                ProjectChatPanel(window: state, workspace: workspace, projectID: project.id)
                    .frame(minWidth: 300, maxWidth: 600, maxHeight: .infinity)
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

/// The widths of the sidebar and the inspector (docs/ui.md › Main window layout): a main window
/// opens with the sidebar at 200 pt and the inspector at `inspectorWidth`, and a pane shown again
/// takes its width back (the sidebar its last width in this window). Only a divider dragged by
/// the user changes the widths, and only then is `inspectorWidth` stored. `HSplitView` ignores
/// `idealWidth`, so the widths are set on its `NSSplitView`, found from the centre column.
private struct PaneWidths: NSViewRepresentable {
    let state: WindowState

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
        static let defaultSidebarWidth: CGFloat = 200

        weak var state: WindowState?
        private weak var probe: NSView?
        private weak var splitView: NSSplitView?
        private var observer: NSObjectProtocol?
        /// The panes (sidebar, inspector) whose widths were last applied.
        private var applied: [Bool]?
        private var sidebarWidth = Coordinator.defaultSidebarWidth
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
                    let byUser = note.userInfo?["NSSplitViewDividerIndex"] != nil
                    MainActor.assumeIsolated {
                        self?.resized(byUser: byUser)
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

        /// Sets the sidebar and inspector widths; false when the split view is not ready yet.
        @discardableResult
        private func apply() -> Bool {
            guard let state, let splitView, let panes = panes() else { return false }
            isApplying = true
            defer { isApplying = false }
            splitView.layoutSubtreeIfNeeded()
            if panes.sidebar != nil {
                splitView.setPosition(sidebarWidth, ofDividerAt: panes.centre - 1)
            }
            if panes.inspector != nil {
                let position = splitView.bounds.width - CGFloat(state.inspectorWidth) - splitView.dividerThickness
                splitView.setPosition(position, ofDividerAt: panes.centre)
            }
            applied = [state.sidebarVisible, state.inspectorVisible]
            return true
        }

        /// A divider dragged by the user: the new widths are kept, `inspectorWidth` persisted.
        private func resized(byUser: Bool) {
            guard byUser, !isApplying, let state, let panes = panes() else { return }
            if let sidebar = panes.sidebar, sidebar.frame.width >= 160 {
                sidebarWidth = sidebar.frame.width
            }
            if let inspector = panes.inspector, inspector.frame.width >= 300 {
                state.inspectorWidth = Double(inspector.frame.width)
            }
        }
    }
}

/// Dragging the sidebar's divider to the window edge collapses the sidebar (docs/ui.md ›
/// Sidebar): the split view item of the sidebar pane may collapse, and a collapse that remains
/// when the drag ends hides the sidebar (`sidebarVisible`, persisted per window).
private struct SidebarCollapseByDragging: NSViewRepresentable {
    let state: WindowState

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
        view.attach()
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Finds the split view item of the pane it is in once it is in a window.
    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard window != nil else { return }
            coordinator?.attach(to: self)
        }
    }

    @MainActor
    final class Coordinator {
        weak var state: WindowState?
        private weak var item: NSSplitViewItem?
        private var observation: NSKeyValueObservation?
        private var waitingForMouseUp = false

        /// The `HSplitView` is an `NSSplitView` whose delegate is an `NSSplitViewController`; the
        /// sidebar's item becomes collapsible.
        func attach(to view: NSView) {
            var current = view.superview
            while let candidate = current, !(candidate is NSSplitView) {
                current = candidate.superview
            }
            guard let splitView = current as? NSSplitView,
                  let controller = splitView.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first(where: { view.isDescendant(of: $0.viewController.view) }) else { return }
            guard item !== self.item else { return }
            detach()
            self.item = item
            item.canCollapse = true
            observation = item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.collapseChanged()
                }
            }
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            item = nil
        }

        /// The divider moves past half the minimum width while the mouse is down; the sidebar is
        /// hidden only when it is still collapsed once the drag ends.
        private func collapseChanged() {
            guard !waitingForMouseUp else { return }
            waitingForMouseUp = true
            checkAfterDrag()
        }

        private func checkAfterDrag() {
            guard NSEvent.pressedMouseButtons & 1 == 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.checkAfterDrag()
                    }
                }
                return
            }
            waitingForMouseUp = false
            if item?.isCollapsed == true {
                state?.sidebarVisible = false
            }
        }
    }
}
