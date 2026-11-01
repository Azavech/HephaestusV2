// OWNER: ui-tickets — attachment thumbnails and chips (docs/tickets.md › Showing attachments).
import HephaestusCore
import SwiftUI

/// The thumbnail of an attachment; Space and a click open the image viewer or Quick Look.
// STUB: ui-tickets
struct AttachmentThumbnail: View {
    let attachment: Attachment
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "AttachmentThumbnail")
    }
}
