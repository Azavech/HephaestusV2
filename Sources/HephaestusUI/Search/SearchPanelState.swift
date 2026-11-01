// OWNER: ui-web-search — the search panel's state of one window, not persisted (docs/search.md ›
// Opening and closing, › Controls; docs/ui.md › WindowState, `search`).
import Foundation
import HephaestusCore

/// The query, the scope chips and the project toggle of a window's search panel.
struct SearchPanelState: Codable, Hashable {
    var query = ""
    /// The selected scope chips in chip order; empty means All.
    var scopes: [SearchScope] = []
    /// `This project` (true) or `All projects`; a new window starts on `This project`.
    var thisProject = true

    /// All is selected exactly when no scope chip is selected.
    var isAllSelected: Bool {
        scopes.isEmpty
    }

    /// Clicking a scope chip toggles it and deselects All; deselecting the last selected scope
    /// chip selects All.
    mutating func toggle(_ scope: SearchScope) {
        if let index = scopes.firstIndex(of: scope) {
            scopes.remove(at: index)
        } else {
            scopes.append(scope)
            scopes.sort { Self.order(of: $0) < Self.order(of: $1) }
        }
    }

    /// Clicking All deselects every scope chip.
    mutating func selectAll() {
        scopes = []
    }

    /// The position of a scope in the chip and ranking order.
    static func order(of scope: SearchScope) -> Int {
        SearchScope.allCases.firstIndex(of: scope) ?? 0
    }

    /// The chip name of a scope, also the title of its result group.
    static func chipName(of scope: SearchScope) -> String {
        switch scope {
        case .projects: return "Projects"
        case .tickets: return "Tickets"
        case .bundles: return "Bundles"
        case .docs: return "Docs"
        case .code: return "Code"
        case .chats: return "Chats"
        case .skills: return "Skills"
        case .web: return "Web"
        }
    }
}
