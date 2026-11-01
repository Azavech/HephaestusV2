// OWNER: ui-shell — the frosted background of the sidebar and inspector panes
// (docs/ui.md › Main window layout).
import AppKit
import SwiftUI

/// The system sidebar material, blended with what is behind the window. It follows the appearance
/// and the window's active state, and macOS makes it opaque when Reduce Transparency is on. The
/// window capture fills its area with an opaque colour (docs/feedback.md › Screenshot capture).
struct FrostedPaneBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
