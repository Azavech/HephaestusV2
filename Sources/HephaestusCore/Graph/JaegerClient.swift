import Foundation

/// Jaeger's v3 query API, through a port forward on 127.0.0.1 (docs/graph.md › Reading the
/// traces): the traces are searched and read with `/api/v3/traces`, in OTLP json.
struct JaegerClient: Sendable {
    /// Gets the body of a URL; the engine's uses `URLSession`, tests give their own.
    typealias Fetch = @Sendable (URL) async throws -> Data

    let base: URL
    let fetch: Fetch

    init(port: Int, fetch: @escaping Fetch = JaegerClient.urlSessionFetch) {
        base = URL(string: "http://127.0.0.1:\(port)")!
        self.fetch = fetch
    }

    struct Failure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    /// The most traces one search returns: Jaeger refuses more (`search depth must be in [0, 10000]`).
    static let searchDepth = 10_000
    /// The longest a request to Jaeger waits for its answer.
    static let timeout: TimeInterval = 30

    /// Every trace holding a span of `service` that started in the window. A search that returns
    /// `searchDepth` traces may have left some out: its window is searched again in two halves.
    func traces(service: String, window: DateInterval) async throws -> [JaegerTrace] {
        let found = try await search(service: service, window: window)
        guard found.count >= Self.searchDepth, window.duration > 0.001 else { return found }
        let middle = window.start.addingTimeInterval(window.duration / 2)
        var merged: [String: JaegerTrace] = [:]
        for half in [DateInterval(start: window.start, end: middle), DateInterval(start: middle, end: window.end)] {
            for trace in try await traces(service: service, window: half) {
                merged[trace.traceID] = trace
            }
        }
        return Array(merged.values)
    }

    private func search(service: String, window: DateInterval) async throws -> [JaegerTrace] {
        var components = URLComponents(url: base.appending(path: "api/v3/traces"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query.service_name", value: service),
            URLQueryItem(name: "query.start_time_min", value: Self.timestamp(window.start)),
            URLQueryItem(name: "query.start_time_max", value: Self.timestamp(window.end)),
            URLQueryItem(name: "query.search_depth", value: String(Self.searchDepth)),
        ]
        let answer = try await get(components.url!)
        if let error = answer.error {
            // A service that has sent no span yet is not an error of the window.
            if error.httpCode == 404 {
                return []
            }
            throw Failure(message: error.message)
        }
        return answer.traces
    }

    /// The trace of a correlation id, whenever it started within the days Jaeger keeps; nil when
    /// Jaeger has none or refuses the id (an id with hyphens: `TraceID cannot be longer than 32 hex
    /// characters`).
    func trace(id: String) async throws -> JaegerTrace? {
        guard let path = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: base.absoluteString + "/api/v3/traces/" + path) else { return nil }
        let answer = try await get(url)
        if let error = answer.error, error.httpCode >= 500 {
            throw Failure(message: error.message)
        }
        return answer.traces.first
    }

    /// RFC 3339 with the fraction of second, in UTC.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    private func get(_ url: URL) async throws -> OTLPAnswer {
        let data = try await fetch(url)
        do {
            return try JSONDecoder().decode(OTLPAnswer.self, from: data)
        } catch {
            throw Failure(message: "Jaeger answered something else than OTLP json")
        }
    }

    /// The body of a GET with an ephemeral session, whatever its status: Jaeger answers its errors
    /// in json.
    static let urlSessionFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, _) = try await session.data(for: request)
        return data
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()
}
