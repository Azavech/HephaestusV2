import Foundation
import Testing
@testable import HephaestusCore

/// A request as Jaeger answers it: GET /page through the three services and both Clusters.
func pageTrace(id: String, start: Int64) -> JaegerTrace {
    JaegerTrace(traceID: id, spans: [
        JaegerSpan(spanID: "s5", operationName: "SELECT value_values", parent: "s4", startTime: start + 4000, duration: 800,
                   tags: ["span.kind": "client", "db.system.name": "postgresql"], service: "value"),
        JaegerSpan(spanID: "s1", operationName: "GET /page", parent: "outside", startTime: start, duration: 9000,
                   tags: ["span.kind": "server", "http.route": "/page", "http.request.method": "GET", "http.status_code": "200"],
                   service: "front"),
        JaegerSpan(spanID: "s2", operationName: "GET /greeting", parent: "s1", startTime: start + 500, duration: 8000,
                   tags: ["span.kind": "client", "server.address": "back"], service: "front"),
        JaegerSpan(spanID: "s3", operationName: "GET /greeting", parent: "s2", startTime: start + 1000, duration: 7000,
                   tags: ["span.kind": "server", "http.route": "/greeting"], service: "back"),
        JaegerSpan(spanID: "s4", operationName: "GET /value", parent: "s3", startTime: start + 1500, duration: 4000,
                   tags: ["span.kind": "client", "server.address": "value.poc.svc.cluster.local"], service: "back"),
        JaegerSpan(spanID: "s6", operationName: "INSERT back_values", parent: "s3", startTime: start + 6000, duration: 900,
                   tags: ["span.kind": "client", "db.system.name": "postgresql", "otel.status_code": "ERROR"], service: "back"),
    ])
}

/// The check of the bucket at startup: a trace whose first span is an S3 client span.
func startupTrace(start: Int64) -> JaegerTrace {
    JaegerTrace(traceID: "0f", spans: [
        JaegerSpan(spanID: "h1", operationName: "S3 HeadBucket", startTime: start, duration: 300,
                   tags: ["span.kind": "client", "rpc.system": "aws-api", "rpc.service": "S3"], service: "back"),
    ])
}

@Suite("Graph analysis")
struct GraphAnalysisTests {
    static let graph = GraphFixtures.graph
    /// 2026-11-06 03:00:00 UTC, in microseconds.
    static let start: Int64 = 1_793_934_000_000_000

