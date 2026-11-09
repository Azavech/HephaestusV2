import Foundation

/// The answer of the v3 API of Jaeger (`/api/v3/traces`): OTLP json, or an error
/// (docs/graph.md › Reading the traces).
struct OTLPAnswer: Decodable {
    struct Failure: Decodable {
        let httpCode: Int
        let message: String
    }

    struct Result: Decodable {
        let resourceSpans: [ResourceSpans]?
    }

    struct ResourceSpans: Decodable {
        let resource: Resource?
        let scopeSpans: [ScopeSpans]?
    }

    struct Resource: Decodable {
        let attributes: [Attribute]?
    }

    struct ScopeSpans: Decodable {
        let spans: [Span]?
    }

    struct Span: Decodable {
        let traceId: String
        let spanId: String
        let parentSpanId: String?
        let name: String
        let kind: Int?
        let startTimeUnixNano: String
        let endTimeUnixNano: String
        let attributes: [Attribute]?
        let status: Status?
        let events: [Event]?
    }

    /// An event of a span: a log line of the request when it has the attribute `log.level`.
    struct Event: Decodable {
        let timeUnixNano: String
        let name: String
        let attributes: [Attribute]?
    }

    struct Status: Decodable {
        let code: Int?
    }

    struct Attribute: Decodable {
        let key: String
        let value: Value
    }

    /// An attribute's value as text: an int64 is a string in OTLP json, a number in some encoders;
    /// the values of an array joined with `, ` (the values of a header).
    struct Value: Decodable {
        let text: String

        private enum CodingKeys: String, CodingKey {
            case stringValue, intValue, boolValue, doubleValue, arrayValue
        }

        private struct ArrayValue: Decodable {
            let values: [Value]?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try container.decodeIfPresent(String.self, forKey: .stringValue) {
                self.text = text
            } else if let number = try? container.decodeIfPresent(String.self, forKey: .intValue) {
                text = number
            } else if let number = try? container.decodeIfPresent(Int64.self, forKey: .intValue) {
                text = String(number)
            } else if let flag = try container.decodeIfPresent(Bool.self, forKey: .boolValue) {
                text = String(flag)
            } else if let number = try container.decodeIfPresent(Double.self, forKey: .doubleValue) {
                text = String(number)
            } else if let array = try container.decodeIfPresent(ArrayValue.self, forKey: .arrayValue) {
                text = (array.values ?? []).map(\.text).joined(separator: ", ")
            } else {
                text = ""
            }
        }
    }

    let result: Result?
    let error: Failure?

    /// The kinds of span of OpenTelemetry, as Jaeger names them.
    static let kinds = [1: "internal", 2: "server", 3: "client", 4: "producer", 5: "consumer"]

    /// The traces of the answer: its spans grouped by trace, the service of each the `service.name`
    /// of its resource.
    var traces: [JaegerTrace] {
        var spans: [String: [JaegerSpan]] = [:]
        var order: [String] = []
        for resourceSpans in result?.resourceSpans ?? [] {
            let service = resourceSpans.resource?.attributes?.first { $0.key == "service.name" }?.value.text ?? ""
            for scopeSpans in resourceSpans.scopeSpans ?? [] {
                for span in scopeSpans.spans ?? [] {
                    var tags = Dictionary((span.attributes ?? []).map { ($0.key, $0.value.text) }, uniquingKeysWith: { first, _ in first })
                    tags["span.kind"] = span.kind.flatMap { Self.kinds[$0] }
                    if span.status?.code == 2 {
                        tags["otel.status_code"] = "ERROR"
                    }
                    let start = (Int64(span.startTimeUnixNano) ?? 0) / 1000
                    let end = (Int64(span.endTimeUnixNano) ?? 0) / 1000
                    let traceID = GraphAnalysis.correlationID(span.traceId)
                    if spans[traceID] == nil {
                        order.append(traceID)
                    }
                    spans[traceID, default: []].append(JaegerSpan(
                        spanID: span.spanId, operationName: span.name, parent: span.parentSpanId,
                        startTime: start, duration: end - start, tags: tags, service: service,
                        events: (span.events ?? []).map { event in
                            JaegerEvent(time: (Int64(event.timeUnixNano) ?? 0) / 1000, name: event.name,
                                        attributes: Dictionary((event.attributes ?? []).map { ($0.key, $0.value.text) },
                                                               uniquingKeysWith: { first, _ in first }))
                        }
                    ))
                }
            }
        }
        return order.map { JaegerTrace(traceID: $0, spans: spans[$0] ?? []) }
    }
}
