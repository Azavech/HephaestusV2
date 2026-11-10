// OWNER: ui-dashboard — the graph widgets of the Dashboard (docs/dashboard.md › Graph widgets).
import Charts
import HephaestusCore
import SwiftUI

/// The graph of the shown project for its graph widgets, read with `graph.read` for the current
/// working environment and the Dashboard's window: when the Dashboard shows a graph widget, 5
/// seconds after the end of each read, and at once when the window or the environment changes.
@MainActor @Observable
final class DashboardGraphFeed {
    /// The last read that succeeded; nil until the first read of the environment and window ends.
    private(set) var snapshot: GraphSnapshot?
    /// The engine's message when the last read failed, until a read succeeds.
    private(set) var failure: String?
    /// The layout of the last graph read.
    private(set) var layout: GraphLayout?

    /// Reads until the task is cancelled; a new environment or window starts with the spinner.
    func read(workspace: DeviceWorkspace, params: GraphRead.Params) async {
        snapshot = nil
        failure = nil
        while !Task.isCancelled {
            do {
                let result = try await workspace.call(GraphRead.self, params)
                guard !Task.isCancelled else { return }
                if layout == nil || snapshot?.graph != result.graph {
                    layout = GraphLayout(graph: result.graph)
                }
                snapshot = result
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                failure = errorMessage(error)
            }
            try? await Task.sleep(for: GraphSectionState.interval)
        }
    }
}

/// What the graph widgets show (docs/dashboard.md › Graph widgets).
enum DashboardGraph {
    /// The height the map of a Service graph widget counts for the rows of a widget without
    /// position and of an added widget; the map itself fills its widget (docs/dashboard.md › Lists
    /// without positions).
    static let mapHeight: CGFloat = 260
    /// The height the chart of a Requests per minute widget counts for those rows; the chart
    /// itself fills its widget.
    static let chartHeight: CGFloat = 120
    /// The room under the chart for the lower half of the label of its axis at 0.
    static let chartLabelRoom: CGFloat = 6
    static let noCalls = "No calls in the window."
    static let noFailedRequests = "No failed requests in the window."
    static let lastMinuteCaption = "in the last minute"

    /// The arrows that have at least one call, the busiest first, arrows with the same number by
    /// their order in the graph, at most `limit`.
    static func busiestCalls(_ snapshot: GraphSnapshot, limit: Int) -> [(arrow: GraphArrow, count: Int)] {
        let calls = snapshot.arrows.enumerated().compactMap { index, arrow -> (Int, GraphArrow, Int)? in
            guard let count = snapshot.calls[arrow.id], count > 0 else { return nil }
            return (index, arrow, count)
        }
        return calls
            .sorted { ($1.2, $0.0) < ($0.2, $1.0) }
            .prefix(max(limit, 0))
            .map { ($0.1, $0.2) }
    }

    /// The requests answered 400 or above, newest first, at most `limit`.
    static func failedRequests(_ snapshot: GraphSnapshot, limit: Int) -> [GraphRequestSummary] {
        Array(snapshot.requests.filter { ($0.status ?? 0) >= 400 }.prefix(max(limit, 0)))
    }

    /// The text of an arrow: `<from> → <to>`, the kind of the target after it when it is not a
    /// service.
    static func label(of arrow: GraphArrow) -> String {
        let target = arrow.to.kind == .service ? arrow.to.name : "\(arrow.to.name) \(arrow.to.kind.label)"
        return "\(arrow.from.name) → \(target)"
    }

    /// The number of rows of a widget: its `Number` setting within 1–20.
    static func rowLimit(of widget: DashboardWidget) -> Int {
        min(max(widget.count, DashboardWidget.countRange.lowerBound), DashboardWidget.countRange.upperBound)
    }
}

