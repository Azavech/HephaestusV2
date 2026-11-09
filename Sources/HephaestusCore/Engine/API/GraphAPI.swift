import Foundation

// docs/engine-api.md › Graph: the methods of the Graph section and of the Dashboard's graph
// widgets (docs/graph.md, docs/dashboard.md › Graph widgets), with their types.

/// `graph.read`: the boxes and arrows of the namespace of an environment, their calls and the
/// requests of a time window. Actors: user.
public enum GraphRead: EngineMethod {
    public static let name = "graph.read"
    public struct Params: Codable, Sendable, Hashable {
        /// Project identifier.
        public var projectID: ProjectID
        /// Name of an environment of the project as they apply, inherited ones included.
        public var environment: String
        public var window: GraphWindow

        public init(projectID: ProjectID, environment: String, window: GraphWindow) {
            self.projectID = projectID
            self.environment = environment
            self.window = window
        }
    }
    public typealias Result = GraphSnapshot
}

/// `graph.request`: one request of Jaeger, with its timeline and its log lines. Actors: user.
public enum GraphRequest: EngineMethod {
    public static let name = "graph.request"
    public struct Params: Codable, Sendable, Hashable {
        /// Project identifier.
        public var projectID: ProjectID
        /// Name of an environment of the project as they apply, inherited ones included.
        public var environment: String
        /// The correlation id, trimmed and in lowercase.
        public var correlationID: String

        public init(projectID: ProjectID, environment: String, correlationID: String) {
            self.projectID = projectID
            self.environment = environment
            self.correlationID = correlationID
        }
    }
    public typealias Result = GraphRequestDetail
}

/// The result of `graph.read` (docs/engine-api.md › GraphSnapshot).
public struct GraphSnapshot: Codable, Sendable, Hashable {
    public var environment: String
    /// Absent when the environment has none.
    public var namespace: String?
    public var window: GraphWindow
    public var start: Date
    /// The time of the read.
    public var end: Date
    public var boxes: [GraphBox]
    public var arrows: [GraphArrow]
    /// The calls of each arrow in the window, by arrow id; an arrow without calls is absent.
    public var calls: [String: Int]
    /// Newest first.
    public var requests: [GraphRequestSummary]
    public var tracesRead: Int
    /// The time the read of Jaeger took, in seconds.
    public var jaegerSeconds: Double
    /// `Jaeger cannot be reached: <reason>`; nil when Jaeger was read.
    public var jaegerError: String?
    /// `The sources of <deployment> cannot be read: <reason>.`, in the order of the boxes.
    public var sourceErrors: [String]

    public init(environment: String, namespace: String? = nil, window: GraphWindow, start: Date, end: Date,
                boxes: [GraphBox] = [], arrows: [GraphArrow] = [], calls: [String: Int] = [:],
                requests: [GraphRequestSummary] = [], tracesRead: Int = 0, jaegerSeconds: Double = 0,
                jaegerError: String? = nil, sourceErrors: [String] = []) {
        self.environment = environment
        self.namespace = namespace
        self.window = window
        self.start = start
        self.end = end
        self.boxes = boxes
        self.arrows = arrows
        self.calls = calls
        self.requests = requests
        self.tracesRead = tracesRead
        self.jaegerSeconds = jaegerSeconds
        self.jaegerError = jaegerError
        self.sourceErrors = sourceErrors
    }

    /// The boxes and the arrows.
    public var graph: ServiceGraph {
        ServiceGraph(boxes: boxes, arrows: arrows)
    }
}

/// A request of the window (docs/engine-api.md › GraphRequestSummary).
public struct GraphRequestSummary: Codable, Sendable, Hashable, Identifiable {
    /// The correlation id: the trace id, 32 lowercase hexadecimal digits.
    public var id: String
    public var start: Date
    public var firstService: String
    public var route: String
    public var status: Int?
    /// Seconds.
    public var duration: Double
    /// The ids of the boxes its spans touched, sorted.
    public var boxes: [String]
    /// The ids of the arrows its calls took, sorted.
    public var arrows: [String]
    /// The calls of each of these arrows in the request alone, by arrow id.
    public var arrowCalls: [String: Int]

