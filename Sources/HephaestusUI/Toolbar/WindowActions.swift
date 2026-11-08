// OWNER: ui-shell — the window actions behind the toolbar and the menus: New Chat, the inspector
// and the search panel (docs/ui.md › Toolbar).
import Foundation

extension WindowState {
    /// True when the window's device is connected.
    var isConnected: Bool {
        workspace?.isConnected ?? false
    }

    /// The active project on a connected device (the **project** condition of docs/ui.md › Menus
    /// and keyboard shortcuts).
    var hasActiveProject: Bool {
        isConnected && projectID != nil
    }

    /// New Chat: shows the inspector, a new draft chat in it and the focus in its composer
    /// (docs/ui.md › Inspector).
    func newChat() {
        guard projectID != nil else { return }
        inspectorVisible = true
        updateViewState { $0.inspectorShowsDraft = true }
        pendingSectionCommand = .focusInspectorComposer
    }

    /// Search (⇧⌘F): opens the search panel, or closes it when it is open.
    func toggleSearch() {
        searchVisible.toggle()
    }
}
