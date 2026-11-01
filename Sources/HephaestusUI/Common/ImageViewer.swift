// OWNER: ui-tickets — the image viewer window's content (docs/tickets.md › Image viewer).
import HephaestusCore
import SwiftUI

/// The content of an image viewer window: a stored image of a project, or the Feedback sheet's screenshot (`AppModel.feedbackPreviews`).
// STUB: ui-tickets
struct ImageViewerWindow: View {
    let value: ImageViewerValue

    var body: some View {
        PlaceholderView(name: "ImageViewerWindow")
            .frame(minWidth: 400, minHeight: 300)
    }
}
