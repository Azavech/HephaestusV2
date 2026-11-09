// OWNER: ui-graph — the requests of the window and the request chosen: its timeline, the details
// of an HTTP span and its log lines (docs/graph.md › Requests, › Request view).
import AppKit
import HephaestusCore
import SwiftUI

/// The formats of the Graph's times and durations.
enum GraphFormat {
    /// `12.4 ms`.
    static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    /// `HH:mm:ss`.
    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// `HH:mm:ss.SSS`.
    static func preciseTime(_ date: Date) -> String {
        preciseFormatter.string(from: date)
    }

    private static let timeFormatter = formatter("HH:mm:ss")
    private static let preciseFormatter = formatter("HH:mm:ss.SSS")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// The colour of a status: red from 400.
    static func statusColor(_ status: Int?) -> Color {
        (status ?? 0) >= 400 ? .red : .primary
    }
}

/// Every request of the window, newest first, but those the Correlation ID field filters out; a
/// click on a row opens the view of its request.
struct GraphRequestsTable: View {
    let state: GraphSectionState

    var body: some View {
        Table(state.visibleRequests, selection: selection) {
            TableColumn("Correlation ID") { request in
                Text(request.id)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .width(min: 120, ideal: 260)
            TableColumn("Start") { request in
                Text(GraphFormat.preciseTime(request.start))
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 100)
            TableColumn("First service and route") { request in
                Text("\(request.firstService) \(request.route)")
            }
            .width(min: 120, ideal: 175)
            TableColumn("Status") { request in
                Text(request.status.map(String.init) ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(GraphFormat.statusColor(request.status))
            }
            .width(min: 45, ideal: 50)
            TableColumn("Duration") { request in
                Text(GraphFormat.milliseconds(request.duration))
                    .monospacedDigit()
            }
            .width(min: 65, ideal: 75)
            TableColumn("Items hit") { request in
                Text("\(request.itemsHit)")
                    .monospacedDigit()
            }
            .width(min: 55, ideal: 65)
        }
    }

    /// The row of the request shown; choosing a row opens its request.
    private var selection: Binding<String?> {
        Binding(get: { state.selected?.id }, set: { id in
            guard let id, id != state.selected?.id, let request = state.requests.first(where: { $0.id == id }) else { return }
            state.open(request)
        })
    }
}

/// The request chosen: its timeline, each span with an icon of its kind, the details of the HTTP
/// span clicked under it; or the log lines of every service for it, by time.
struct GraphRequestPane: View {
    @Bindable var state: GraphSectionState

    var body: some View {
        if let request = state.selected {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.id)
                        .font(.system(.headline, design: .monospaced))
                        .textSelection(.enabled)
                    Text("\(request.firstService) \(request.route) · \(request.status.map(String.init) ?? "–") · \(GraphFormat.milliseconds(request.duration)) · \(request.itemsHit) items hit · \(request.start.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("", selection: $state.detailTab) {
                    ForEach(GraphSectionState.DetailTab.allCases, id: \.self) { tab in
                        Text(tab == .log ? "Log (\(state.detail?.logs.count ?? 0))" : tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                if let failure = state.detailFailure {
                    FieldMessage(text: failure)
                } else if let detail = state.detail, detail.request.id == request.id {
                    switch state.detailTab {
                    case .timeline:
                        timeline(of: detail)
                    case .log:
                        GraphLogView(logs: detail.logs)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(12)
        } else {
            Text("Choose a request, or type its correlation id")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func timeline(of detail: GraphRequestDetail) -> some View {
        let total = max(detail.request.duration, detail.timeline.map { $0.offset + $0.duration }.max() ?? 0)
        let chosen = detail.timeline.first { $0.id == state.selectedSpanID && $0.http != nil }
        // The details of the span chosen take 55% of the height under the tabs.
        return GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(detail.timeline) { span in
                            Button {
                                // Only an HTTP request or call has details.
                                if span.http != nil {
                                    state.selectedSpanID = span.id == state.selectedSpanID ? nil : span.id
                                }
                            } label: {
                                GraphTimelineRow(span: span, total: total, selected: span.id == chosen?.id)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                if let chosen, let http = chosen.http {
                    Divider()
                    GraphHTTPDetailsView(span: chosen, http: http)
                        .frame(height: max(100, geometry.size.height * 0.55))
                }
            }
        }
    }
}

extension GraphSpanKind {
    /// The SF Symbol of the kind (docs/graph.md › Timeline).
    var icon: String {
        switch self {
        case .httpRequest: return "arrow.down.circle"
        case .httpCall: return "arrow.up.right.circle"
        case .sql: return "cylinder.split.1x2"
        case .redis: return "bolt.horizontal"
        case .s3: return "archivebox"
        case .publish: return "envelope.arrow.triangle.branch"
        case .consume: return "envelope.open"
        case .other: return "circle.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .httpRequest, .httpCall: return .accentColor
        case .sql: return .purple
        case .redis: return .orange
        case .s3: return .teal
        case .publish, .consume: return .pink
        case .other: return .gray
        }
    }
}

/// A span: its icon and name, its service, its start and duration, and a bar; red when it failed.
struct GraphTimelineRow: View {
    let span: GraphSpan
    let total: Double
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: span.kind.icon)
                    .foregroundStyle(span.kind.tint)
                    .frame(width: 16)
                    .help(span.kind.label)
                VStack(alignment: .leading, spacing: 0) {
                    Text(span.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(span.service)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(span.depth) * 10)
            .frame(width: 150, alignment: .leading)
            Text("+\(GraphFormat.milliseconds(span.offset))")
                .font(.caption.monospacedDigit())
                .frame(width: 62, alignment: .trailing)
            Text(GraphFormat.milliseconds(span.duration))
                .font(.caption.monospacedDigit())
                .frame(width: 56, alignment: .trailing)
            GeometryReader { geometry in
                let width = geometry.size.width
                let start = total > 0 ? span.offset / total : 0
                let length = total > 0 ? span.duration / total : 0
                RoundedRectangle(cornerRadius: 3)
                    .fill(span.failed ? Color.red : span.kind.tint)
                    .frame(width: max(2, width * length), height: 12)
                    .offset(x: width * start, y: 4)
            }
            .frame(minWidth: 40, maxHeight: 20)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
    }
}

/// The method, URL, status and headers of an HTTP request or call.
struct GraphHTTPDetailsView: View {
    let span: GraphSpan
    let http: GraphHTTPDetails

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: span.kind.icon)
                    Text(span.kind.label)
                        .font(.headline)
                    Text(span.service)
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Method").foregroundStyle(.secondary)
                        Text(http.method).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("URL").foregroundStyle(.secondary)
                        Text(http.url).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        Text(http.status.map(String.init) ?? "–")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(GraphFormat.statusColor(http.status))
                    }
                }
                headers("Request headers", http.requestHeaders)
                headers("Response headers", http.responseHeaders)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
    }

    private func headers(_ title: String, _ headers: [GraphField]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.bold())
            if headers.isEmpty {
                Text("none").foregroundStyle(.secondary)
            }
            ForEach(headers, id: \.self) { header in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(header.name)
                        .font(.system(.caption, design: .monospaced).bold())
                    Text(header.value)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(header.value == "[hidden]" ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Every log line of the request, by time: its time and its start from the request, its service,
/// its level, its message and its fields.
struct GraphLogView: View {
    let logs: [GraphLogLine]

    var body: some View {
        if logs.isEmpty {
            Text("No log line for this request")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(logs) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(GraphFormat.preciseTime(line.time))
                                Text("+\(GraphFormat.milliseconds(line.offset))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption.monospacedDigit())
                            .frame(width: 84, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 8) {
                                    Text(line.service)
                                        .lineLimit(1)
                                    Text(line.level)
                                        .foregroundStyle(Self.levelColor(line.level))
                                }
                                .font(.caption.bold())
                                Text(line.message)
                                    .font(.callout)
                                if !line.fields.isEmpty {
                                    Text(line.fields.map { "\($0.name)=\($0.value)" }.joined(separator: "  "))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static func levelColor(_ level: String) -> Color {
        switch level {
        case "error", "fatal", "panic": return .red
        case "warning", "warn": return .orange
        case "debug", "trace": return .secondary
        default: return .primary
        }
    }
}
