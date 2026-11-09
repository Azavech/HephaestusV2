// OWNER: ui-graph — the state of the Graph section of one window and project (docs/graph.md).
import Foundation
import HephaestusCore

/// The state of the Graph section for one window and project (docs/ui.md › WindowState,
/// `graphState`): the last graph read, the time window, the views opened one from the other, the
/// texts of the fields and the request chosen. It belongs to its window and is never encoded.
@MainActor @Observable
final class GraphSectionState {
    /// A view narrower than the whole graph: a service in focus, or the boxes and arrows a request
    /// hit (docs/graph.md › Navigation, › Request view).
    enum Scope: Equatable {
        case focus(String)
        case request(GraphRequestSummary)
    }

    /// The tabs under the request chosen.
    enum DetailTab: String, CaseIterable {
        case timeline = "Timeline"
        case log = "Log"
    }

    static let notFound = "no request found for this correlation id"
    static let serviceNotFound = "no service found for this name"
    /// How many ids and services the fields suggest.
    static let suggestionLimit = 10
    /// The time from the end of a read to the start of the next one.
    static let interval: Duration = .seconds(5)
    /// The client of the view of a request, the entry point.
    static let client = GraphBox(kind: .client, name: "Client")

    /// The time window of the section, `Last 5 minutes` by default; kept per window of the app and
    /// project while the app runs (docs/graph.md › Time window).
    var window: GraphWindow = .fiveMinutes
    /// The last read that succeeded; nil until the first one.
    private(set) var snapshot: GraphSnapshot?
    /// The engine's message when the last read failed, until a read succeeds.
    private(set) var failure: String?
    /// Where the boxes of the whole graph go.
    private(set) var layout: GraphLayout?
    /// The views opened one from the other, the last one shown; none: the whole graph.
    private(set) var scopes: [Scope] = []
    /// Where the boxes of the view shown go, laid out on their own; nil for the whole graph.
    private(set) var scopeLayout: GraphLayout?
    /// Asks the graph view to fit what it shows, each time it changes.
    private(set) var fitRequest = 0
    /// Whether the first graph of the project was shown: a sub project's Graph opens focused on its
    /// own service then (docs/graph.md › Sub projects).
    private var openedOnce = false

