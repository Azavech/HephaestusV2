// OWNER: ui-shell — the Dashboard section (docs/dashboard.md).
import AppKit
import HephaestusCore
import SwiftUI

/// What the widgets show, from the workspace's data (docs/dashboard.md › Widgets).
enum DashboardContent {
    /// The widget's title: its `Title` setting, or the title of its kind when that is empty.
    static func title(of widget: DashboardWidget) -> String {
        let title = widget.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? widget.kind.title : title
    }

    /// The fields a Project widget shows, in the order of its settings whatever the stored order.
    static func fields(of widget: DashboardWidget) -> [DashboardProjectField] {
        DashboardProjectField.allCases.filter(widget.fields.contains)
    }

    /// The statuses whose counts a Tickets widget shows, in the order of its settings.
    static func statuses(of widget: DashboardWidget) -> [TicketStatus] {
        TicketStatus.allCases.filter(widget.statuses.contains)
    }

    /// The counts of a Tickets widget: those of the project and its loaded descendants, or the
    /// project's own with `Include sub projects` unchecked.
    static func ticketCounts(of project: ProjectSummary, widget: DashboardWidget) -> TicketCounts {
        widget.includeSubprojects ? project.ticketCounts : project.ownTicketCounts
    }

    static func count(_ status: TicketStatus, in counts: TicketCounts) -> Int {
        switch status {
        case .todo: return counts.todo
        case .inProgress: return counts.inProgress
        case .review: return counts.review
        case .done: return counts.done
        }
    }

    /// The total of a Cost widget: that of the project and its loaded descendants, or the
    /// project's own with `Include sub projects` unchecked.
    static func costUSD(of project: ProjectSummary, widget: DashboardWidget) -> Double {
        widget.includeSubprojects ? project.costUSD : project.ownCostUSD
    }

    /// The number of chats a Recent Chats widget lists: its setting, brought back within 1–20 when
    /// a file edited by hand put it outside.
    static func chatLimit(of widget: DashboardWidget) -> Int {
        min(max(widget.chatCount, DashboardWidget.chatCountRange.lowerBound), DashboardWidget.chatCountRange.upperBound)
    }

    /// The project's most recently updated chats of the widget's kinds, newest first.
    static func recentChats(of projectID: String, in chats: [ChatMeta], widget: DashboardWidget) -> [ChatMeta] {
        Array(chats.filter { $0.projectID == projectID && widget.chatKinds.contains($0.kind) }
            .sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id.uuidString < $1.id.uuidString }
            .prefix(chatLimit(of: widget)))
    }

    /// The label of a chat kind's checkbox in the settings popover.
    static func label(of kind: ChatKind) -> String {
        switch kind {
        case .project: return "Project"
        case .ticket: return "Ticket"
        case .bundle: return "Bundle"
        case .feedback: return "Feedback"
        case .ci: return "CI"
        }
    }
}

/// What an Instances widget shows (docs/dashboard.md › Instances widget).
enum DashboardInstances {
    /// The colour of the dot before a pod's STATUS.
    enum Dot: Equatable {
        case green, orange, red, gray
    }

    /// The column headers of `kubectl get pods -o wide`, in their order.
    static let headers = ["Name", "Ready", "Status", "Restarts", "Age", "Node"]
    /// The time from the end of a read to the start of the next one.
    static let interval: Duration = .seconds(10)
    static let noEnvironmentMessage = "Add an environment in Project Settings."

    /// The STATUS texts of a pod that starts or stops; `Init:<n>/<m>` and `Running` with a container
    /// not ready are too.
    static let changingStatuses: Set<String> = ["Pending", "ContainerCreating", "PodInitializing", "Terminating"]
    /// The STATUS texts of a pod that fails, also after `Init:`.
    static let failedStatuses: Set<String> = ["Failed", "Error", "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull",
                                              "CreateContainerConfigError", "OOMKilled", "Evicted"]

    /// `<ready containers>/<containers>`.
    static func ready(_ pod: PodStatus) -> String {
        "\(pod.readyContainers)/\(pod.containers)"
    }

    /// Green for a pod running with every container ready, orange while it starts or stops, red
    /// when it fails, grey otherwise.
    static func dot(_ pod: PodStatus) -> Dot {
        let status = pod.status
        if status == "Running" {
            return pod.readyContainers == pod.containers ? .green : .orange
        }
        if changingStatuses.contains(status) || isInitProgress(status) {
            return .orange
        }
        if failedStatuses.contains(status) || (status.hasPrefix("Init:") && failedStatuses.contains(String(status.dropFirst(5)))) {
            return .red
        }
        return .gray
    }

    /// `Init:<n>/<m>`, the init containers still running.
    static func isInitProgress(_ status: String) -> Bool {
        guard status.hasPrefix("Init:") else { return false }
        let parts = status.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}

/// A widget of a list: its id and its rank among the widgets that have that id, which only a file
/// edited by hand repeats (docs/dashboard.md › Widgets). It identifies the widget's view and the
/// widget an edit applies to.
struct DashboardSlot: Hashable {
    var id: UUID
    var occurrence: Int

    static func slots(of widgets: [DashboardWidget]) -> [DashboardSlot] {
        var seen: [UUID: Int] = [:]
        return widgets.map { widget in
            let occurrence = seen[widget.id, default: 0]
            seen[widget.id] = occurrence + 1
            return DashboardSlot(id: widget.id, occurrence: occurrence)
        }
    }

    func index(in widgets: [DashboardWidget]) -> Int? {
        Self.slots(of: widgets).firstIndex(of: self)
    }
}

/// What the place of the widgets depends on besides their list: whether the graph widgets show,
/// and the rows the content of each widget needs at the cell size of the window, which are known
/// once the widget has been laid out (docs/dashboard.md › Placement, Lists without positions).
struct DashboardArrangement: Equatable {
    var graphEnabled = false
    var rows: [DashboardSlot: Int] = [:]

