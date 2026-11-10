// OWNER: ui-shell — the seam between the menu commands and the section views
// (docs/ui.md › Menus and keyboard shortcuts).
import Foundation
import SwiftUI

/// The menu commands that act on the editor, tab or page of the section a main window shows
/// (docs/ui.md › Menus and keyboard shortcuts). The shown section view sets itself, or a controller
/// of its own, as `WindowState.sectionCommands`; a handler that is `@Observable` keeps the menu
/// items' enabled state current. Every member has a default: disabled, doing nothing.
@MainActor
protocol SectionCommandHandler: AnyObject {
    /// File ▸ Save (⌘S): the shown section has an editor with unsaved changes.
    var canSave: Bool { get }
    func save()
    /// File ▸ Close Tab (⌘W): the Web section has a selected tab, or the Code section a selected
    /// editor tab (docs/ui.md › Closing tabs and windows).
    var canCloseTab: Bool { get }
    func closeTab()
    /// Navigate ▸ Go to Line… (⌘L).
    var canGoToLine: Bool { get }
    func goToLine()
    /// Navigate ▸ Back (⌘[), Forward (⌘]) and Reload Page (⇧⌘R) of the Web section.
    var canGoBack: Bool { get }
    func goBack()
    var canGoForward: Bool { get }
    func goForward()
    var canReloadPage: Bool { get }
    func reloadPage()
    /// Navigate ▸ Show Previous Tab (⇧⌘[) and Show Next Tab (⇧⌘]): at least 2 tabs.
    var canShowAdjacentTab: Bool { get }
    func showPreviousTab()
    func showNextTab()
    /// Edit ▸ Toggle Comment (⌘/).
    var canToggleComment: Bool { get }
    func toggleComment()
}

extension SectionCommandHandler {
    var canSave: Bool { false }
    func save() {}
    var canCloseTab: Bool { false }
    func closeTab() {}
    var canGoToLine: Bool { false }
    func goToLine() {}
    var canGoBack: Bool { false }
    func goBack() {}
    var canGoForward: Bool { false }
    func goForward() {}
    var canReloadPage: Bool { false }
    func reloadPage() {}
    var canShowAdjacentTab: Bool { false }
    func showPreviousTab() {}
    func showNextTab() {}
    var canToggleComment: Bool { false }
    func toggleComment() {}
}

/// The focused main window's state, read by the menu commands.
struct WindowStateFocusedKey: FocusedValueKey {
    typealias Value = WindowState
}

/// The focused chat window's value, read by the menu commands.
struct ChatWindowFocusedKey: FocusedValueKey {
    typealias Value = ChatWindowValue
}

/// The focused chat window's search panel, which Navigate ▸ Search… closes.
struct ChatWindowSearchFocusedKey: FocusedValueKey {
    typealias Value = ChatWindowSearch
}

extension FocusedValues {
    var windowState: WindowState? {
        get { self[WindowStateFocusedKey.self] }
        set { self[WindowStateFocusedKey.self] = newValue }
    }

    var chatWindowValue: ChatWindowValue? {
        get { self[ChatWindowFocusedKey.self] }
        set { self[ChatWindowFocusedKey.self] = newValue }
    }

    var chatWindowSearch: ChatWindowSearch? {
        get { self[ChatWindowSearchFocusedKey.self] }
        set { self[ChatWindowSearchFocusedKey.self] = newValue }
    }
}
