import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// The graph of three services: `front` calls `back`, which calls `value` and has a Cluster.
private enum GraphTestData {
    static let front = GraphBox(kind: .service, name: "front")
    static let back = GraphBox(kind: .service, name: "back")
    static let value = GraphBox(kind: .service, name: "value")
    static let cluster = GraphBox(kind: .cluster, name: "back")
    static let arrows = [
        GraphArrow(from: back, to: value), GraphArrow(from: back, to: cluster), GraphArrow(from: front, to: back),
    ]
    static let end = Date(timeIntervalSince1970: 1_793_934_300)

    static func request(_ id: String, status: Int? = 200, secondsBeforeEnd: Double = 10) -> GraphRequestSummary {
        GraphRequestSummary(id: id, start: end.addingTimeInterval(-secondsBeforeEnd), firstService: "front", route: "GET /page",
                            status: status, duration: 0.012, boxes: ["service/back", "service/front"],
                            arrows: ["service/front->service/back"], arrowCalls: ["service/front->service/back": 1])
    }

    static func snapshot(calls: [String: Int] = [:], requests: [GraphRequestSummary] = [], jaegerError: String? = nil) -> GraphSnapshot {
        GraphSnapshot(environment: "staging", namespace: "orders", window: .fiveMinutes, start: end.addingTimeInterval(-300), end: end,
                      boxes: [back, front, value, cluster], arrows: arrows, calls: calls, requests: requests, tracesRead: requests.count,
                      jaegerSeconds: 0.25, jaegerError: jaegerError)
    }
}

@MainActor
@Suite("Graph section state")
struct GraphSectionStateTests {
    @Test("A click on a service focuses on it; a right-click goes back; Show All goes back to the whole graph")
    func navigation() {
        let state = GraphSectionState()
        state.apply(GraphTestData.snapshot(), ownService: nil)
        #expect(state.scopes.isEmpty)
        #expect(state.shownGraph?.boxes.count == 4)
        state.focus(on: GraphTestData.back)
        #expect(state.focusID == "service/back")
        #expect(Set(state.shownGraph?.boxes.map(\.id) ?? []) == ["service/back", "service/front", "service/value", "cluster/back"])
        state.focus(on: GraphTestData.cluster)
        #expect(state.scopes.count == 1)
        state.focus(on: GraphTestData.value)
        #expect(state.focusID == "service/value")
        #expect(Set(state.shownGraph?.boxes.map(\.id) ?? []) == ["service/back", "service/value"])
        state.back()
        #expect(state.focusID == "service/back")
        state.showAll()
        #expect(state.scopes.isEmpty)
        state.back()
        #expect(state.scopes.isEmpty)
    }

    @Test("A request shows what it hit with the Client, its own counts; it replaces a request shown and goes back to the focus")
    func requestView() throws {
        let state = GraphSectionState()
        let request = GraphTestData.request("00000000000000000000000000000abc")
        state.apply(GraphTestData.snapshot(calls: ["service/back->service/value": 4], requests: [request]), ownService: nil)
        state.focus(on: GraphTestData.back)
        state.open(request)
        #expect(state.selected == request)
        let graph = try #require(state.shownGraph)
        #expect(graph.boxes.map(\.id) == ["client/Client", "service/back", "service/front"])
        #expect(graph.arrows.map(\.id) == ["client/Client->service/front", "service/front->service/back"])
        #expect(state.shownCounts == ["service/front->service/back": 1, "client/Client->service/front": 1])
        #expect(state.label(of: try #require(state.clientArrow)) == "GET /page")
        state.open(GraphTestData.request("00000000000000000000000000000abd"))
        #expect(state.scopes.count == 2)
        state.back()
        #expect(state.focusID == "service/back")
        #expect(state.selected == nil)
    }

    @Test("A sub project's Graph opens focused on the service named like its folder, once")
    func ownService() {
        let state = GraphSectionState()
        state.apply(GraphTestData.snapshot(), ownService: "back")
        #expect(state.focusID == "service/back")
        state.back()
        state.apply(GraphTestData.snapshot(), ownService: "back")
        #expect(state.scopes.isEmpty)
        let other = GraphSectionState()
        other.apply(GraphTestData.snapshot(), ownService: "elsewhere")
        #expect(other.scopes.isEmpty)
    }

    @Test("The Correlation ID field filters the list, suggests the newest ids and chooses a whole id typed")
    func correlationField() {
        let state = GraphSectionState()
        let requests = [GraphTestData.request("00000000000000000000000000000abc"), GraphTestData.request("00000000000000000000000000000abd"),
                        GraphTestData.request("00000000000000000000000000000fff")]
        state.apply(GraphTestData.snapshot(requests: requests), ownService: nil)
        state.searchText = "AB"
        #expect(state.visibleRequests.map(\.id) == ["00000000000000000000000000000abc", "00000000000000000000000000000abd"])
        #expect(state.suggestions.count == 2)
        state.searchText = "00000000000000000000000000000abd"
        #expect(state.selected?.id == "00000000000000000000000000000abd")
        #expect(state.suggestions.isEmpty)
    }

    @Test("The Service field suggests services, focuses on a whole name, and says when none matches")
    func serviceField() {
        let state = GraphSectionState()
        state.apply(GraphTestData.snapshot(), ownService: nil)
        state.serviceText = "a"
        #expect(state.serviceSuggestions.map(\.name) == ["back", "value"])
        state.serviceText = "VALUE"
        #expect(state.focusID == "service/value")
        state.serviceText = "nothing"
        state.findService()
        #expect(state.serviceMessage == GraphSectionState.serviceNotFound)
        #expect(GraphSectionState.serviceNotFound == "no service found for this name")
        #expect(GraphSectionState.notFound == "no request found for this correlation id")
    }

