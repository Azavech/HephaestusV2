// OWNER: ui-web-search — querying and results of the search panel (docs/search.md › Querying,
// › Results list, › Keyboard and mouse).
import Foundation
import HephaestusCore
import Observation

/// Runs `search.query` 250 ms after the last change of a window's query, chips or toggle, keeps
/// only the answer of the latest call and holds the selected result.
// STUB: ui-web-search
@MainActor @Observable
final class SearchController {
    private(set) var results: [SearchResult] = []
    private(set) var isQuerying = false
    private(set) var errorMessage: String?
    var selectedResultID: String?

    let window: WindowState
    let workspace: DeviceWorkspace

    init(window: WindowState, workspace: DeviceWorkspace) {
        self.window = window
        self.workspace = workspace
    }
}
