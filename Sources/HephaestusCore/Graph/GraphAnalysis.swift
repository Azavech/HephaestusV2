import Foundation

/// What the traces of Jaeger say of the graph: the calls of each arrow, the requests, their
/// timelines and their log lines (docs/graph.md › Calls and colours, › Requests, › Request view).
public enum GraphAnalysis {
    /// How long a request waits before it is listed: each service sends its spans at most a second
    /// after they end, so a request read sooner can miss the spans of a service, and look as if it
    /// started in the next one.
    public static let settling: TimeInterval = 3

    /// The correlation id of a trace id of Jaeger: lowercase, 32 hex digits.
    public static func correlationID(_ traceID: String) -> String {
        let lowered = traceID.lowercased()
        return String(repeating: "0", count: max(0, 32 - lowered.count)) + lowered
    }

    /// The arrow a span is a call of: a client span of a service to the service named by the first
    /// label of its `server.address`, a postgres span to the service's Cluster, an S3 span to its
    /// bucket. Nil for any other span, or an arrow the graph does not have.
    static func arrow(of span: JaegerSpan, in trace: JaegerTrace, graph: ServiceGraph) -> GraphArrow? {
        guard span.kind == "client", let service = trace.service(of: span) else { return nil }
        let from = GraphBox(kind: .service, name: service)
        let to: GraphBox
        if span.tag("db.system.name") == "postgresql" {
            to = GraphBox(kind: .cluster, name: service)
        } else if span.tag("rpc.system") == "aws-api", span.tag("rpc.service") == "S3" {
            to = GraphBox(kind: .bucket, name: service)
        } else if let address = span.tag("server.address"), let host = address.split(separator: ".").first {
            to = GraphBox(kind: .service, name: String(host))
        } else {
            return nil
        }
        return graph.arrow(from: from, to: to)
    }