    @Test("Find looks an id up in Jaeger when the window does not hold it, and says when nothing matches")
    func find() async {
        let state = GraphSectionState()
        state.apply(GraphTestData.snapshot(), ownService: nil)
        state.searchText = "0abc"
        await state.find { id in
            #expect(id == "0abc")
            return GraphRequestDetail(request: GraphTestData.request("0000000000000000000000000000aabc"))
        }
        #expect(state.selected?.id == "0000000000000000000000000000aabc")
        state.searchText = "ffff"
        await state.find { _ in throw EngineError(.notFound, "Request ffff not found.") }
        #expect(state.searchMessage == GraphSectionState.notFound)
    }

    @Test("A request a Failed requests widget asked for opens once the graph is read")
    func pending() async {
        let state = GraphSectionState()
        state.pendingRequestID = "00000000000000000000000000000abc"
        await state.openPending { _ in Issue.record("no lookup before the graph"); throw EngineError(.notFound, "") }
        #expect(state.pendingRequestID != nil)
        state.apply(GraphTestData.snapshot(requests: [GraphTestData.request("00000000000000000000000000000abc")]), ownService: nil)
        await state.openPending { _ in Issue.record("the window holds it"); throw EngineError(.notFound, "") }
        #expect(state.selected?.id == "00000000000000000000000000000abc")
        #expect(state.pendingRequestID == nil)
    }

    @Test("The status line: the read's text, or Jaeger's failure, then the message of a source")
    func statusLine() {
        var snapshot = GraphTestData.snapshot(requests: [GraphTestData.request("abc")])
        #expect(GraphStatus.text(of: snapshot).hasPrefix("1 requests in the window, 1 traces read in 0.2 s, at "))
        snapshot.jaegerError = "Jaeger cannot be reached: Environment “staging” has no Jaeger."
        snapshot.sourceErrors = ["The sources of front cannot be read: timeout."]
        #expect(GraphStatus.text(of: snapshot)
            == "Jaeger cannot be reached: Environment “staging” has no Jaeger. · The sources of front cannot be read: timeout.")
        #expect(GraphFormat.milliseconds(0.0124) == "12.4 ms")
    }
}

@MainActor
@Suite("Dashboard graph widgets")
struct DashboardGraphWidgetsTests {
    @Test("Busiest calls: the arrows with calls, the busiest first, equal counts in the graph's order, at most Number")
    func busiestCalls() {
        let snapshot = GraphTestData.snapshot(calls: ["service/front->service/back": 3, "service/back->cluster/back": 3,
                                                      "service/back->service/value": 9])
        let rows = DashboardGraph.busiestCalls(snapshot, limit: 5)
        #expect(rows.map(\.arrow.id) == ["service/back->service/value", "service/back->cluster/back", "service/front->service/back"])
        #expect(rows.map(\.count) == [9, 3, 3])
        #expect(DashboardGraph.busiestCalls(snapshot, limit: 1).count == 1)
        #expect(DashboardGraph.busiestCalls(GraphTestData.snapshot(), limit: 5).isEmpty)
        #expect(DashboardGraph.label(of: GraphArrow(from: GraphTestData.back, to: GraphTestData.cluster)) == "back → back postgres Cluster")
        #expect(DashboardGraph.label(of: GraphArrow(from: GraphTestData.front, to: GraphTestData.back)) == "front → back")
    }

    @Test("Failed requests: the newest answered 400 or above, at most Number")
    func failedRequests() {
        let requests = [GraphTestData.request("a", status: 500, secondsBeforeEnd: 5), GraphTestData.request("b", status: 200),
                        GraphTestData.request("c", status: 404, secondsBeforeEnd: 20), GraphTestData.request("d", status: nil),
                        GraphTestData.request("e", status: 400, secondsBeforeEnd: 30)]
        let snapshot = GraphTestData.snapshot(requests: requests)
        #expect(DashboardGraph.failedRequests(snapshot, limit: 5).map(\.id) == ["a", "c", "e"])
        #expect(DashboardGraph.failedRequests(snapshot, limit: 2).map(\.id) == ["a", "c"])
    }

    @Test("Number: 5 by default, 1 to 20, a value written by hand outside it shows 1 or 20 rows")
    func number() {
        #expect(DashboardGraph.rowLimit(of: DashboardWidget(kind: .busiestCalls)) == 5)
        #expect(DashboardGraph.rowLimit(of: DashboardWidget(kind: .busiestCalls, count: 0)) == 1)
        #expect(DashboardGraph.rowLimit(of: DashboardWidget(kind: .failedRequests, count: 40)) == 20)
        #expect(DashboardEdits.steppingCount(of: DashboardWidget(kind: .failedRequests, count: 20), by: 1) == 20)
        #expect(DashboardEdits.steppingCount(of: DashboardWidget(kind: .failedRequests, count: 5), by: -1) == 4)
    }

    @Test("A click on a failed request asks the Graph of the project to open it")
    func pendingRequest() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.projectID = "API"
        #expect(window.graphState(of: "API") == nil)
        let state = window.ensureGraphState(of: "API")
        state.pendingRequestID = "abc"
        #expect(window.graphState(of: "API") === state)
        #expect(window.ensureGraphState(of: "API").pendingRequestID == "abc")
    }
}
