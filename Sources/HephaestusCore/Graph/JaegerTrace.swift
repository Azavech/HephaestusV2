import Foundation

/// A trace of Jaeger, its spans and the service of each one: read from the OTLP json of the v3 API
/// (docs/graph.md › Reading the traces).
public struct JaegerTrace: Sendable {
    public let traceID: String
    public let spans: [JaegerSpan]

    public init(traceID: String, spans: [JaegerSpan]) {
        self.traceID = traceID
        self.spans = spans
    }

    /// The `service.name` of the resource of a span; nil without one.
    public func service(of span: JaegerSpan) -> String? {
        span.service.isEmpty ? nil : span.service
    }
}

public struct JaegerSpan: Sendable {
    public let spanID: String
    public let operationName: String
    /// The span it is the child of; nil for none.
    public let parentID: String?
    /// Microseconds since 1970.
    public let startTime: Int64
    /// Microseconds.
    public let duration: Int64
    /// Its attributes, as text whatever their type, with `span.kind` and `otel.status_code`.
    public let tags: [String: String]
    /// The `service.name` of its resource; empty without one.
    public let service: String
    /// Its events, the log lines of the request among them.
    public let events: [JaegerEvent]

    public init(spanID: String, operationName: String, parent: String? = nil, startTime: Int64, duration: Int64,
                tags: [String: String], service: String, events: [JaegerEvent] = []) {
        self.spanID = spanID
        self.operationName = operationName
        self.parentID = parent.flatMap { $0.isEmpty ? nil : $0 }
        self.startTime = startTime
        self.duration = duration
        self.tags = tags
        self.service = service
        self.events = events
    }

    /// An attribute, as text whatever its type.
    public func tag(_ key: String) -> String? {
        tags[key]
    }

    /// `server`, `client`, `producer`, `consumer` or `internal`: the kind of span of OpenTelemetry.
    public var kind: String? { tag("span.kind") }

    public var start: Date { Date(timeIntervalSince1970: Double(startTime) / 1_000_000) }
}

/// An event of a span: a log line when it has the attribute `log.level`.
public struct JaegerEvent: Sendable {
    /// Microseconds since 1970.
    public let time: Int64
    public let name: String
    public let attributes: [String: String]

    public init(time: Int64, name: String, attributes: [String: String]) {
        self.time = time
        self.name = name
        self.attributes = attributes
    }
}