    /// The cells of each widget of a list, nil for a hidden graph widget. A widget without
    /// position whose rows are not known yet counts one row.
    func cells(of widgets: [DashboardWidget]) -> [DashboardCells?] {
        let slots = DashboardSlot.slots(of: widgets)
        return DashboardGrid.layout(of: widgets, graphEnabled: graphEnabled) { rows[slots[$0]] ?? 1 }
    }

    /// The list with `cells` as the stored position and size of each shown widget. A hidden graph
    /// widget keeps its own, and a widget without position whose rows are not known yet stays
    /// without position.
    func storing(_ cells: [DashboardCells?], in widgets: [DashboardWidget]) -> [DashboardWidget] {
        let slots = DashboardSlot.slots(of: widgets)
        var list = widgets
        for (index, cell) in cells.enumerated() where index < list.count {
            guard let cell, list[index].cells != nil || rows[slots[index]] != nil else { continue }
            list[index].cells = cell
        }
        return list
    }
}

/// The changes of edit mode, each a new list made from the newest one; nil when the widget it
/// applies to is no longer in the list (docs/dashboard.md › Edit mode, Settings). A move, a
/// resize, an addition and a removal give each shown widget the position and the size the
/// Dashboard shows once the change is made; a change of settings stores no position.
enum DashboardEdits {
    /// `Add Widget`: the widget is appended with the default settings and a new id, at column 0
    /// under every widget, 12 columns wide and `rows` high, the rows its content needs at the cell
    /// size of the window; then it rises by the placement rule.
    static func appending(_ kind: DashboardWidgetKind, rows: Int, to widgets: [DashboardWidget], arrangement: DashboardArrangement,
                          id: UUID = UUID()) -> [DashboardWidget] {
        let shown = arrangement.cells(of: widgets)
        var list = arrangement.storing(shown, in: widgets)
        var widget = DashboardWidget(id: id, kind: kind)
        widget.cells = DashboardCells(column: 0, row: shown.compactMap { $0?.bottom }.max() ?? 0,
                                      width: DashboardGrid.halfWidth, height: max(rows, 1))
        list.append(widget)
        return arrangement.storing(arrangement.cells(of: list), in: list)
    }

    /// The remove button: the other widgets keep the place the Dashboard shows, and those under
    /// the removed widget rise.
    static func removing(_ slot: DashboardSlot, from widgets: [DashboardWidget], arrangement: DashboardArrangement) -> [DashboardWidget]? {
        guard let index = slot.index(in: widgets) else { return nil }
        var list = arrangement.storing(arrangement.cells(of: widgets), in: widgets)
        list.remove(at: index)
        return arrangement.storing(arrangement.cells(of: list), in: list)
    }

    /// A widget moved or resized to `cells`: the placement rule applies to the arrangement the
    /// Dashboard shows, with the widget at these cells and placed before the other widgets that
    /// start on its row. Nil when the arrangement stays as it is.
    static func placing(_ slot: DashboardSlot, at cells: DashboardCells, in widgets: [DashboardWidget],
                        arrangement: DashboardArrangement) -> [DashboardWidget]? {
        guard let index = slot.index(in: widgets) else { return nil }
        let shown = arrangement.cells(of: widgets)
        guard shown[index] != nil else { return nil }
        let placed = DashboardGrid.layout(shown, placing: index, at: cells)
        guard placed != shown else { return nil }
        var list = arrangement.storing(placed, in: widgets)
        // The widget the user placed gets its position whatever is known of its rows.
        list[index].cells = placed[index]
        return list
    }

    /// A change of a widget's settings.
    static func updating(_ slot: DashboardSlot, in widgets: [DashboardWidget],
                         _ update: (inout DashboardWidget) -> Void) -> [DashboardWidget]? {
        guard let index = slot.index(in: widgets) else { return nil }
        var list = widgets
        update(&list[index])
        return list
    }

    /// A checkbox of a group checked or unchecked: the checked values, in the order of the
    /// settings; the last checked value stays checked.
    static func toggling<Value: CaseIterable & Hashable>(_ value: Value, on: Bool, in checked: [Value]) -> [Value] {
        var values = Set(checked)
        if on {
            values.insert(value)
        } else if values != [value] {
            values.remove(value)
        }
        return Value.allCases.filter(values.contains)
    }

    /// Whether the box of a value is the only checked box of its group, which cannot be unchecked.
    static func isLastChecked<Value: Hashable>(_ value: Value, in checked: [Value]) -> Bool {
        Set(checked) == [value]
    }

    /// A click on a checkbox: its value is checked when the newest list does not have it, unchecked
    /// when it does, so that each of several quick clicks applies.
    static func flipping<Value: CaseIterable & Hashable>(_ value: Value, in checked: [Value]) -> [Value] {
        toggling(value, on: !checked.contains(value), in: checked)
    }

    /// A click on the stepper of `Number of chats`: one more or one less than the newest number,
    /// within 1–20.
    static func steppingChatCount(of widget: DashboardWidget, by step: Int) -> Int {
        let range = DashboardWidget.chatCountRange
        return min(max(DashboardContent.chatLimit(of: widget) + step, range.lowerBound), range.upperBound)
    }

    /// A click on the stepper of `Number`: one more or one less than the newest number, within
    /// 1–20.
    static func steppingCount(of widget: DashboardWidget, by step: Int) -> Int {
        let range = DashboardWidget.countRange
        return min(max(DashboardGraph.rowLimit(of: widget) + step, range.lowerBound), range.upperBound)
    }
}

/// Sends the changes of edit mode with `projects.update` one after the other (docs/dashboard.md ›
/// Edit mode). Each change starts from the stored list once the `project.updated` of the previous
/// one has been applied, since a local window may receive the result of a call before its event;
/// it waits at most `eventTimeout` for it. A queued change is sent also when the Dashboard is gone,
/// for example the Title of a popover closed by showing another section.
@MainActor
final class DashboardChanges {
    private var last: Task<Void, Never>?
    let eventTimeout: Duration