    public init(id: String, start: Date, firstService: String, route: String, status: Int? = nil, duration: Double,
                boxes: [String] = [], arrows: [String] = [], arrowCalls: [String: Int] = [:]) {
        self.id = id
        self.start = start
        self.firstService = firstService
        self.route = route
        self.status = status
        self.duration = duration
        self.boxes = boxes
        self.arrows = arrows
        self.arrowCalls = arrowCalls
    }

    /// The number of boxes its spans touched: the Items hit column.
    public var itemsHit: Int { boxes.count }
}

/// The result of `graph.request` (docs/engine-api.md › GraphRequestDetail).
public struct GraphRequestDetail: Codable, Sendable, Hashable {
    public var request: GraphRequestSummary
    public var timeline: [GraphSpan]
    public var logs: [GraphLogLine]

    public init(request: GraphRequestSummary, timeline: [GraphSpan] = [], logs: [GraphLogLine] = []) {
        self.request = request
        self.timeline = timeline
        self.logs = logs
    }
}

/// What a span of the timeline is (docs/graph.md › Timeline).
public enum GraphSpanKind: String, Codable, Sendable, Hashable, CaseIterable {
    case httpRequest, httpCall, sql, redis, s3, publish, consume, other

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }

    /// The name of the kind: the tooltip of its icon.
    public var label: String {
        switch self {
        case .httpRequest: return "HTTP request"
        case .httpCall: return "HTTP call"
        case .sql: return "SQL"
        case .redis: return "redis"
        case .s3: return "S3"
        case .publish: return "Kafka message published"
        case .consume: return "Kafka message consumed"
        case .other: return "span"
        }
    }
}

/// A span of a request, in its timeline (docs/engine-api.md › GraphSpan).
public struct GraphSpan: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var service: String
    public var name: String
    /// Seconds from the start of the request.
    public var offset: Double
    /// Seconds.
    public var duration: Double
    /// How many spans it is below the first one.
    public var depth: Int
    public var failed: Bool
    public var kind: GraphSpanKind
    /// For an HTTP request or call.
    public var http: GraphHTTPDetails?

    public init(id: String, service: String, name: String, offset: Double, duration: Double, depth: Int, failed: Bool,
                kind: GraphSpanKind, http: GraphHTTPDetails? = nil) {
        self.id = id
        self.service = service
        self.name = name
        self.offset = offset
        self.duration = duration
        self.depth = depth
        self.failed = failed
        self.kind = kind
        self.http = http
    }
}

/// The details of an HTTP request or call: its method, URL with its query, status and headers, the
/// secret ones `[hidden]` (docs/engine-api.md › GraphHTTPDetails).
public struct GraphHTTPDetails: Codable, Sendable, Hashable {
    public var method: String
    public var url: String
    public var status: Int?
    public var requestHeaders: [GraphField]
    public var responseHeaders: [GraphField]

    public init(method: String, url: String, status: Int? = nil, requestHeaders: [GraphField] = [],
                responseHeaders: [GraphField] = []) {
        self.method = method
        self.url = url
        self.status = status
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
    }
}

/// A header, or a field of a log line (docs/engine-api.md › GraphField).
public struct GraphField: Codable, Sendable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A log line of a request: an event of one of its spans with the attribute `log.level`
/// (docs/engine-api.md › GraphLogLine).
public struct GraphLogLine: Codable, Sendable, Hashable, Identifiable {
    /// `<span id>/<index of the event in the span>`.
    public var id: String
    public var time: Date
    /// Seconds from the start of the request.
    public var offset: Double
    public var service: String
    public var level: String
    public var message: String
    public var fields: [GraphField]

    public init(id: String, time: Date, offset: Double, service: String, level: String, message: String, fields: [GraphField] = []) {
        self.id = id
        self.time = time
        self.offset = offset
        self.service = service
        self.level = level
        self.message = message
        self.fields = fields
    }
}
