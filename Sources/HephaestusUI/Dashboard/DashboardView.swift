// OWNER: ui-shell — the Dashboard section (docs/dashboard.md).
import AppKit
import HephaestusCore
import SwiftUI
import UniformTypeIdentifiers

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

/// The changes of edit mode, each a new list made from the newest one; nil when the widget it
/// applies to is no longer in the list (docs/dashboard.md › Edit mode, Settings).
enum DashboardEdits {
    /// `Add Widget`: the widget is appended with the default settings and a new id.
    static func appending(_ kind: DashboardWidgetKind, to widgets: [DashboardWidget], id: UUID = UUID()) -> [DashboardWidget] {
        widgets + [DashboardWidget(id: id, kind: kind)]
    }

    static func removing(_ slot: DashboardSlot, from widgets: [DashboardWidget]) -> [DashboardWidget]? {
        guard let index = slot.index(in: widgets) else { return nil }
        var list = widgets
        list.remove(at: index)
        return list
    }

    /// A widget dropped on another takes that widget's place; the widgets between them move by one
    /// place.
    static func moving(_ source: DashboardSlot, onto target: DashboardSlot, in widgets: [DashboardWidget]) -> [DashboardWidget]? {
        guard source != target, let from = source.index(in: widgets), let to = target.index(in: widgets) else { return nil }
        var list = widgets
        list.insert(list.remove(at: from), at: to)
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
}

/// The text a dragged widget carries: the token of the Dashboard that drags it and its slot, so
/// that a drop moves it only within the Dashboard it comes from.
enum DashboardDrag {
    static let prefix = "hephaestus-dashboard-widget:"

    static func payload(token: UUID, slot: DashboardSlot) -> String {
        "\(prefix)\(token.uuidString)/\(slot.id.uuidString)/\(slot.occurrence)"
    }

    /// The slot of a payload of the Dashboard with this token; nil for any other text.
    static func slot(from text: String, token: UUID) -> DashboardSlot? {
        guard text.hasPrefix(prefix) else { return nil }
        let parts = text.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, UUID(uuidString: String(parts[0])) == token,
              let id = UUID(uuidString: String(parts[1])), let occurrence = Int(parts[2]) else { return nil }
        return DashboardSlot(id: id, occurrence: occurrence)
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

/// The Dashboard of the window's active project (docs/dashboard.md).
struct DashboardView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        DashboardSection(window: window, workspace: workspace, projectID: projectID)
            // Edit mode ends when the window shows another project or device (docs/dashboard.md ›
            // Edit mode).
            .id("\(workspace.deviceID)/\(projectID)")
    }
}

/// The bar with `Edit`, or `Add Widget` and `Done` in edit mode, over the widgets of the project.
private struct DashboardSection: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    @State private var editing = false
    /// The engine's message when the last change failed, until the next change.
    @State private var failure: String?
    @State private var changes = DashboardChanges()
    /// The token of the widgets this Dashboard drags (docs/dashboard.md › Edit mode).
    @State private var dragToken = UUID()
    /// The widget this Dashboard is dragging, which its drops accept.
    @State private var dragging: DashboardSlot?
    /// The widget a dragged widget is over.
    @State private var dropTarget: DashboardSlot?

    /// The stored list, or the default list of a project without one (docs/dashboard.md › Widgets).
    private var widgets: [DashboardWidget] {
        workspace.details[projectID]?.project.dashboardWidgetList ?? DashboardWidget.defaultList
    }

    var body: some View {
        if let project = workspace.project(projectID) {
            VStack(alignment: .leading, spacing: 0) {
                bar
                ScrollView {
                    grid(project)
                        .padding(20)
                }
            }
            .onChange(of: editing) {
                dragging = nil
            }
        }
    }

