// OWNER: ui-web-search — querying and results of the search panel (docs/search.md › Querying,
// › Results list, › Keyboard and mouse).
import Foundation
import HephaestusCore
import Observation

/// Runs `search.query` 250 ms after the last change of a window's query, chips or toggle, keeps
/// only the answer of the latest call and holds the selected result.
@MainActor @Observable
final class SearchController {
    /// The latest answer, in rank order.
    private(set) var results: [SearchResult] = []
    /// True while the latest call is in flight.
    private(set) var isQuerying = false
    /// The message of the latest call's error.
    private(set) var errorMessage: String?
    var selectedResultID: String?
    /// The trimmed query of the shown answer; nil while no answer is shown.
    private(set) var answeredQuery: String?

    let window: WindowState
    let workspace: DeviceWorkspace

    /// The delay between the last change and the call.
    static let delay: Duration = .milliseconds(250)

    @ObservationIgnored private var callNumber = 0
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(window: WindowState, workspace: DeviceWorkspace) {
        self.window = window
        self.workspace = workspace
    }

    // MARK: Querying

    /// `This project` sends the window's active project (the sub project when one is selected);
    /// `All projects`, or a window with no active project, sends none.
    var projectID: String? {
        guard window.search.thisProject else { return nil }
        return window.projectID
    }

    /// A change of the query, the chips or the toggle: the call runs 250 ms after the last one;
    /// a query that is empty after trimming is not sent and the results are cleared.
    func inputsChanged() {
        pending?.cancel()
        guard !trimmedQuery.isEmpty else {
            clear()
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    /// Runs the query now: on opening the panel, the previous query runs again.
    func run() {
        pending?.cancel()
        pending = nil
        let query = window.search.query
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        let scopes = window.search.scopes
        let params = SearchQuery.Params(query: query, scopes: scopes.isEmpty ? nil : scopes, projectID: projectID)
        callNumber += 1
        let number = callNumber
        isQuerying = true
        let workspace = workspace
        Task { [weak self] in
            let answer: Result<[SearchResult], Error>
            do {
                answer = .success(try await workspace.call(SearchQuery.self, params))
            } catch {
                answer = .failure(error)
            }
            self?.receive(answer, number: number, query: trimmed)
        }
    }

    /// Shows an answer only when it belongs to the latest call; older answers are dropped.
    private func receive(_ answer: Result<[SearchResult], Error>, number: Int, query: String) {
        guard number == callNumber else { return }
        isQuerying = false
        switch answer {
        case .success(let list):
            results = list
            errorMessage = nil
            answeredQuery = query
            selectedResultID = orderedResults.first?.id
        case .failure(let error):
            results = []
            errorMessage = HephaestusUI.errorMessage(error)
            answeredQuery = nil
            selectedResultID = nil
        }
    }

    /// Drops the in-flight call and clears the results.
    private func clear() {
        callNumber += 1
        isQuerying = false
        results = []
        errorMessage = nil
        answeredQuery = nil
        selectedResultID = nil
    }

    private var trimmedQuery: String {
        window.search.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The terms of the shown answer's query, for highlighting.
    var terms: [String] {
        SearchHighlight.terms(of: answeredQuery ?? "")
    }

    // MARK: Results

    /// One group per `kind`, in the order in which the kinds first appear in the answer; inside a
    /// group the answer order is kept.
    var groups: [SearchResultGroup] {
        var order: [SearchScope] = []
        var byKind: [SearchScope: [SearchResult]] = [:]
        for result in results {
            if byKind[result.kind] == nil {
                order.append(result.kind)
            }
            byKind[result.kind, default: []].append(result)
        }
        return order.map { SearchResultGroup(kind: $0, results: byKind[$0] ?? []) }
    }

    /// The results in the order the panel shows them, across groups.
    var orderedResults: [SearchResult] {
        groups.flatMap(\.results)
    }

    /// ↓ and ↑: the next or previous result, across groups.
    func moveSelection(by offset: Int) {
        let ordered = orderedResults
        guard !ordered.isEmpty else { return }
        guard let current = ordered.firstIndex(where: { $0.id == selectedResultID }) else {
            selectedResultID = ordered.first?.id
            return
        }
        let index = min(max(current + offset, 0), ordered.count - 1)
        selectedResultID = ordered[index].id
    }

    /// Return: opens the selected result.
    func openSelected() {
        guard let result = results.first(where: { $0.id == selectedResultID }) else { return }
        open(result)
    }

    /// docs/search.md › Navigation: the panel closes, then the window navigates to the target.
    func open(_ result: SearchResult) {
        pending?.cancel()
        window.searchVisible = false
        let window = window
        let target = result.target
        Task {
            await window.navigate(to: target)
        }
    }
}

/// The results of one kind, under the header `<chip name> · <count>`.
struct SearchResultGroup: Identifiable {
    var kind: SearchScope
    var results: [SearchResult]

    var id: SearchScope { kind }
}
