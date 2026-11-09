// OWNER: ui-graph — the Graph section (docs/graph.md).
import AppKit
import HephaestusCore
import SwiftUI

/// The Graph of the active project: its pane header with the namespace and the status line, the
/// controls bar, the graph, the requests of the window and the request chosen (docs/graph.md ›
/// Layout). It reads the graph with `graph.read` when it appears, 5 seconds after the end of each
/// read, and at once when the window or the current working environment changes.
struct GraphSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        if let detail = workspace.details[projectID] {
            if let environment = detail.currentWorkingEnvironment {
                if let state = window.graphState(of: projectID) {
                    GraphSectionContent(workspace: workspace, projectID: projectID, environment: environment,
                                        ownService: Self.ownService(of: detail), state: state)
                } else {
                    Color.clear
                        .onAppear { _ = window.ensureGraphState(of: projectID) }
                }
            } else {
                VStack(spacing: 10) {
                    Text(DashboardInstances.noEnvironmentMessage)
                        .foregroundStyle(.secondary)
                    Button("Project Settings…") {
                        window.section = .settings
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            LoadingStateView(text: "Loading \(workspace.project(projectID)?.name ?? projectID)…")
                .onAppear {
                    workspace.ensureProjectLoaded(projectID)
                }
        }
    }

    /// The service a sub project's Graph opens focused on: the last component of its folder; nil
    /// for a top-level project (docs/graph.md › Sub projects).
    static func ownService(of detail: ProjectDetail) -> String? {
        guard detail.parentID != nil else { return nil }
        return URL(fileURLWithPath: detail.rootPath).lastPathComponent
    }
}

extension WindowState {
    /// The state of the Graph section of a project in this window; nil until the section first
    /// shows.
    func graphState(of projectID: String) -> GraphSectionState? {
        projectStates[ProjectKey(deviceID: deviceID, projectID: projectID)]?.graphState
    }

    /// The state of the Graph section of a project in this window, created when it has none.
    func ensureGraphState(of projectID: String) -> GraphSectionState {
        if let state = graphState(of: projectID) {
            return state
        }
        let state = GraphSectionState()
        updateViewState(of: projectID) { $0.graphState = state }
        return state
    }

    /// True while the active project's sidebar shows the Graph row: View ▸ Graph is enabled
    /// (docs/graph.md › Enabling).
    var showsGraph: Bool {
        guard let projectID, let workspace else { return false }
        return workspace.details[projectID]?.graphEnabled == true
    }

    /// Selects Dashboard when the section is the Graph of a loaded project whose graph is not
    /// enabled (docs/graph.md › Enabling).
    func leaveHiddenGraph(in workspace: DeviceWorkspace) {
        guard section == .graph, workspace.deviceID == deviceID, let projectID,
              let detail = workspace.details[projectID], !detail.graphEnabled else { return }
        section = .dashboard
    }
}

/// What makes the section read the graph again at once.
private struct GraphReadKey: Hashable {
    var environment: ProjectEnvironment
    var window: GraphWindow
}

/// What makes the section read the request chosen again: another request, or a new read.
private struct GraphDetailKey: Hashable {
    var requestID: String?
    var readAt: Date?
}

private struct GraphSectionContent: View {
    let workspace: DeviceWorkspace
    let projectID: String
    let environment: ProjectEnvironment
    let ownService: String?
    @Bindable var state: GraphSectionState
    /// The height of the bottom pane and the width of the request chosen, which the dividers change.
    @State private var bottomHeight: CGFloat = 280
    @State private var detailWidth: CGFloat = 360

    static let bottomRange: ClosedRange<CGFloat> = 160...600
    static let detailRange: ClosedRange<CGFloat> = 280...760
    /// The least room the graph and the requests table keep.
    static let graphMinimum: CGFloat = 200
    static let tableMinimum: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .paneHeaderBar()
            Divider()
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            // The graph and the requests table take the room the bottom pane and the request
            // chosen leave; both dividers can be dragged, and the panes never take more room than
            // the section has.
            GeometryReader { geometry in
                let bottom = min(bottomHeight, max(Self.bottomRange.lowerBound, geometry.size.height - Self.graphMinimum))
                let detailMaximum = max(Self.detailRange.lowerBound, geometry.size.width - Self.tableMinimum)
                let detail = min(detailWidth, detailMaximum)
                VStack(spacing: 0) {
                    graphArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    GraphDivider(axis: .vertical, size: $bottomHeight,
                                 range: Self.bottomRange.lowerBound...max(Self.bottomRange.lowerBound,
                                                                          min(Self.bottomRange.upperBound, geometry.size.height - Self.graphMinimum)))
                    HStack(spacing: 0) {
                        GraphRequestsTable(state: state)
                            .frame(maxWidth: .infinity)
                        GraphDivider(axis: .horizontal, size: $detailWidth,
                                     range: Self.detailRange.lowerBound...min(Self.detailRange.upperBound, detailMaximum))
                        GraphRequestPane(state: state)
                            .frame(width: detail, alignment: .topLeading)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(height: bottom)
                }
            }
        }
        .task(id: GraphReadKey(environment: environment, window: state.window)) {
            await read()
        }
        .task(id: GraphDetailKey(requestID: state.selected?.id, readAt: state.snapshot?.end)) {
            await readDetail()
        }
    }