    private var bar: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if editing {
                    Menu("Add Widget") {
                        ForEach(DashboardWidgetKind.allCases, id: \.self) { kind in
                            Button(kind.title) {
                                change { DashboardEdits.appending(kind, to: $0) }
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

    @ViewBuilder
    private func grid(_ project: ProjectSummary) -> some View {
        let list = widgets
        let items = zip(DashboardSlot.slots(of: list), list).map { DashboardItem(slot: $0, widget: $1) }
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        // Two columns when both fit at 320 points or more, one column otherwise.
        ViewThatFits(in: .horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach(rows.indices, id: \.self) { index in
                    GridRow {
                        ForEach(rows[index], id: \.slot) { item in
                            card(item, project)
                        }
                        if rows[index].count == 1 {
                            // The empty cell keeps the last widget of an odd list in the first column.
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
            }
            .frame(minWidth: 656)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(items, id: \.slot) { item in
                    card(item, project)
                }
            }
        }
    }

    private func card(_ item: DashboardItem, _ project: ProjectSummary) -> some View {
        let slot = item.slot
        return DashboardWidgetCard(window: window, workspace: workspace, project: project, widget: item.widget,
                                   editing: editing, isDropTarget: editing && dropTarget == slot,
                                   remove: {
                                       change { DashboardEdits.removing(slot, from: $0) }
                                   },
                                   change: { update in
                                       change { DashboardEdits.updating(slot, in: $0, update) }
                                   })
            .modifier(WidgetDragging(enabled: editing,
                                     payload: DashboardDrag.payload(token: dragToken, slot: slot),
                                     target: slot, dragging: $dragging, dropTarget: $dropTarget,
                                     source: { [dragToken] in DashboardDrag.slot(from: $0, token: dragToken) },
                                     move: { source in
                                         change { DashboardEdits.moving(source, onto: slot, in: $0) }
                                     }))
    }

    /// Sends a change; the engine's message shows under the bar when it fails, until the next
    /// change.
    private func change(_ edit: @escaping ([DashboardWidget]) -> [DashboardWidget]?) {
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
                     })
    }
}

/// A widget with its slot, for the layouts.
private struct DashboardItem {
    var slot: DashboardSlot
    var widget: DashboardWidget
}

/// One widget: its title row, with the remove and settings buttons in edit mode, over its content
/// (docs/dashboard.md › Widgets, Edit mode).
private struct DashboardWidgetCard: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary
    let widget: DashboardWidget
    let editing: Bool
    let isDropTarget: Bool
    let remove: () -> Void
    /// Sends a change of the widget's settings.
    let change: (@escaping (inout DashboardWidget) -> Void) -> Void

    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            content
                // In edit mode a drag starts anywhere in the widget, and Recent Chats rows open no chat.
                .allowsHitTesting(!editing)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.fill.secondary))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: editing) { _, isEditing in
            if !isEditing {
                showsSettings = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch widget.kind {
        case .project: projectContent
        case .tickets: ticketsContent
        case .recentChats: recentChatsContent
        case .cost: costContent
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
            if widget.includeSubprojects {
                Text("Sub projects included")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// In edit mode a widget can be dragged, and a widget dropped on it takes its place
/// (docs/dashboard.md › Edit mode).
private struct WidgetDragging: ViewModifier {
    let enabled: Bool
    let payload: String
    let target: DashboardSlot
    @Binding var dragging: DashboardSlot?
    @Binding var dropTarget: DashboardSlot?
    /// The slot of a dropped text that a widget of this Dashboard carries.
    let source: (String) -> DashboardSlot?
    let move: (DashboardSlot) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    dragging = target
                    return NSItemProvider(object: payload as NSString)
                }
                .onDrop(of: [.plainText], delegate: WidgetDropDelegate(target: target, dragging: $dragging, dropTarget: $dropTarget,
                                                                      source: source, move: move))
        } else {
            content
        }
    }
}

/// A drop on a widget: only a widget this Dashboard drags is accepted, then moved when the dropped
/// text names a widget of this Dashboard, so that other text dropped on a widget does nothing.
private struct WidgetDropDelegate: DropDelegate {
    let target: DashboardSlot
    @Binding var dragging: DashboardSlot?
    @Binding var dropTarget: DashboardSlot?
    let source: (String) -> DashboardSlot?
    let move: (DashboardSlot) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        dropTarget = target
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target {
            dropTarget = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        dragging = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let target = target
        let source = source
        let move = move
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            Task { @MainActor in
                if let dragged = source(text), dragged != target {
                    move(dragged)
                }
            }
        }
        return true
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