    static func date(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    @Test("Each client span is a call of the arrow it matches, and only the spans that started in the window count")
    func counts() {
        let window = DateInterval(start: Self.date(Self.start - 1), end: Self.date(Self.start + 60_000_000))
        let traces = [
            pageTrace(id: "01a1", start: Self.start),
            pageTrace(id: "01a2", start: Self.start + 1_000_000),
            startupTrace(start: Self.start + 2_000_000),
            // before the window
            pageTrace(id: "01a0", start: Self.start - 10_000_000),
        ]
        #expect(GraphAnalysis.counts(traces: traces, graph: Self.graph, window: window) == [
            "service/front->service/back": 2,
            "service/back->service/value": 2,
            "service/value->cluster/value": 2,
            "service/back->cluster/back": 2,
            "service/back->bucket/back": 1,
        ])
    }

    @Test("A request has its correlation id, start, first service and route, status, duration and the boxes it hit")
    func request() throws {
        let request = try #require(GraphAnalysis.request(of: pageTrace(id: "1a1be54d9f17fc39cc0368b607cbddf", start: Self.start),
                                                         graph: Self.graph))
        #expect(request.id == "01a1be54d9f17fc39cc0368b607cbddf")
        #expect(request.start == Self.date(Self.start))
        #expect(request.firstService == "front")
        #expect(request.route == "GET /page")
        #expect(request.status == 200)
        #expect(request.duration == 0.009)
        #expect(request.boxes == ["cluster/back", "cluster/value", "service/back", "service/front", "service/value"])
        #expect(request.itemsHit == 5)
        #expect(request.arrows == [
            "service/back->cluster/back", "service/back->service/value", "service/front->service/back", "service/value->cluster/value",
        ])
    }

    @Test("The timeline holds each span in the order it started, its start from the request, its duration and its depth")
    func timeline() throws {
        let detail = try #require(GraphAnalysis.detail(of: pageTrace(id: "01a1", start: Self.start), graph: Self.graph))
        #expect(detail.timeline.map(\.name) == ["GET /page", "GET /greeting", "GET /greeting", "GET /value", "SELECT value_values",
                                                "INSERT back_values"])
        #expect(detail.timeline.map(\.service) == ["front", "front", "back", "back", "value", "back"])
        #expect(detail.timeline.map(\.offset) == [0, 0.0005, 0.001, 0.0015, 0.004, 0.006])
        #expect(detail.timeline.map(\.duration) == [0.009, 0.008, 0.007, 0.004, 0.0008, 0.0009])
        #expect(detail.timeline.map(\.depth) == [0, 1, 2, 3, 4, 3])
        #expect(detail.timeline.map(\.failed) == [false, false, false, false, false, true])
    }

    @Test("A trace whose first span is not a server span is not a request")
    func startup() {
        #expect(GraphAnalysis.request(of: startupTrace(start: Self.start), graph: Self.graph) == nil)
        #expect(GraphAnalysis.detail(of: startupTrace(start: Self.start), graph: Self.graph) == nil)
    }

    @Test("The requests of the window are every request that started in it, newest first, each once, but the last 3 seconds")
    func requests() {
        let window = DateInterval(start: Self.date(Self.start), end: Self.date(Self.start + 60_000_000))
        let traces = [
            // settling: listed at the next read
            pageTrace(id: "01a9", start: Self.start + 58_000_000),
            pageTrace(id: "01a1", start: Self.start + 1_000_000),
            pageTrace(id: "01a3", start: Self.start + 3_000_000),
            pageTrace(id: "01a2", start: Self.start + 2_000_000),
            pageTrace(id: "01a3", start: Self.start + 3_000_000),
            pageTrace(id: "01a0", start: Self.start - 1_000_000),
            startupTrace(start: Self.start + 4_000_000),
        ]
        #expect(GraphAnalysis.requests(traces: traces, graph: Self.graph, window: window).map(\.id) == [
            "000000000000000000000000000001a3",
            "000000000000000000000000000001a2",
            "000000000000000000000000000001a1",
        ])
    }

    @Test("The requests matching a text are the ones whose id holds it, any part, any case, in their order; all for an empty text")
    func matching() {
        let window = DateInterval(start: Self.date(Self.start), end: Self.date(Self.start + 60_000_000))
        let traces = [
            pageTrace(id: "7c41aa", start: Self.start + 1_000_000),
            pageTrace(id: "7c42bb", start: Self.start + 2_000_000),
            pageTrace(id: "9d41cc", start: Self.start + 3_000_000),
        ]
        let requests = GraphAnalysis.requests(traces: traces, graph: Self.graph, window: window)
        let cases: [(name: String, text: String, ids: [String])] = [
            ("empty text", "", ["000000000000000000000000009d41cc", "000000000000000000000000007c42bb", "000000000000000000000000007c41aa"]),
            ("blank text", "  ", ["000000000000000000000000009d41cc", "000000000000000000000000007c42bb", "000000000000000000000000007c41aa"]),
            ("start of the id", "00000000000000000000000000" + "7c", ["000000000000000000000000007c42bb", "000000000000000000000000007c41aa"]),
            ("part of the id", "7c4", ["000000000000000000000000007c42bb", "000000000000000000000000007c41aa"]),
            ("end of the id", "41cc", ["000000000000000000000000009d41cc"]),
            ("upper case and spaces", " 7C42BB ", ["000000000000000000000000007c42bb"]),
            ("whole id", "000000000000000000000000007c41aa", ["000000000000000000000000007c41aa"]),
            ("no match", "ffff", []),
        ]
        for testCase in cases {
            #expect(GraphAnalysis.matching(requests, text: testCase.text).map(\.id) == testCase.ids, "\(testCase.name)")
        }
    }

    @Test("A correlation id is the trace id of Jaeger in lowercase, padded to 32 hex digits")
    func correlationID() {
        #expect(GraphAnalysis.correlationID("01A1BE54D9F17FC39CC0368B607CBDDF") == "01a1be54d9f17fc39cc0368b607cbddf")
        #expect(GraphAnalysis.correlationID("1a1be54d9f17fc39cc0368b607cbddf") == "01a1be54d9f17fc39cc0368b607cbddf")
    }

    @Test("The OTLP json of Jaeger's v3 API is read into traces, the service of each span the one of its resource")
    func otlp() throws {
        let json = """
        {"result":{"resourceSpans":[
        {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"front"}}]},
         "scopeSpans":[{"scope":{"name":"github.com/example/yc-shared/ginserver"},"spans":[
          {"traceId":"01a1be54d9f17fc39cc0368b607cbddf","spanId":"7f00000000000001","parentSpanId":"0123456789abcdef","flags":1,"name":"GET /page",
           "kind":2,"startTimeUnixNano":"1793934000000000000","endTimeUnixNano":"1793934000009000000",
           "attributes":[{"key":"http.route","value":{"stringValue":"/page"}},{"key":"http.status_code","value":{"intValue":"200"}}],"status":{}}]}]},
        {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"back"}}]},
         "scopeSpans":[{"scope":{"name":"github.com/example/yc-shared/s3store"},"spans":[
          {"traceId":"01a1be54d9f17fc39cc0368b607cbddf","spanId":"7f00000000000002","parentSpanId":"7f00000000000001","name":"S3 PutObject",
           "kind":3,"startTimeUnixNano":"1793934000001000000","endTimeUnixNano":"1793934000006000000",
           "attributes":[{"key":"rpc.system","value":{"stringValue":"aws-api"}},{"key":"rpc.service","value":{"stringValue":"S3"}},
                         {"key":"error","value":{"boolValue":true}},{"key":"ratio","value":{"doubleValue":0.5}},{"key":"count","value":{"intValue":3}}],
           "status":{"code":2}}]}]}
        ]}}
        """
        let answer = try JSONDecoder().decode(OTLPAnswer.self, from: Data(json.utf8))
        let trace = try #require(answer.traces.first)
        let root = try #require(trace.spans.first { $0.operationName == "GET /page" })
        let put = try #require(trace.spans.first { $0.operationName == "S3 PutObject" })
        #expect(answer.traces.count == 1)
        #expect(trace.traceID == "01a1be54d9f17fc39cc0368b607cbddf")
        #expect(trace.service(of: root) == "front")
        #expect(trace.service(of: put) == "back")
        #expect(root.kind == "server")
        #expect(root.tag("http.status_code") == "200")
        #expect(root.startTime == 1_793_934_000_000_000)
        #expect(root.duration == 9000)
        #expect(root.parentID == "0123456789abcdef")
        #expect(put.kind == "client")
        #expect(put.parentID == "7f00000000000001")
        #expect(put.tag("otel.status_code") == "ERROR")
        #expect(put.tag("error") == "true")
        #expect(put.tag("ratio") == "0.5")
        #expect(put.tag("count") == "3")
        let request = try #require(GraphAnalysis.request(of: trace, graph: Self.graph))
        #expect(request.status == 200)
        #expect(request.arrows == ["service/back->bucket/back"])
        #expect(request.boxes == ["bucket/back", "service/back", "service/front"])
    }

    @Test("The events and header arrays of Jaeger are read: log lines by time, HTTP details, the calls of each arrow in the request")
    func otlpDetails() throws {
        let json = """
        {"result":{"resourceSpans":[
          {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"front"}}]},
           "scopeSpans":[{"spans":[
             {"traceId":"01a1be7e5c6178d1ab7e679d86aa4e71","spanId":"7f00000000000001","name":"GET /page","kind":2,
              "startTimeUnixNano":"1793934000000000000","endTimeUnixNano":"1793934000009000000",
              "attributes":[{"key":"http.request.method","value":{"stringValue":"GET"}},{"key":"http.route","value":{"stringValue":"/page"}},
                            {"key":"url.path","value":{"stringValue":"/page"}},{"key":"url.query","value":{"stringValue":"lang=fr"}},
                            {"key":"http.status_code","value":{"intValue":"200"}},
                            {"key":"http.request.header.accept","value":{"arrayValue":{"values":[{"stringValue":"application/json"},{"stringValue":"text/plain"}]}}},
                            {"key":"http.request.header.authorization","value":{"arrayValue":{"values":[{"stringValue":"[hidden]"}]}}},
                            {"key":"http.response.header.x-correlation-id","value":{"arrayValue":{"values":[{"stringValue":"01a1be7e5c6178d1ab7e679d86aa4e71"}]}}}],
              "events":[{"timeUnixNano":"1793934000008000000","name":"request handled",
                         "attributes":[{"key":"log.level","value":{"stringValue":"info"}},{"key":"status","value":{"stringValue":"200"}}]},
                        {"timeUnixNano":"1793934000001000000","name":"not a log line","attributes":[]}]},
             {"traceId":"01a1be7e5c6178d1ab7e679d86aa4e71","spanId":"7f00000000000002","parentSpanId":"7f00000000000001","name":"GET /greeting",
              "kind":3,"startTimeUnixNano":"1793934000001000000","endTimeUnixNano":"1793934000007000000",
              "attributes":[{"key":"http.request.method","value":{"stringValue":"GET"}},{"key":"server.address","value":{"stringValue":"back"}},
                            {"key":"url.full","value":{"stringValue":"http://back:8080/greeting"}}]}]}]},
          {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"back"}}]},
           "scopeSpans":[{"spans":[
             {"traceId":"01a1be7e5c6178d1ab7e679d86aa4e71","spanId":"7f00000000000003","parentSpanId":"7f00000000000002","name":"GET /greeting","kind":2,
              "startTimeUnixNano":"1793934000002000000","endTimeUnixNano":"1793934000006000000",
              "attributes":[{"key":"http.request.method","value":{"stringValue":"GET"}}],
              "events":[{"timeUnixNano":"1793934000005000000","name":"value recorded","attributes":[{"key":"log.level","value":{"stringValue":"info"}}]}]},
             {"traceId":"01a1be7e5c6178d1ab7e679d86aa4e71","spanId":"7f00000000000004","parentSpanId":"7f00000000000003","name":"INSERT back_values",
              "kind":3,"startTimeUnixNano":"1793934000003000000","endTimeUnixNano":"1793934000004000000",
              "attributes":[{"key":"db.system.name","value":{"stringValue":"postgresql"}}]},
             {"traceId":"01a1be7e5c6178d1ab7e679d86aa4e71","spanId":"7f00000000000005","parentSpanId":"7f00000000000003","name":"INSERT back_values",
              "kind":3,"startTimeUnixNano":"1793934000004000000","endTimeUnixNano":"1793934000005000000",
              "attributes":[{"key":"db.system.name","value":{"stringValue":"postgresql"}}]}]}]}
        ]}}
        """
        let trace = try #require(try JSONDecoder().decode(OTLPAnswer.self, from: Data(json.utf8)).traces.first)
        let detail = try #require(GraphAnalysis.detail(of: trace, graph: Self.graph))
        #expect(detail.request.arrowCalls == ["service/front->service/back": 1, "service/back->cluster/back": 2])
        #expect(detail.logs.map(\.message) == ["value recorded", "request handled"])
        #expect(detail.logs.map(\.service) == ["back", "front"])
        #expect(detail.logs.last?.fields == [GraphField(name: "status", value: "200")])
        #expect(abs((detail.logs.first?.offset ?? 0) - 0.005) < 0.000001)
        #expect(detail.timeline.map(\.kind) == [.httpRequest, .httpCall, .httpRequest, .sql, .sql])
        let page = try #require(detail.timeline.first?.http)
        #expect(page.url == "/page?lang=fr")
        #expect(page.status == 200)
        #expect(page.requestHeaders == [GraphField(name: "accept", value: "application/json, text/plain"),
                                        GraphField(name: "authorization", value: "[hidden]")])
        #expect(page.responseHeaders == [GraphField(name: "x-correlation-id", value: "01a1be7e5c6178d1ab7e679d86aa4e71")])
        #expect(detail.timeline[1].http?.url == "http://back:8080/greeting")
        #expect(detail.timeline[3].http == nil)
    }

    @Test("The kinds of span: redis, S3, Kafka published and consumed, and any other")
    func kinds() {
        func kind(_ tags: [String: String]) -> GraphSpanKind {
            GraphAnalysis.kind(of: JaegerSpan(spanID: "a", operationName: "x", startTime: 0, duration: 0, tags: tags, service: "back"))
        }
        #expect(kind(["span.kind": "client", "db.system.name": "redis"]) == .redis)
        #expect(kind(["span.kind": "client", "db.system.name": "mysql"]) == .sql)
        #expect(kind(["span.kind": "client", "rpc.service": "S3"]) == .s3)
        #expect(kind(["span.kind": "producer"]) == .publish)
        #expect(kind(["span.kind": "consumer"]) == .consume)
        #expect(kind(["span.kind": "server"]) == .other)
        #expect(kind(["span.kind": "client"]) == .other)
        #expect(kind(["span.kind": "internal"]) == .other)
    }

    @Test("A header value is read as Jaeger answers it, the json of its values, or as text")
    func headerValue() {
        #expect(GraphAnalysis.headerValue(#"["application/json"]"#) == "application/json")
        #expect(GraphAnalysis.headerValue(#"["gzip","br"]"#) == "gzip, br")
        #expect(GraphAnalysis.headerValue("application/json, text/plain") == "application/json, text/plain")
        #expect(GraphAnalysis.headerValue("[not json") == "[not json")
    }

    @Test("An error of the v3 API is read")
    func otlpError() throws {
        let json = #"{"error":{"httpCode":400,"message":"malformed parameter trace_id: TraceID cannot be longer than 32 hex characters: 01a1be58-4c7c"}}"#
        let answer = try JSONDecoder().decode(OTLPAnswer.self, from: Data(json.utf8))
        #expect(answer.traces.isEmpty)
        #expect(answer.error?.httpCode == 400)
    }

    @Test("A search window is written in RFC 3339 with its fraction of second, in UTC")
    func timestamp() {
        #expect(JaegerClient.timestamp(Date(timeIntervalSince1970: 1_793_934_000.25)) == "2026-11-06T03:00:00.250Z")
    }

    @Test("The requests per minute count each request in the minute of the window it started in, counted from its end")
    func requestsPerMinute() {
        let end = Self.date(Self.start + 300_000_000)
        let window = GraphWindow.fiveMinutes.interval(endingAt: end)
        func request(_ secondsBeforeEnd: Double) -> GraphRequestSummary {
            GraphRequestSummary(id: "\(secondsBeforeEnd)", start: end.addingTimeInterval(-secondsBeforeEnd), firstService: "front",
                                route: "GET /page", duration: 0)
        }
        let requests = [request(1), request(59.9), request(60), request(61), request(299), request(301)]
        #expect(GraphAnalysis.requestsPerMinute(requests, window: window) == [1, 0, 0, 2, 2])
        #expect(GraphAnalysis.requestsPerMinute([], window: GraphWindow.week.interval(endingAt: end)).count == 7 * 24 * 60)
    }

    @Test("A search that returns 10,000 traces is made again on each half of its window, until none is full")
    func halving() async throws {
        let recorder = FetchRecorder()
        let client = JaegerClient(port: 1) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let min = items.first { $0.name == "query.start_time_min" }?.value ?? ""
            await recorder.record(min)
            let count = await recorder.calls == 1 ? JaegerClient.searchDepth : 1
            let spans = (0..<count).map { index in
                #"{"traceId":"\#(String(format: "%032x", index + (min.hasSuffix("00.000Z") ? 0 : 50_000)))","spanId":"1","name":"GET /","kind":2,"startTimeUnixNano":"0","endTimeUnixNano":"0"}"#
            }
            return Data(#"{"result":{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"front"}}]},"scopeSpans":[{"spans":[\#(spans.joined(separator: ","))]}]}]}}"#.utf8)
        }
        let window = DateInterval(start: Self.date(Self.start), duration: 60)
        let traces = try await client.traces(service: "front", window: window)
        #expect(await recorder.calls == 3)
        #expect(traces.count == 2)
    }

    @Test("Jaeger's 404 for a service without spans gives no trace; another error fails")
    func searchErrors() async throws {
        let notFound = JaegerClient(port: 1) { _ in Data(#"{"error":{"httpCode":404,"message":"trace not found"}}"#.utf8) }
        #expect(try await notFound.traces(service: "front", window: DateInterval(start: Self.date(Self.start), duration: 60)).isEmpty)
        let failing = JaegerClient(port: 1) { _ in Data(#"{"error":{"httpCode":500,"message":"storage is down"}}"#.utf8) }
        await #expect(throws: JaegerClient.Failure.self) {
            _ = try await failing.traces(service: "front", window: DateInterval(start: Self.date(Self.start), duration: 60))
        }
        let refused = JaegerClient(port: 1) { _ in Data(#"{"error":{"httpCode":400,"message":"TraceID cannot be longer than 32 hex characters"}}"#.utf8) }
        #expect(try await refused.trace(id: "01a1-be") == nil)
    }
}

/// The calls a fake Jaeger received.
private actor FetchRecorder {
    private(set) var calls = 0
    private(set) var starts: [String] = []

    func record(_ start: String) {
        calls += 1
        starts.append(start)
    }
}