    /// The text of the Correlation ID field.
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            searchMessage = nil
            let id = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let request = requests.first(where: { $0.id == id }), selected?.id != id {
                open(request)
            }
        }
    }
    private(set) var searchMessage: String?
    /// The text of the Service field.
    var serviceText = "" {
        didSet {
            guard serviceText != oldValue else { return }
            serviceMessage = nil
            let typed = serviceText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let service = graph?.services(matching: typed).first(where: { $0.name.lowercased() == typed }) {
                focus(on: service)
            }
        }
    }
    private(set) var serviceMessage: String?

    var detailTab: DetailTab = .timeline
    /// The HTTP span of the timeline whose details are shown.
    var selectedSpanID: String?
    /// The timeline and the log lines of the request chosen, once read.
    private(set) var detail: GraphRequestDetail?
    /// The engine's message when the read of the request chosen failed.
    private(set) var detailFailure: String?
    /// A request a Failed requests widget asked the section to open (docs/dashboard.md › Graph
    /// widgets); opened once the section has read its graph.
    var pendingRequestID: String?

    init() {}

    // MARK: What is shown

    /// The boxes and arrows of the last read.
    var graph: ServiceGraph? { snapshot?.graph }
    /// The requests of the window, newest first.
    var requests: [GraphRequestSummary] { snapshot?.requests ?? [] }
    /// The calls of each arrow in the window.
    var counts: [String: Int] { snapshot?.calls ?? [:] }

    /// The request shown in the bottom right pane: the last one opened of the views.
    var selected: GraphRequestSummary? {
        for scope in scopes.reversed() {
            if case .request(let request) = scope {
                return request
            }
        }
        return nil
    }

    /// The service in focus, when the view shown is a focus.
    var focusID: String? {
        if case .focus(let id) = scopes.last {
            return id
        }
        return nil
    }

    /// The arrow from the client to the first service of the request shown.
    var clientArrow: GraphArrow? {
        guard case .request(let request) = scopes.last else { return nil }
        return GraphArrow(from: Self.client, to: GraphBox(kind: .service, name: request.firstService))
    }

    /// What the view shown draws: the whole graph; the focus; or what the request hit, with its
    /// client.
    var shownGraph: ServiceGraph? {
        guard let graph else { return nil }
        guard let shown = shownSet else { return graph }
        var result = graph.keeping(boxes: shown.boxes, arrows: shown.arrows)
        if let clientArrow {
            result.boxes.insert(Self.client, at: 0)
            result.arrows.insert(clientArrow, at: 0)
        }
        return result
    }

    /// What the view shown keeps: the focus, or the boxes and arrows the request hit; nil for the
    /// whole graph.
    private var shownSet: (boxes: Set<String>, arrows: Set<String>)? {
        switch scopes.last {
        case .none:
            return nil
        case .focus(let id):
            guard let graph, let box = graph.box(id: id) else { return nil }
            return graph.focus(on: box)
        case .request(let request):
            return (Set(request.boxes), Set(request.arrows))
        }
    }

    /// The calls of each arrow shown: in the window, or in the request alone in its view.
    var shownCounts: [String: Int] {
        guard case .request(let request) = scopes.last else { return counts }
        var calls = request.arrowCalls
        if let clientArrow {
            calls[clientArrow.id] = 1
        }
        return calls
    }

    /// The layout of the view shown.
    var shownLayout: GraphLayout? {
        scopeLayout ?? layout
    }

    /// The requests the list shows: those of the window whose correlation id holds the text typed.
    var visibleRequests: [GraphRequestSummary] {
        GraphAnalysis.matching(requests, text: searchText)
    }

    /// The ids the Correlation ID field suggests: the 10 newest requests matching the text typed.
    var suggestions: [GraphRequestSummary] {
        let typed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty else { return [] }
        let matching = Array(visibleRequests.prefix(Self.suggestionLimit))
        // A whole id typed or chosen needs no suggestion.
        return matching.count == 1 && matching[0].id == typed ? [] : matching
    }

    /// The services the Service field suggests: the 10 first by name matching the text typed.
    var serviceSuggestions: [GraphBox] {
        guard let graph else { return [] }
        let typed = serviceText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = Array(graph.services(matching: typed).prefix(Self.suggestionLimit))
        return matching.count == 1 && matching[0].name.lowercased() == typed ? [] : matching
    }

    // MARK: Reads

    /// Takes the result of a read: the graph, laid out again when its boxes or arrows changed, and
    /// the requests opened, replaced by their newest summary. The first graph of a sub project
    /// opens focused on the service named like its folder.
    func apply(_ result: GraphSnapshot, ownService: String?) {
        let changed = snapshot?.graph != result.graph
        snapshot = result
        failure = nil
        if changed {
            layout = GraphLayout(graph: result.graph)
            scopes = scopes.filter { scope in
                if case .focus(let id) = scope { return result.graph.box(id: id) != nil }
                return true
            }
            relayoutScope()
            fitRequest += 1
        }
        if !openedOnce {
            openedOnce = true
            if let ownService, let box = result.graph.box(id: GraphBox(kind: .service, name: ownService).id) {
                focus(on: box)
            }
        }
        // A request opened is read again while it is in the window: its last spans can arrive
        // after it was opened.
        var replaced = false
        scopes = scopes.map { scope in
            if case .request(let request) = scope, let fresh = result.requests.first(where: { $0.id == request.id }), fresh != request {
                replaced = true
                return .request(fresh)
            }
            return scope
        }
        if replaced {
            relayoutScope()
        }
    }

    /// Takes a failed read: its message shows until a read succeeds.
    func fail(_ message: String) {
        failure = message
    }

    /// Takes the detail of the request chosen, or its failure.
    func applyDetail(_ result: Result<GraphRequestDetail, Error>, for id: String) {
        guard selected?.id == id else { return }
        switch result {
        case .success(let value):
            detail = value
            detailFailure = nil
        case .failure(let error):
            detailFailure = errorMessage(error)
        }
    }

    // MARK: Navigation (docs/graph.md › Navigation)

    /// Opens the focus on a service, and fits what stays to the view.
    func focus(on box: GraphBox) {
        guard box.kind == .service, focusID != box.id else { return }
        setScopes(scopes + [.focus(box.id)])
    }

    /// Opens the view of a request: only what it hit; a request shown is replaced by the new one.
    func open(_ request: GraphRequestSummary) {
        searchMessage = nil
        var next = scopes
        if case .request = next.last {
            next.removeLast()
        }
        next.append(.request(request))
        setScopes(next)
    }

    /// Back to the view before: the right-click.
    func back() {
        guard !scopes.isEmpty else { return }
        setScopes(Array(scopes.dropLast()))
    }

    /// Back to the whole graph at once: Show All.
    func showAll() {
        guard !scopes.isEmpty else { return }
        setScopes([])
    }

    /// Asks the graph view to fit what it shows.
    func fit() {
        fitRequest += 1
    }

    /// Return in the Service field: the service of the whole name typed, or the only one matching.
    func findService() {
        guard let graph else { return }
        let typed = serviceText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty else { return }
        let matching = graph.services(matching: typed)
        if let service = matching.first(where: { $0.name.lowercased() == typed }) ?? (matching.count == 1 ? matching.first : nil) {
            serviceMessage = nil
            focus(on: service)
        } else if matching.isEmpty {
            serviceMessage = Self.serviceNotFound
        }
    }

    /// Return or Find in the Correlation ID field: the request of the window, else Jaeger's.
    func find(_ lookUp: (String) async throws -> GraphRequestDetail) async {
        let id = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        searchMessage = nil
        guard !id.isEmpty else { return }
        if let request = requests.first(where: { $0.id == id }) {
            open(request)
            return
        }
        do {
            let found = try await lookUp(id)
            open(found.request)
            detail = found
            detailFailure = nil
        } catch let error as EngineError where error.code == .notFound {
            searchMessage = Self.notFound
        } catch {
            searchMessage = errorMessage(error)
        }
    }

    /// The request a Failed requests widget asked to open, once the graph is read: the one of the
    /// window, else Jaeger's.
    func openPending(_ lookUp: (String) async throws -> GraphRequestDetail) async {
        guard snapshot != nil, let id = pendingRequestID else { return }
        pendingRequestID = nil
        if let request = requests.first(where: { $0.id == id }) {
            open(request)
            return
        }
        if let found = try? await lookUp(id) {
            open(found.request)
            detail = found
        }
    }

    private func setScopes(_ next: [Scope]) {
        let oldID = selected?.id
        scopes = next
        relayoutScope()
        if selected?.id != oldID {
            selectedSpanID = nil
            detail = nil
            detailFailure = nil
        }
        fitRequest += 1
    }

    private func relayoutScope() {
        scopeLayout = scopes.isEmpty ? nil : shownGraph.map { GraphLayout(graph: $0) }
    }

    // MARK: Colours and labels

    /// The busiest arrow shown: of the window, or of the request in its view.
    var busiest: Int { shownCounts.values.max() ?? 0 }

    func color(of arrow: GraphArrow) -> GraphArrowColor {
        GraphColorScale.color(count: shownCounts[arrow.id] ?? 0, busiest: busiest)
    }

    /// What an arrow has written on it: the route for the arrow of the client, its calls for the
    /// others.
    func label(of arrow: GraphArrow) -> String {
        if arrow == clientArrow, let request = selected {
            return request.route
        }
        return "\(shownCounts[arrow.id] ?? 0)"
    }
}