/// The content of a graph widget: the spinner of the first read, a failure, the message without
/// Jaeger, or the widget's own content. The map of a Service graph widget and the chart of a
/// Requests per minute widget fill the space the widget gives them (docs/dashboard.md › Content).
struct DashboardGraphWidgetContent: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary
    let widget: DashboardWidget
    let feed: DashboardGraphFeed
    let editing: Bool

    /// The graph of the last read, when the widget has one to show.
    private var snapshot: GraphSnapshot? {
        guard workspace.details[project.id]?.currentWorkingEnvironment != nil, feed.failure == nil else { return nil }
        return feed.snapshot
    }

    var body: some View {
        switch widget.kind {
        case .serviceGraph:
            VStack(alignment: .leading, spacing: 6) {
                // The map fills the widget; whatever shows in its place counts as high as it.
                Group {
                    if let snapshot {
                        serviceGraph(snapshot)
                    } else {
                        unread
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, idealHeight: DashboardGraph.mapHeight, maxHeight: .infinity, alignment: .topLeading)
                if let jaegerError = snapshot?.jaegerError {
                    Text(jaegerError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .requestsPerMinute:
            requestsPerMinute(snapshot)
        default:
            if let snapshot {
                if let jaegerError = snapshot.jaegerError {
                    Text(jaegerError)
                        .foregroundStyle(.secondary)
                } else if widget.kind == .busiestCalls {
                    busiestCalls(snapshot)
                } else {
                    failedRequests(snapshot)
                }
            } else {
                unread
            }
        }
    }

    /// What a graph widget shows while it has no graph: the message of a project without
    /// environment, the engine's message of a failed read, or the spinner of the first read.
    @ViewBuilder
    private var unread: some View {
        if workspace.details[project.id]?.currentWorkingEnvironment == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(DashboardInstances.noEnvironmentMessage)
                    .foregroundStyle(.secondary)
                Button("Project Settings…") {
                    window.section = .settings
                }
            }
        } else if let failure = feed.failure {
            FieldMessage(text: failure)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: Service graph

    private func serviceGraph(_ snapshot: GraphSnapshot) -> some View {
        Button {
            guard !editing else { return }
            openGraph(requestID: nil)
        } label: {
            GeometryReader { geometry in
                if let layout = feed.layout, let fit = GraphGeometry.fit(layout, boxes: snapshot.boxes, in: geometry.size) {
                    GraphMapView(model: GraphMapModel(graph: snapshot.graph, layout: layout, counts: snapshot.calls,
                                                      showsAllLabels: false),
                                 scale: fit.scale, offset: fit.offset)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the Graph")
    }

    // MARK: Busiest calls

    @ViewBuilder
    private func busiestCalls(_ snapshot: GraphSnapshot) -> some View {
        let rows = DashboardGraph.busiestCalls(snapshot, limit: DashboardGraph.rowLimit(of: widget))
        let busiest = snapshot.calls.values.max() ?? 0
        if rows.isEmpty {
            Text(DashboardGraph.noCalls)
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows, id: \.arrow.id) { row in
                    GridRow {
                        Text(DashboardGraph.label(of: row.arrow))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(String(row.count))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(GraphGeometry.swiftUIColor(GraphColorScale.color(count: row.count, busiest: busiest)))
                            // The number is never truncated or wrapped: a narrower widget scrolls it.
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
        }
    }

    // MARK: Failed requests

    @ViewBuilder
    private func failedRequests(_ snapshot: GraphSnapshot) -> some View {
        let rows = DashboardGraph.failedRequests(snapshot, limit: DashboardGraph.rowLimit(of: widget))
        if rows.isEmpty {
            Text(DashboardGraph.noFailedRequests)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { request in
                    Button {
                        guard !editing else { return }
                        openGraph(requestID: request.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(request.id)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 160, alignment: .leading)
                            Text("\(request.firstService) \(request.route)")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            // The status and the start time are never truncated or wrapped: a
                            // narrower widget scrolls them.
                            Text(request.status.map(String.init) ?? "–")
                                .monospacedDigit()
                                .foregroundStyle(.red)
                                .fixedSize()
                            Text(GraphFormat.time(request.start))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Requests per minute

    /// The number of the last minute with its caption and, under them, the chart, which fills the
    /// widget. While there is no graph, or no Jaeger, what shows in place of the number takes its
    /// row, and the space of the chart stays empty, so the widget counts the same height.
    private func requestsPerMinute(_ snapshot: GraphSnapshot?) -> some View {
        let requests = snapshot.flatMap { $0.jaegerError == nil ? $0 : nil }
        let counts = requests.map { GraphAnalysis.requestsPerMinute($0.requests, window: DateInterval(start: $0.start, end: $0.end)) } ?? []
        let points = counts.enumerated().map { MinutePoint(minute: $0.offset - counts.count + 1, count: $0.element) }
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Text("0")
                    .font(.title.weight(.semibold).monospacedDigit())
                    .hidden()
                if requests != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(counts.last ?? 0))
                            .font(.title.weight(.semibold).monospacedDigit())
                            // The number is never truncated or wrapped: a narrower widget scrolls it.
                            .fixedSize()
                        Text(DashboardGraph.lastMinuteCaption)
                            .foregroundStyle(.secondary)
                    }
                } else if let jaegerError = snapshot?.jaegerError {
                    Text(jaegerError)
                        .foregroundStyle(.secondary)
                } else {
                    unread
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Group {
                if requests != nil {
                    Chart(points) { point in
                        LineMark(x: .value("Minute", point.minute), y: .value("Requests", point.count))
                    }
                    .chartYScale(domain: 0...max(1, counts.max() ?? 1))
                    .chartXAxis(.hidden)
                    // The label of the axis at 0 is drawn half under the chart: it stays inside
                    // the content, which is cut at its edge.
                    .padding(.bottom, DashboardGraph.chartLabelRoom)
                } else {
                    Color.clear
                }
            }
            .frame(minHeight: 0, idealHeight: DashboardGraph.chartHeight, maxHeight: .infinity)
        }
    }

    /// Opens the Graph of the shown project, with the view of a request: on a sub project's
    /// Dashboard, the window activates the sub project (docs/dashboard.md › Actions).
    private func openGraph(requestID: String?) {
        if let requestID {
            window.ensureGraphState(of: project.id).pendingRequestID = requestID
        }
        Task {
            await window.navigate(to: .section(projectID: project.id, section: .graph))
        }
    }
}

/// A minute of the Requests per minute chart: 0 for the last one, negative before.
private struct MinutePoint: Identifiable {
    var minute: Int
    var count: Int
    var id: Int { minute }
}