    init(eventTimeout: Duration = .seconds(2)) {
        self.eventTimeout = eventTimeout
    }

    /// Makes the new list with `edit` from the stored list and sends it when it differs; `done`
    /// receives the engine's message, or nil. `lists` subscribes to the lists of the project that
    /// the workspace applies from then on.
    func send(stored: @escaping @MainActor () -> [DashboardWidget],
              lists: @escaping @MainActor () -> AsyncStream<[DashboardWidget]>,
              edit: @escaping ([DashboardWidget]) -> [DashboardWidget]?,
              call: @escaping @MainActor ([DashboardWidget]) async throws -> [DashboardWidget],
              done: @escaping @MainActor (String?) -> Void) {
        let previous = last
        let timeout = eventTimeout
        last = Task { @MainActor in
            await previous?.value
            let base = stored()
            guard let list = edit(base), list != base else {
                done(nil)
                return
            }
            let applied = lists()
            do {
                let result = try await call(list)
                if stored() != result {
                    await Self.wait(for: result, in: applied, timeout: timeout)
                }
                done(nil)
            } catch {
                done(errorMessage(error))
            }
        }
    }

    /// Returns once `lists` gives `result`, or after `timeout`.
    private static func wait(for result: [DashboardWidget], in lists: AsyncStream<[DashboardWidget]>, timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await list in lists where list == result {
                    return
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }
}

/// The Dashboard of the shown project: the window's active project, under its title row, or a sub
/// project shown from the sidebar, under a pane header with its name (docs/dashboard.md ›
/// Section).
struct DashboardView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    /// A sub project's Dashboard has a pane header with the project's name in place of the title
    /// row.
    var showsHeader = false

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                // 36 pt like every header of the centre column (docs/ui.md › Pane headers).
                HStack {
                    Text(workspace.project(projectID)?.name ?? "")
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .paneHeaderBar()
                Divider()
            } else {
                // The section's pane header, across the column (docs/ui.md › Pane headers).
                PaneTitleRow(section: .dashboard)
            }
            DashboardSection(window: window, workspace: workspace, projectID: projectID)
        }
        // Edit mode ends when the window shows another project or device, or leaves a sub
        // project's Dashboard (docs/dashboard.md › Edit mode).
        .id("\(workspace.deviceID)/\(projectID)")
    }
}

