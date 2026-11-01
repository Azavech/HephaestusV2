// OWNER: ui-skills-feedback — starting feedback: capture, the receiving device, the default project
// lookup, the context and Send (docs/feedback.md › Flow, › Starting feedback, › Feedback project,
// › Feedback context, › Creating the feedback chat).
import AppKit
import Foundation

/// The window whose feedback is started.
enum FeedbackSource {
    /// A main window: its device receives the feedback.
    case main(WindowState)
    /// A chat window: the chat's device receives the feedback.
    case chat(ChatWindowValue)
    /// Settings, About or another window: This Mac receives the feedback.
    case other
}

/// Starts feedback for a window: captures it with `WindowCapture` (owned by ui-shell), keeps the
/// PNG in `AppModel.feedbackPreviews`, then shows the Feedback sheet on that window
/// (`WindowSheet.feedback` on a main window). A start while a capture is running is ignored.
@MainActor
final class FeedbackController {
    weak var app: AppModel?

    init() {}

    /// The ladybug of a status bar, or Help ▸ Send Feedback… (⇧⌘B) for the key window.
    // STUB: ui-skills-feedback
    func start(capturing window: NSWindow?, source: FeedbackSource) {}
}
