// OWNER: ui-web-search — the search panel's state of one window, not persisted (docs/search.md ›
// Opening and closing, › Controls; docs/ui.md › WindowState, `search`).
import Foundation
import HephaestusCore

/// The query, the scope chips and the project toggle of a window's search panel.
struct SearchPanelState: Codable, Hashable {
    var query = ""
    /// The selected scope chips; empty means All.
    var scopes: [SearchScope] = []
    /// `This project` (true) or `All projects`; a new window starts on `This project`.
    var thisProject = true
}