/// The bar with `Edit`, or `Add Widget` and `Done` in edit mode, over the widgets of the project
/// on their grid (docs/dashboard.md › Layout, Edit mode).
private struct DashboardSection: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    /// The coordinate space of the visible part of the widget area.
    private static let visibleArea = "dashboardVisibleArea"
    /// The margin around the widget area.
    private static let margin: CGFloat = 20

    @State private var editing = false
    /// The engine's message when the last change failed, until the next change.
    @State private var failure: String?
    @State private var changes = DashboardChanges()
    /// The graph of the graph widgets (docs/dashboard.md › Graph widgets).
    @State private var graphFeed = DashboardGraphFeed()
    /// The width of the widget area, which gives the size of the cells, for what happens after
    /// the layout: a drag, an added widget, a removed one. 0 until the area is laid out.
    @State private var areaWidth: CGFloat = 0
    /// The height each widget needs at its width for its title row, its content and its padding:
    /// the rows of a widget without position (docs/dashboard.md › Lists without positions).
    @State private var neededHeights: [DashboardSlot: CGFloat] = [:]
    /// The size of each widget's title row at full width, with its padding: the smallest size of
    /// the widget, known in edit mode.
    @State private var smallestSizes: [DashboardSlot: CGSize] = [:]
    /// The move or the resize in progress.
    @State private var drag: DashboardDrag?
    /// The arrangement of the last move or resize, shown until its change is applied.
    @State private var settling: DashboardSettling?
    @State private var scrollPosition = ScrollPosition()
    /// How far the widget area is scrolled; read when a drag starts and while the Dashboard
    /// scrolls under one, so it is kept outside the view's state.
    @State private var scroll = DashboardScroll()
    /// The width macOS keeps for the scroll bar of the widget area when it always shows scroll
    /// bars; 0 when the scroll bars show over the content.
    @State private var scrollBarWidth = DashboardSection.scrollBarWidth

    private static var scrollBarWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    /// The stored list, or the default list of a project without one (docs/dashboard.md › Widgets).
    private var widgets: [DashboardWidget] {
        workspace.details[projectID]?.project.dashboardWidgetList ?? DashboardWidget.defaultList
    }

    /// Whether the project's graph is enabled: its graph widgets show and are offered
    /// (docs/dashboard.md › Graph widgets).
    private var graphEnabled: Bool {
        workspace.details[projectID]?.graphEnabled == true
    }

    /// Whether the Dashboard shows a graph widget: the `Window` menu shows and the graph is read.
    private var showsGraphWidget: Bool {
        graphEnabled && widgets.contains { $0.kind.isGraph }
    }

    /// The time window of the graph widgets.
    private var graphWindow: GraphWindow {
        workspace.details[projectID]?.project.dashboardGraphWindowValue ?? .hour
    }

    private var metrics: DashboardGridMetrics {
        DashboardGridMetrics(width: areaWidth)
    }

    /// What the arrangement depends on now: the rows each widget needs at the cell size of the
    /// window.
    private func arrangement(_ metrics: DashboardGridMetrics) -> DashboardArrangement {
        DashboardArrangement(graphEnabled: graphEnabled, rows: neededHeights.mapValues { metrics.cells(holding: $0) })
    }

    var body: some View {
        if let project = workspace.project(projectID) {
            VStack(alignment: .leading, spacing: 0) {
                bar(project)
                GeometryReader { area in
                    // The widget area is as wide with its scroll bar as without it: the cells
                    // follow its width, so a bar that took room from it would make the widgets
                    // lower, and come and go without end.
                    let width = max(area.size.width - 2 * Self.margin - scrollBarWidth, 0)
                    ScrollView {
                        grid(project, metrics: DashboardGridMetrics(width: width))
                            .frame(width: width)
                            .padding(Self.margin)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: width, initial: true) {
                        areaWidth = width
                    }
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: DashboardScroll.Metrics.self) { geometry in
                        DashboardScroll.Metrics(offset: geometry.contentOffset.y, visibleHeight: geometry.containerSize.height,
                                                contentHeight: geometry.contentSize.height)
                    } action: { _, metrics in
                        scroll.metrics = metrics
                        // The widget stays under the pointer while the Dashboard scrolls under it.
                        if let drag, drag.offset != metrics.offset {
                            self.drag?.offset = metrics.offset
                        }
                    }
                    .coordinateSpace(.named(Self.visibleArea))
                    .pointerStyle(drag?.kind == .resize ? .frameResize(position: .bottomTrailing) : nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                scrollBarWidth = Self.scrollBarWidth
            }
            .onChange(of: editing) {
                drag = nil
            }
            .onChange(of: DashboardSlot.slots(of: widgets)) { _, slots in
                // The sizes of the widgets that left the list are forgotten.
                let kept = Set(slots)
                neededHeights = neededHeights.filter { kept.contains($0.key) }
                smallestSizes = smallestSizes.filter { kept.contains($0.key) }
                if let drag, !kept.contains(drag.slot) {
                    self.drag = nil
                }
            }
            .task(id: drag != nil) {
                await scrollWhileDragging()
            }
            .task(id: DashboardGraphRead(environment: workspace.details[projectID]?.currentWorkingEnvironment, window: graphWindow,
                                         active: showsGraphWidget)) {
                guard showsGraphWidget, let environment = workspace.details[projectID]?.currentWorkingEnvironment else { return }
                await graphFeed.read(workspace: workspace,
                                     params: GraphRead.Params(projectID: projectID, environment: environment.name, window: graphWindow))
            }
        }
    }

    private func bar(_ project: ProjectSummary) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if showsGraphWidget {
                    // The window of the graph widgets, stored in the project file.
                    Picker("Window", selection: Binding(get: { graphWindow }, set: { applyGraphWindow($0) })) {
                        ForEach(GraphWindow.allCases) { window in
                            Text(window.label).tag(window)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if editing {
                    Menu("Add Widget") {
                        ForEach(DashboardWidgetKind.addable(for: project.type, graphEnabled: graphEnabled), id: \.self) { kind in
                            Button(kind.title) {
                                add(kind, project)
                            }
                        }
                    }
                    .fixedSize()
                }
                Button(editing ? "Done" : "Edit") {
                    editing.toggle()
                }
            }
            FieldMessage(text: failure)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// The cells the Dashboard shows for each widget of the list, nil for a hidden graph widget:
    /// their placement, or the arrangement of the last move or resize until its change is applied.
    private func shownCells(of list: [DashboardWidget], arrangement: DashboardArrangement) -> [DashboardCells?] {
        var cells = arrangement.cells(of: list)
        if let settling {
            for (index, slot) in DashboardSlot.slots(of: list).enumerated() where cells[index] != nil {
                cells[index] = settling.cells[slot] ?? cells[index]
            }
        }
        return cells
    }

    /// The arrangement while a widget is moved or resized: the frame at which the widget follows
    /// the pointer, the cells it asks for, and the cells of every widget once the others have made
    /// room. Nil when the widget is no longer shown.
    private func live(_ drag: DashboardDrag, in list: [DashboardWidget], metrics: DashboardGridMetrics) -> DashboardLive? {
        let shown = shownCells(of: list, arrangement: drag.arrangement)
        guard let index = drag.slot.index(in: list), let start = shown[index] else { return nil }
        let smallest = smallestSizes[drag.slot].map(metrics.smallestSize(titleRow:)) ?? DashboardSmallestSize()
        let target = drag.target(from: start, metrics: metrics, smallest: smallest)
        return DashboardLive(index: index, frame: target.frame, target: target.cells, shown: shown,
                             cells: DashboardGrid.layout(shown, placing: index, at: target.cells))
    }

    private func grid(_ project: ProjectSummary, metrics: DashboardGridMetrics) -> some View {
        let list = widgets
        let slots = DashboardSlot.slots(of: list)
        let live = drag.flatMap { self.live($0, in: list, metrics: metrics) }
        let cells = live?.cells ?? shownCells(of: list, arrangement: arrangement(metrics))
        // The graph widgets are hidden while the graph is not enabled, and kept in the list.
        let items = list.indices.compactMap { index in
            cells[index].map { DashboardItem(slot: slots[index], widget: list[index], cells: $0) }
        }
        return DashboardGridLayout {
            if let live, let placeholder = live.cells[live.index] {
                // The cells where the moved or resized widget will land.
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .dashboardFrame(.cells(placeholder))
                    .zIndex(1)
                    .allowsHitTesting(false)
            }
            ForEach(items, id: \.slot) { item in
                let floats = live.map { slots[$0.index] == item.slot } ?? false
                card(item, project)
                    // The widget that follows the pointer hides the widgets under it; the fill of
                    // a widget alone would let them show through.
                    .background {
                        if floats {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    .dashboardFrame(floats ? .floating(live?.frame ?? .zero) : .cells(item.cells))
                    .zIndex(floats ? 2 : 0)
                    // A widget without position shows once the rows it needs are known.
                    .opacity(item.widget.cells != nil || neededHeights[item.slot] != nil || settling?.cells[item.slot] != nil ? 1 : 0)
            }
        }
    }

    private func card(_ item: DashboardItem, _ project: ProjectSummary) -> some View {
        let slot = item.slot
        return DashboardWidgetCard(window: window, workspace: workspace, project: project, widget: item.widget,
                                   graphFeed: graphFeed, editing: editing,
                                   remove: {
                                       let arrangement = arrangement(metrics)
                                       change { DashboardEdits.removing(slot, from: $0, arrangement: arrangement) }
                                   },
                                   change: { update in
                                       change { DashboardEdits.updating(slot, in: $0, update) }
                                   },
                                   measured: { height in
                                       // Also during a drag, which keeps the rows it started
                                       // with: a height that changed meanwhile counts once the
                                       // widget is released.
                                       if neededHeights[slot] != height {
                                           neededHeights[slot] = height
                                       }
                                   },
                                   measuredSmallest: { size in
                                       if smallestSizes[slot] != size {
                                           smallestSizes[slot] = size
                                       }
                                   })
            .overlay(alignment: .bottomTrailing) {
                if editing {
                    DashboardResizeHandle()
                        .gesture(dragGesture(slot, .resize))
                }
            }
            .gesture(dragGesture(slot, .move), isEnabled: editing)
    }

    /// The drag that moves a widget, or resizes it by its handle: the widget follows the pointer
    /// from the place it had, and releasing it applies the arrangement.
    private func dragGesture(_ slot: DashboardSlot, _ kind: DashboardDrag.Kind) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.visibleArea))
            .onChanged { value in
                if drag?.slot == slot, drag?.kind == kind {
                    drag?.location = value.location
                } else {
                    drag = DashboardDrag(slot: slot, kind: kind, start: value.startLocation, location: value.location,
                                         startOffset: scroll.metrics.offset, offset: scroll.metrics.offset,
                                         arrangement: arrangement(metrics))
                }
            }
            .onEnded { value in
                guard var ended = drag, ended.slot == slot, ended.kind == kind else { return }
                ended.location = value.location
                drag = nil
                apply(ended)
            }
    }

    /// Applies the arrangement of a released move or resize; nothing is sent when no widget
    /// changed place or size. The Dashboard keeps showing the arrangement until the change is
    /// applied, so the widgets do not go back to their stored places meanwhile.
    private func apply(_ drag: DashboardDrag) {
        let list = widgets
        guard let live = live(drag, in: list, metrics: metrics), live.cells != live.shown else { return }
        let id = UUID()
        let cells = zip(DashboardSlot.slots(of: list), live.cells).compactMap { slot, cells in cells.map { (slot, $0) } }
        settling = DashboardSettling(id: id, cells: Dictionary(cells, uniquingKeysWith: { first, _ in first }))
        let slot = drag.slot
        let target = live.target
        let arrangement = drag.arrangement
        change(settling: id) { DashboardEdits.placing(slot, at: target, in: $0, arrangement: arrangement) }
    }

    /// `Add Widget`: the widget gets the rows its content needs at the cell size of this window.
    private func add(_ kind: DashboardWidgetKind, _ project: ProjectSummary) {
        let metrics = metrics
        let arrangement = arrangement(metrics)
        let height = DashboardWidgetCard.neededHeight(of: DashboardWidget(kind: kind), width: metrics.length(DashboardGrid.halfWidth),
                                                      window: window, workspace: workspace, project: project, graphFeed: graphFeed)
        let rows = metrics.cells(holding: height)
        change { DashboardEdits.appending(kind, rows: rows, to: $0, arrangement: arrangement) }
    }

    /// Scrolls the Dashboard while a widget is moved or resized with the pointer near the top or
    /// the bottom edge of the visible area, until the drag ends.
    private func scrollWhileDragging() async {
        guard drag != nil else { return }
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            let now = clock.now
            let elapsed = now - last
            last = now
            guard let drag else { return }
            let metrics = scroll.metrics
            let velocity = DashboardAutoScroll.velocity(pointer: drag.location.y, visibleHeight: metrics.visibleHeight)
            guard velocity != 0 else { continue }
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let target = min(max(metrics.offset + velocity * seconds, 0), max(metrics.contentHeight - metrics.visibleHeight, 0))
            if abs(target - metrics.offset) >= 0.5 {
                scrollPosition.scrollTo(y: target)
            }
        }
    }

    /// Applies a window of the `Window` menu; the engine's message shows under the bar when it
    /// fails, until the next change.
    private func applyGraphWindow(_ window: GraphWindow) {
        guard window != graphWindow else { return }
        let workspace = workspace
        let projectID = projectID
        Task {
            do {
                _ = try await workspace.call(ProjectsUpdate.self, ProjectsUpdate.Params(projectID: projectID, dashboardGraphWindow: .set(window)))
                failure = nil
            } catch {
                failure = errorMessage(error)
            }
        }
    }

    /// Sends a change; the engine's message shows under the bar when it fails, until the next
    /// change. `settling` names the arrangement the Dashboard shows until this change is applied.
    private func change(settling id: UUID? = nil, _ edit: @escaping ([DashboardWidget]) -> [DashboardWidget]?) {
        let workspace = workspace
        let projectID = projectID
        changes.send(stored: { workspace.details[projectID]?.project.dashboardWidgetList ?? DashboardWidget.defaultList },
                     lists: {
                         let events = workspace.events()
                         return AsyncStream { continuation in
                             let task = Task { @MainActor in
                                 for await event in events {
                                     if case .projectUpdated(let detail) = event.event, detail.project.id == projectID {
                                         continuation.yield(detail.project.dashboardWidgetList)
                                     }
                                 }
                                 continuation.finish()
                             }
                             continuation.onTermination = { _ in
                                 task.cancel()
                             }
                         }
                     },
                     edit: edit,
                     call: { list in
                         let detail = try await workspace.call(ProjectsUpdate.self,
                                                               ProjectsUpdate.Params(projectID: projectID, dashboardWidgets: list))
                         return detail.project.dashboardWidgetList
                     },
                     done: { message in
                         failure = message
                         if let id, settling?.id == id {
                             settling = nil
                         }
                     })
    }
}