    // MARK: Header and controls

    private var header: some View {
        HStack(spacing: 12) {
            Text(environment.namespace.map { "\(environment.name) · \($0)" } ?? environment.name)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 12)
            statusLine
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let failure = state.failure {
            Text(failure)
                .foregroundStyle(.red)
                .help(failure)
        } else if let snapshot = state.snapshot {
            let text = GraphStatus.text(of: snapshot)
            Text(text)
                .foregroundStyle(.secondary)
                .help(text)
        } else {
            Text(GraphStatus.reading)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Window", selection: $state.window) {
                ForEach(GraphWindow.allCases) { window in
                    Text(window.label).tag(window)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            TextField("Correlation ID", text: $state.searchText)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 160, idealWidth: 290, maxWidth: 300)
                .textInputSuggestions(state.suggestions, id: \.id) { request in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(request.id)
                            .font(.system(.body, design: .monospaced))
                        Text("\(request.firstService) \(request.route)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .textInputCompletion(request.id)
                }
                .onSubmit { Task { await find() } }
            Button("Find") { Task { await find() } }
            if let message = state.searchMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            TextField("Service", text: $state.serviceText)
                .frame(minWidth: 100, idealWidth: 180, maxWidth: 200)
                .textInputSuggestions(state.serviceSuggestions) { service in
                    Text(service.name)
                        .textInputCompletion(service.name)
                }
                .onSubmit { state.findService() }
            if let message = state.serviceMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var graphArea: some View {
        if state.snapshot != nil {
            GraphCanvasView(state: state)
        } else if let failure = state.failure {
            FieldMessage(text: failure)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(GraphStatus.reading)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Reads

    /// Reads the graph until the task is cancelled: the section goes away, or the window or the
    /// environment changes, which starts over.
    private func read() async {
        let params = GraphRead.Params(projectID: projectID, environment: environment.name, window: state.window)
        while !Task.isCancelled {
            do {
                let result = try await workspace.call(GraphRead.self, params)
                guard !Task.isCancelled else { return }
                state.apply(result, ownService: ownService)
                await state.openPending(lookUp)
            } catch {
                guard !Task.isCancelled else { return }
                state.fail(errorMessage(error))
            }
            try? await Task.sleep(for: GraphSectionState.interval)
        }
    }

    /// Reads the timeline and the log lines of the request chosen.
    private func readDetail() async {
        guard let id = state.selected?.id else { return }
        do {
            let detail = try await lookUp(id)
            guard !Task.isCancelled else { return }
            state.applyDetail(.success(detail), for: id)
        } catch {
            guard !Task.isCancelled else { return }
            state.applyDetail(.failure(error), for: id)
        }
    }

    private func find() async {
        await state.find(lookUp)
    }

    private func lookUp(_ id: String) async throws -> GraphRequestDetail {
        try await workspace.call(GraphRequest.self, GraphRequest.Params(projectID: projectID, environment: environment.name,
                                                                        correlationID: id))
    }
}

/// A divider between two panes, 1 point wide, that dragging moves: it changes `size`, the size of
/// the pane after it, within `range`.
struct GraphDivider: View {
    enum Axis {
        /// Between a pane above and a pane below.
        case vertical
        /// Between a pane on the left and a pane on the right.
        case horizontal
    }

    let axis: Axis
    @Binding var size: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var start: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: axis == .horizontal ? 8 : nil, height: axis == .vertical ? 8 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let first = start ?? size
                            start = first
                            let moved = axis == .horizontal ? value.translation.width : value.translation.height
                            size = min(max(first - moved, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in start = nil })
            }
    }
}

/// The texts of the status line (docs/graph.md › Status line).
enum GraphStatus {
    static let reading = "Reading the graph…"

    /// `<n> requests in the window, <m> traces read in <s> s, at <time>`, or the failure of Jaeger,
    /// then the message of a source that cannot be read.
    static func text(of snapshot: GraphSnapshot) -> String {
        var text = snapshot.jaegerError
            ?? "\(snapshot.requests.count) requests in the window, \(snapshot.tracesRead) traces read in \(String(format: "%.1f", snapshot.jaegerSeconds)) s, at \(GraphFormat.time(snapshot.end))"
        if let source = snapshot.sourceErrors.first {
            text += " · " + source
        }
        return text
    }
}
