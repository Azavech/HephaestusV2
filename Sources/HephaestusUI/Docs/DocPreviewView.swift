// OWNER: ui-code-docs — the preview web view (docs/documentation-viewer.md › Preview web view, › Link activation).
import HephaestusCore
import SwiftUI

/// The `WKWebView` loading `doc.html`, `doc.js` and `markdown.css`.
// STUB: ui-code-docs
struct DocPreviewView: View {
    let buffer: EditorBuffer
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "DocPreviewView")
    }
}