/// How far the widget area of a Dashboard is scrolled. A reference, so that reading it during a
/// drag does not make the Dashboard draw again at each scroll.
@MainActor
private final class DashboardScroll {
    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var visibleHeight: CGFloat = 0
        var contentHeight: CGFloat = 0
    }

    var metrics = Metrics()
}

/// The arrangement of a released move or resize, by widget, shown until its change is applied.
private struct DashboardSettling: Equatable {
    var id: UUID
    var cells: [DashboardSlot: DashboardCells]
}

/// The arrangement while a widget is moved or resized.
private struct DashboardLive {
    /// The index of the widget in the list.
    var index: Int
    /// The frame at which the widget follows the pointer.
    var frame: CGRect
    /// The cells the widget asks for.
    var target: DashboardCells
    /// The cells of every widget when the drag started, and once the others have made room.
    var shown: [DashboardCells?]
    var cells: [DashboardCells?]
}

/// What makes the Dashboard read the graph of its graph widgets again.
private struct DashboardGraphRead: Hashable {
    var environment: ProjectEnvironment?
    var window: GraphWindow
    var active: Bool
}

/// A shown widget with its slot and the cells it covers.
private struct DashboardItem {
    var slot: DashboardSlot
    var widget: DashboardWidget
    var cells: DashboardCells
}