    /// The calls of each arrow, by id: the spans of the traces that started in the window.
    public static func counts(traces: [JaegerTrace], graph: ServiceGraph, window: DateInterval) -> [String: Int] {
        var counts: [String: Int] = [:]
        for trace in traces {
            for span in trace.spans where window.contains(span.start) {
                if let arrow = arrow(of: span, in: trace, graph: graph) {
                    counts[arrow.id, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// The first span of a trace: the one whose parent is not in the trace (the parent of a request
    /// is in the client that sent it), the earliest when several.
    static func root(of trace: JaegerTrace) -> JaegerSpan? {
        let ids = Set(trace.spans.map(\.spanID))
        return trace.spans
            .filter { span in span.parentID.map { !ids.contains($0) } ?? true }
            .min { ($0.startTime, $0.spanID) < ($1.startTime, $1.spanID) }
    }

    /// The request of a trace, nil when its first span is not a server span of a service (a query
    /// at startup).
    public static func request(of trace: JaegerTrace, graph: ServiceGraph) -> GraphRequestSummary? {
        guard let root = root(of: trace), root.kind == "server", let firstService = trace.service(of: root) else { return nil }
        var boxes: Set<String> = []
        var arrowCalls: [String: Int] = [:]
        let services = Set(graph.boxes.filter { $0.kind == .service }.map(\.name))
        for span in trace.spans {
            if let service = trace.service(of: span), services.contains(service) {
                boxes.insert(GraphBox(kind: .service, name: service).id)
            }
            if let arrow = arrow(of: span, in: trace, graph: graph) {
                arrowCalls[arrow.id, default: 0] += 1
                boxes.insert(arrow.to.id)
            }
        }
        let route = root.tag("http.route").map { "\(root.tag("http.request.method") ?? "") \($0)".trimmingCharacters(in: .whitespaces) }
        return GraphRequestSummary(
            id: correlationID(trace.traceID),
            start: root.start,
            firstService: firstService,
            route: route ?? root.operationName,
            // Jaeger's json names http.response.status_code of OpenTelemetry http.status_code.
            status: status(of: root),
            duration: Double(root.duration) / 1_000_000,
            boxes: boxes.sorted(),
            arrows: arrowCalls.keys.sorted(),
            arrowCalls: arrowCalls
        )
    }

    /// The request of a trace with its timeline and its log lines; nil when the trace is not a
    /// request.
    public static func detail(of trace: JaegerTrace, graph: ServiceGraph) -> GraphRequestDetail? {
        guard let request = request(of: trace, graph: graph), let root = root(of: trace) else { return nil }
        return GraphRequestDetail(request: request, timeline: timeline(of: trace, root: root), logs: logs(of: trace, root: root))
    }

    /// Every request of the traces that started in the window, newest first, each once; the ones
    /// that started in the last seconds of the window (`settling`) wait for the next read.
    public static func requests(traces: [JaegerTrace], graph: ServiceGraph, window: DateInterval) -> [GraphRequestSummary] {
        var seen: Set<String> = []
        let settled = window.end.addingTimeInterval(-settling)
        return traces
            .compactMap { request(of: $0, graph: graph) }
            .filter { window.contains($0.start) && $0.start <= settled && seen.insert($0.id).inserted }
            .sorted { ($0.start, $0.id) > ($1.start, $1.id) }
    }

    /// The requests whose correlation id holds the text typed, any part of it, in upper or lower
    /// case, in their order; every request for an empty text (docs/graph.md › Correlation ID field).
    public static func matching(_ requests: [GraphRequestSummary], text: String) -> [GraphRequestSummary] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty else { return requests }
        return requests.filter { $0.id.contains(typed) }
    }

    /// `http.response.status_code`, else `http.status_code`.
    static func status(of span: JaegerSpan) -> Int? {
        (span.tag("http.response.status_code") ?? span.tag("http.status_code")).flatMap { Int($0) }
    }

    /// Each span of the trace, in the order it started, its depth below the first span.
    static func timeline(of trace: JaegerTrace, root: JaegerSpan) -> [GraphSpan] {
        let byID = Dictionary(trace.spans.map { ($0.spanID, $0) }, uniquingKeysWith: { first, _ in first })
        func depth(_ span: JaegerSpan) -> Int {
            var depth = 0
            var current = span
            while let parent = current.parentID.flatMap({ byID[$0] }), depth < trace.spans.count {
                depth += 1
                current = parent
            }
            return depth
        }
        return trace.spans
            .sorted { ($0.startTime, $0.spanID) < ($1.startTime, $1.spanID) }
            .map { span in
                GraphSpan(
                    id: span.spanID,
                    service: trace.service(of: span) ?? "",
                    name: span.operationName,
                    offset: Double(span.startTime - root.startTime) / 1_000_000,
                    duration: Double(span.duration) / 1_000_000,
                    depth: depth(span),
                    failed: span.tag("otel.status_code") == "ERROR" || span.tag("error") == "true",
                    kind: kind(of: span),
                    http: http(of: span)
                )
            }
    }

    /// What a span is, from the attributes the plugins of the services give it.
    static func kind(of span: JaegerSpan) -> GraphSpanKind {
        switch span.kind {
        case "server" where span.tag("http.request.method") != nil:
            return .httpRequest
        case "producer":
            return .publish
        case "consumer":
            return .consume
        case "client":
            if let system = span.tag("db.system.name") {
                return system == "redis" ? .redis : .sql
            }
            if span.tag("rpc.service") == "S3" {
                return .s3
            }
            if span.tag("http.request.method") != nil {
                return .httpCall
            }
            return .other
        default:
            return .other
        }
    }

    /// The details of an HTTP request (`url.path` and `url.query`) or call (`url.full`), nil for any
    /// other span.
    static func http(of span: JaegerSpan) -> GraphHTTPDetails? {
        let kind = kind(of: span)
        guard kind == .httpRequest || kind == .httpCall, let method = span.tag("http.request.method") else { return nil }
        let url: String
        if kind == .httpCall {
            url = span.tag("url.full") ?? span.operationName
        } else {
            url = (span.tag("url.path") ?? "") + (span.tag("url.query").map { "?\($0)" } ?? "")
        }
        func headers(_ prefix: String) -> [GraphField] {
            span.tags
                .filter { $0.key.hasPrefix(prefix) }
                .map { GraphField(name: String($0.key.dropFirst(prefix.count)), value: headerValue($0.value)) }
                .sorted { $0.name < $1.name }
        }
        return GraphHTTPDetails(method: method, url: url, status: status(of: span),
                                requestHeaders: headers("http.request.header."), responseHeaders: headers("http.response.header."))
    }

    /// The values of a header as text, joined by a comma: Jaeger answers an array attribute as the
    /// json of its values (`["application/json"]`), OTLP as an array.
    static func headerValue(_ raw: String) -> String {
        guard raw.hasPrefix("["), let values = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { return raw }
        return values.joined(separator: ", ")
    }

    /// The events of the spans that are log lines (their attribute `log.level`), by time.
    static func logs(of trace: JaegerTrace, root: JaegerSpan) -> [GraphLogLine] {
        trace.spans
            .flatMap { span in
                span.events.enumerated().compactMap { index, event -> GraphLogLine? in
                    guard let level = event.attributes["log.level"] else { return nil }
                    return GraphLogLine(
                        id: "\(span.spanID)/\(index)",
                        time: Date(timeIntervalSince1970: Double(event.time) / 1_000_000),
                        offset: Double(event.time - root.startTime) / 1_000_000,
                        service: trace.service(of: span) ?? "",
                        level: level,
                        message: event.name,
                        fields: event.attributes
                            .filter { $0.key != "log.level" }
                            .map { GraphField(name: $0.key, value: $0.value) }
                            .sorted { $0.name < $1.name }
                    )
                }
            }
            .sorted { ($0.time, $0.id) < ($1.time, $1.id) }
    }

    /// The requests of each minute of a window, from its start: the last minute holds the requests
    /// of its last 60 seconds, the one before the 60 seconds before (docs/dashboard.md › Graph
    /// widgets).
    public static func requestsPerMinute(_ requests: [GraphRequestSummary], window: DateInterval) -> [Int] {
        let minutes = max(1, Int((window.duration / 60).rounded(.up)))
        var counts = [Int](repeating: 0, count: minutes)
        for request in requests where window.contains(request.start) {
            let fromEnd = Int(window.end.timeIntervalSince(request.start) / 60)
            let index = minutes - 1 - min(max(fromEnd, 0), minutes - 1)
            counts[index] += 1
        }
        return counts
    }
}
