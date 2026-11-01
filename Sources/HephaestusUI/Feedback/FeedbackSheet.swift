// OWNER: ui-skills-feedback — the Feedback sheet (docs/feedback.md › Feedback sheet).
import HephaestusCore
import SwiftUI

/// Send Feedback: the screenshot (`AppModel.feedbackPreviews[previewID]`), the comment, the project and the context; Send calls `chats.createFeedback`.
// STUB: ui-skills-feedback
struct FeedbackSheet: View {
    let previewID: UUID
    let source: FeedbackSource
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "FeedbackSheet") { dismiss() }
    }
}