/// One widget: its title row, with the remove and settings buttons in edit mode, over its content,
/// which scrolls inside the widget when it does not fit (docs/dashboard.md › Content, Widgets,
/// Edit mode).
struct DashboardWidgetCard: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary
    let widget: DashboardWidget
    let graphFeed: DashboardGraphFeed
    let editing: Bool
    let remove: () -> Void
    /// Sends a change of the widget's settings.
    let change: (@escaping (inout DashboardWidget) -> Void) -> Void
    /// Receives the height the widget needs at its width for its title row, its content and its
    /// padding.
    let measured: (CGFloat) -> Void
    /// Receives the size of the title row at full width in edit mode, with the padding: the
    /// smallest size of the widget.
    let measuredSmallest: (CGSize) -> Void

    /// The space between the title row and the content.
    static let spacing: CGFloat = 8

    @State private var titleHeight: CGFloat?
    @State private var contentHeight: CGFloat?

    private var neededHeight: CGFloat? {
        guard let titleHeight, let contentHeight else { return nil }
        return 2 * DashboardGridMetrics.padding + titleHeight + Self.spacing + contentHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            DashboardWidgetTitleRow(widget: widget, editing: editing, remove: remove, change: change)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { titleHeight = $0 }
            DashboardWidgetScroll(measured: { contentHeight = $0 }) {
                DashboardWidgetContent(window: window, workspace: workspace, project: project, widget: widget,
                                       graphFeed: graphFeed, editing: editing)
            }
            // In edit mode a drag starts anywhere in the widget: its content takes no click and
            // no scroll, so Recent Chats rows open no chat.
            .allowsHitTesting(!editing)
        }
        .padding(DashboardGridMetrics.padding)
        // With a minimum as well as a maximum, the frame has the size of the widget's cells also
        // when the title row and the padding need more, and what does not fit is cut: nothing is
        // drawn outside a widget.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.fill.secondary))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .background {
            if editing {
                // The title row at full width, which gives the smallest size of the widget.
                DashboardWidgetTitleRow(widget: widget, editing: true)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                        measuredSmallest(CGSize(width: size.width + 2 * DashboardGridMetrics.padding,
                                                height: size.height + 2 * DashboardGridMetrics.padding))
                    }
            }
        }
        .onChange(of: neededHeight, initial: true) { _, height in
            if let height {
                measured(height)
            }
        }
    }

    /// The height a widget needs at a width for its title row, its content and its padding, for a
    /// widget that is not in the list yet: `Add Widget` gives it the rows that hold it.
    @MainActor
    static func neededHeight(of widget: DashboardWidget, width: CGFloat, window: WindowState, workspace: DeviceWorkspace,
                             project: ProjectSummary, graphFeed: DashboardGraphFeed) -> CGFloat {
        let view = VStack(alignment: .leading, spacing: spacing) {
            DashboardWidgetTitleRow(widget: widget, editing: true)
            DashboardWidgetContent(window: window, workspace: workspace, project: project, widget: widget,
                                   graphFeed: graphFeed, editing: true)
        }
        .padding(DashboardGridMetrics.padding)
        .frame(width: width)
        return NSHostingView(rootView: view).fittingSize.height
    }
}

/// The title row of a widget: its title and, in edit mode, the remove button at its start and the
/// settings button at its end (docs/dashboard.md › Edit mode).
private struct DashboardWidgetTitleRow: View {
    let widget: DashboardWidget
    let editing: Bool
    var remove: () -> Void = {}
    /// Sends a change of the widget's settings.
    var change: (@escaping (inout DashboardWidget) -> Void) -> Void = { _ in }

    @State private var showsSettings = false

    var body: some View {
        ZStack(alignment: .leading) {
            // The row is as high without its buttons as with them, so the rows a widget needs
            // are the same in and out of edit mode.
            Image(systemName: "minus.circle.fill")
                .hidden()
            Image(systemName: "slider.horizontal.3")
                .hidden()
            HStack(spacing: 6) {
                if editing {
                    Button(action: remove) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove Widget")
                    .accessibilityLabel("Remove Widget")
                }
                Text(DashboardContent.title(of: widget))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if editing {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    .help("Widget Settings")
                    .accessibilityLabel("Widget Settings")
                    .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                        DashboardWidgetSettings(widget: widget, change: change)
                    }
                }
            }
        }
        .onChange(of: editing) { _, isEditing in
            if !isEditing {
                showsSettings = false
            }
        }
    }
}

