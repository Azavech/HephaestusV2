// OWNER: ui-web-search — the window that shows a search panel, and the composer a panel adds a
// resource to (docs/search.md › Search panel, › Adding a resource).
import HephaestusCore
import Observation
import SwiftUI

/// The composer that opened a search panel with `Add Resource…`: while a window holds one, a
/// result of its panel is added to that composer instead of being opened.
struct SearchPick {
    weak var composer: ChatViewModel?
}

/// A window that shows a search panel: a main window (`WindowState`), or a chat window
/// (`ChatWindowSearch`), whose panel only `Add Resource…` opens.
@MainActor
protocol SearchPanelWindow: AnyObject {
    /// Search panel shown. Closing the panel ends `searchPick`.
    var searchVisible: Bool { get set }
    /// The panel's query, scope chips and project toggle.
    var search: SearchPanelState { get set }
    /// The composer the panel adds a result to; nil while a result navigates.
    var searchPick: SearchPick? { get set }
    /// The project `This project` means; nil shows `All projects`, disabled.
    var searchProjectID: String? { get }
    /// Opens a result of the panel: the window navigates to its target.
    func searchNavigate(to target: NavigationTarget)
}

/// The search panel of a chat window, kept while the window is open and not persisted: it shows
/// over the window's content while the window's composer adds a resource, and `This project` means
/// the chat's project.
@MainActor @Observable
final class ChatWindowSearch: SearchPanelWindow {
    var searchVisible = false {
        didSet {
            if !searchVisible, searchPick != nil {
                searchPick = nil
            }
        }
    }
    var search = SearchPanelState()
    var searchPick: SearchPick?
    /// The chat's project, set by the window once the chat's metadata is known.
    var searchProjectID: String?

    /// A chat window's panel only adds resources.
    func searchNavigate(to target: NavigationTarget) {}
}

extension EnvironmentValues {
    /// The window's search panel, for the composers that add a resource with it.
    @Entry var searchPanelWindow: (any SearchPanelWindow)? = nil
}