/// What a widget shows under its title row (docs/dashboard.md › Widgets). The content keeps the
/// height it needs at the width it gets, so that it scrolls when the widget is lower; only the
/// map of a Service graph widget and the chart of a Requests per minute widget fill the widget.
private struct DashboardWidgetContent: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary
    let widget: DashboardWidget
    let graphFeed: DashboardGraphFeed
    let editing: Bool

    var body: some View {
        switch widget.kind {
        case .project:
            projectContent
                .fixedSize(horizontal: false, vertical: true)
        case .tickets:
            ticketsContent
                .fixedSize(horizontal: false, vertical: true)
        case .recentChats:
            recentChatsContent
                .fixedSize(horizontal: false, vertical: true)
        case .cost:
            costContent
                .fixedSize(horizontal: false, vertical: true)
        case .instances:
            InstancesWidgetContent(window: window, workspace: workspace, projectID: project.id)
                .fixedSize(horizontal: false, vertical: true)
        case .busiestCalls, .failedRequests:
            DashboardGraphWidgetContent(window: window, workspace: workspace, project: project, widget: widget, feed: graphFeed,
                                        editing: editing)
                .fixedSize(horizontal: false, vertical: true)
        case .serviceGraph, .requestsPerMinute:
            DashboardGraphWidgetContent(window: window, workspace: workspace, project: project, widget: widget, feed: graphFeed,
                                        editing: editing)
        }
    }

    private var projectContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(DashboardContent.fields(of: widget), id: \.self) { field in
                switch field {
                case .name:
                    Text(project.name)
                        .font(.title2.weight(.semibold))
                case .identifier:
                    Text(project.id)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                case .type:
                    Text("Type: \(project.type.label)")
                case .folder:
                    Text(project.rootPath)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var ticketsContent: some View {
        let statuses = DashboardContent.statuses(of: widget)
        let counts = DashboardContent.ticketCounts(of: project, widget: widget)
        return VStack(alignment: .leading, spacing: 8) {
            if !statuses.isEmpty {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(statuses, id: \.self) { status in
                        count(DashboardContent.count(status, in: counts), status.label)
                    }
                }
                // The counts are never truncated or wrapped: a narrower widget scrolls them.
                .fixedSize()
            }
            if widget.includeSubprojects {
                Text("Sub projects included")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(value))
                .font(.title.weight(.semibold).monospacedDigit())
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    private var recentChatsContent: some View {
        let chats = DashboardContent.recentChats(of: project.id, in: Array(workspace.chats.values), widget: widget)
        return VStack(alignment: .leading, spacing: 8) {
            if chats.isEmpty {
                Text("No chats yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(chats) { chat in
                Button {
                    guard !editing else { return }
                    Task {
                        await window.navigate(to: .chat(chatID: chat.id))
                    }
                } label: {
                    HStack(spacing: 8) {
                        ChatStateMark(state: chat.state)
                            .frame(width: 12)
                        Text(chat.title)
                            .lineLimit(1)
                        Text(CostBreakdown.kind(chat.kind, ticketID: chat.ticketID, bundleID: chat.bundleID))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(ChatsSectionView.relative(chat.updated, now: context.date))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var costContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CostBreakdown.amount(DashboardContent.costUSD(of: project, widget: widget)))
                .font(.title.weight(.semibold).monospacedDigit())
                // The total is never truncated or wrapped: a narrower widget scrolls it.
                .fixedSize()
            if widget.includeSubprojects {
                Text("Sub projects included")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The pods of the project's current working environment, read with `kubernetes.pods` when the
/// widget appears, 10 seconds after the end of each read, and at once when the environment or its
/// fields change (docs/dashboard.md › Instances widget, Live updates).
private struct InstancesWidgetContent: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    /// The pods of the last read that succeeded; nil until the first read of the environment ends.
    @State private var pods: [PodStatus]?
    /// The engine's message when the last read failed, until a read succeeds.
    @State private var failure: String?

    var body: some View {
        if let environment = workspace.details[projectID]?.currentWorkingEnvironment {
            if environment.deployment == nil {
                Text(KubernetesPods.noDeploymentMessage(environment: environment.name))
                    .foregroundStyle(.secondary)
            } else {
                readContent
                    .task(id: environment) {
                        await read(environment)
                    }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(DashboardInstances.noEnvironmentMessage)
                    .foregroundStyle(.secondary)
                Button("Project Settings…") {
                    window.section = .settings
                }
            }
        }
    }

    @ViewBuilder
    private var readContent: some View {
        if let failure {
            FieldMessage(text: failure)
        } else if let pods {
            table(pods)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func table(_ pods: [PodStatus]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(DashboardInstances.headers, id: \.self) { header in
                    Text(header)
                }
            }
            .foregroundStyle(.secondary)
            ForEach(pods, id: \.name) { pod in
                GridRow {
                    Text(pod.name)
                        .truncationMode(.middle)
                    Text(DashboardInstances.ready(pod))
                        .monospacedDigit()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Self.color(DashboardInstances.dot(pod)))
                            .frame(width: 8, height: 8)
                        Text(pod.status)
                    }
                    Text(String(pod.restarts))
                        .monospacedDigit()
                    Text(pod.age)
                        .monospacedDigit()
                    Text(pod.node ?? "")
                }
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    static func color(_ dot: DashboardInstances.Dot) -> Color {
        switch dot {
        case .green: return Color(nsColor: .systemGreen)
        case .orange: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        case .gray: return Color(nsColor: .systemGray)
        }
    }

    /// Reads the pods of `environment` until the task is cancelled: the widget goes away, or the
    /// environment or its fields change, which starts over with the spinner.
    private func read(_ environment: ProjectEnvironment) async {
        pods = nil
        failure = nil
        let params = KubernetesPods.Params(projectID: projectID, environment: environment.name)
        while !Task.isCancelled {
            do {
                let result = try await workspace.call(KubernetesPods.self, params)
                guard !Task.isCancelled else { return }
                pods = result
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                failure = errorMessage(error)
            }
            try? await Task.sleep(for: DashboardInstances.interval)
        }
    }
}

/// The settings popover of a widget: each change applies at once (docs/dashboard.md › Settings).
private struct DashboardWidgetSettings: View {
    let widget: DashboardWidget
    let change: (@escaping (inout DashboardWidget) -> Void) -> Void

    @State private var title = ""
    /// The stored title the field last took: the field applies only a text the user changed.
    @State private var shownTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Title")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title", text: $title, prompt: Text(widget.kind.title))
                        .labelsHidden()
                        .frame(width: 220)
                        .focused($titleFocused)
                        .onSubmit(commitTitle)
                        .onChange(of: titleFocused) { _, isFocused in
                            if !isFocused {
                                commitTitle()
                            }
                        }
                    FieldMessage(text: titleMessage)
                }
            }
            switch widget.kind {
            case .project:
                GridRow {
                    Text("Fields")
                    CheckboxGroup(checked: widget.fields, label: \.label) { field in
                        send { $0.fields = DashboardEdits.flipping(field, in: $0.fields) }
                    }
                }
            case .tickets:
                GridRow {
                    Text("Statuses")
                    CheckboxGroup(checked: widget.statuses, label: \.label) { status in
                        send { $0.statuses = DashboardEdits.flipping(status, in: $0.statuses) }
                    }
                }
                includeSubprojectsRow
            case .recentChats:
                GridRow {
                    Text("Number of chats")
                    chatCountStepper
                }
                GridRow {
                    Text("Chat kinds")
                    CheckboxGroup(checked: widget.chatKinds, choices: DashboardWidget.chatKindChoices, label: DashboardContent.label(of:)) { kind in
                        send { $0.chatKinds = DashboardEdits.flipping(kind, in: $0.chatKinds) }
                    }
                }
            case .cost:
                includeSubprojectsRow
            case .busiestCalls, .failedRequests:
                GridRow {
                    Text("Number")
                    countStepper
                }
            case .instances, .serviceGraph, .requestsPerMinute:
                // The Title setting only.
                EmptyView()
            }
        }
        .padding(16)
        .onAppear {
            title = widget.title
            shownTitle = widget.title
        }
        .onChange(of: widget.title) { _, stored in
            // A title changed elsewhere replaces the text unless the user changed it.
            if title == shownTitle {
                title = stored
            }
            shownTitle = stored
        }
        .onDisappear(perform: commitTitle)
    }

    /// The number, then the stepper; each click steps from the newest number, so that each of
    /// several quick clicks applies.
    private var chatCountStepper: some View {
        let count = DashboardContent.chatLimit(of: widget)
        let range = DashboardWidget.chatCountRange
        return HStack(spacing: 6) {
            Text(String(count))
                .monospacedDigit()
            Stepper("Number of chats",
                    onIncrement: count < range.upperBound ? { send { $0.chatCount = DashboardEdits.steppingChatCount(of: $0, by: 1) } } : nil,
                    onDecrement: count > range.lowerBound ? { send { $0.chatCount = DashboardEdits.steppingChatCount(of: $0, by: -1) } } : nil)
                .labelsHidden()
        }
    }

    /// The number, then the stepper of the `Number` setting, 1 to 20 (docs/dashboard.md › Settings).
    private var countStepper: some View {
        let count = DashboardGraph.rowLimit(of: widget)
        let range = DashboardWidget.countRange
        return HStack(spacing: 6) {
            Text(String(count))
                .monospacedDigit()
            Stepper("Number",
                    onIncrement: count < range.upperBound ? { send { $0.count = DashboardEdits.steppingCount(of: $0, by: 1) } } : nil,
                    onDecrement: count > range.lowerBound ? { send { $0.count = DashboardEdits.steppingCount(of: $0, by: -1) } } : nil)
                .labelsHidden()
        }
    }

    private var includeSubprojectsRow: some View {
        GridRow {
            Color.clear
                .gridCellUnsizedAxes([.horizontal, .vertical])
            // A click flips the newest value, so that each of several quick clicks applies.
            Toggle("Include sub projects", isOn: Binding(get: { widget.includeSubprojects },
                                                         set: { _ in send { $0.includeSubprojects.toggle() } }))
                .toggleStyle(.checkbox)
        }
    }

    /// `Enter a title of at most 100 characters.` while the typed title breaks the rule.
    private var titleMessage: String? {
        let rule = ValidationError.invalid("title", "")
        let valid = (try? ModelRules.singleLine(title, field: "title", length: 0...DashboardWidget.titleLimit, error: rule)) != nil
        return valid ? nil : "Enter a title of at most \(DashboardWidget.titleLimit) characters."
    }

    /// The Title applies on Return, when the field loses the focus and when the popover closes,
    /// when the user changed its text.
    private func commitTitle() {
        guard title != shownTitle, titleMessage == nil else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        shownTitle = title
        guard trimmed != widget.title else { return }
        send { $0.title = trimmed }
    }

    private func send(_ update: @escaping (inout DashboardWidget) -> Void) {
        change(update)
    }
}

/// The checkboxes of a group of values, in the order of the settings; the last checked box is
/// disabled (docs/dashboard.md › Settings). `click` receives the value of the clicked box.
private struct CheckboxGroup<Value: CaseIterable & Hashable>: View {
    let checked: [Value]
    /// The boxes, in this order.
    var choices = Array(Value.allCases)
    let label: (Value) -> String
    let click: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(choices, id: \.self) { value in
                Toggle(label(value), isOn: Binding(get: { checked.contains(value) }, set: { _ in click(value) }))
                    .toggleStyle(.checkbox)
                    .disabled(DashboardEdits.isLastChecked(value, in: checked))
            }
        }
    }
}
