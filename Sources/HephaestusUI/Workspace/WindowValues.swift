// OWNER: ui-shell — the value types of the UI state model (docs/ui.md › Windows, › WindowState,
// › DeviceWorkspace).
import Foundation
import HephaestusCore

/// The engine's `Actor`, named apart from Swift's `Actor` protocol inside HephaestusUI.
typealias EngineActor = HephaestusCore.Actor

/// The state of one chat window (docs/ui.md › WindowState): the window observes the workspace of
/// `deviceID`, opening it when needed, and shows `chatID`; it never changes while the window is
/// open.
public struct ChatWindowValue: Codable, Hashable, Sendable {
    public var deviceID: String
    /// The chat id, an uppercase UUID string.
    public var chatID: String

    public init(deviceID: String, chatID: String) {
        self.deviceID = deviceID
        self.chatID = chatID
    }
}

/// What an image viewer window shows (docs/ui.md › Windows): a stored file of a project, or the
/// screenshot of an open Feedback sheet, whose PNG `AppModel` keeps in memory.
public enum ImageViewerValue: Codable, Hashable, Sendable {
    case stored(deviceID: String, projectID: String, path: String)
    case feedbackPreview(previewID: UUID)
}

/// The key of `WindowState.projectStates` (docs/ui.md › WindowState).
public struct ProjectKey: Codable, Hashable, Sendable {
    public var deviceID: String
    public var projectID: String

    public init(deviceID: String, projectID: String) {
        self.deviceID = deviceID
        self.projectID = projectID
    }
}

/// The mode of the Docs section (docs/documentation-viewer.md › Modes).
public enum DocMode: String, Codable, Hashable, Sendable, CaseIterable {
    case preview
    case edit
    case split

    /// The menu and segment title.
    var title: String {
        switch self {
        case .preview: return "Preview"
        case .edit: return "Edit"
        case .split: return "Split"
        }
    }
}

/// Unsent composer text and attachments of an existing chat, and the resources added to its
/// composer (docs/ui.md › DeviceWorkspace).
public struct ComposerDraft: Hashable, Sendable {
    public var text: String
    public var attachments: [AttachmentUpload]
    /// The added resources, in the order added; Send leaves them (docs/chats.md › Added
    /// resources).
    public var resources: [ChatLinkedItem]

    public init(text: String = "", attachments: [AttachmentUpload] = [], resources: [ChatLinkedItem] = []) {
        self.text = text
        self.attachments = attachments
        self.resources = resources
    }

    /// Nothing to keep: no text, no attachment and no added resource.
    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty && resources.isEmpty
    }
}

/// A device of the Device menu (docs/ui.md › AppModel): This Mac first, then the paired devices.
public struct DeviceEntry: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isLocal: Bool
    public var online: Bool

    public init(id: String, name: String, isLocal: Bool, online: Bool) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.online = online
    }
}

/// An alert shown on a main window: `<item title> failed` with the error's message and OK
/// (docs/ui.md › Principles, Errors), or another one-button alert of the docs.
struct WindowAlert: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var message: String

    /// The alert of a failed call from a button or menu item.
    static func failure(_ itemTitle: String, _ error: Error) -> WindowAlert {
        WindowAlert(title: "\(itemTitle) failed", message: errorMessage(error))
    }
}

/// The message of an error shown to the user: the engine error's message, else the system text.
func errorMessage(_ error: Error) -> String {
    if let error = error as? EngineError { return error.message }
    return error.localizedDescription
}

/// A one-shot request from a menu item to the section that a window shows; the section view
/// consumes it and sets `WindowState.pendingSectionCommand` back to nil.
enum SectionCommand: Hashable {
    /// File ▸ New Web Tab (⌘T): the Web section opens a new tab (docs/web-tabs.md › New tab).
    case newWebTab
    /// Navigate ▸ Open Location… (⌥⌘L): the Web section focuses its address bar.
    case openLocation
    /// File ▸ New Chat (⌥⌘N): the inspector puts the focus in the draft's composer
    /// (docs/ui.md › Inspector).
    case focusInspectorComposer
}

/// A message that a button of the centre column sends from the composer of the inspector's chat,
/// such as `Create Preview` (docs/views.md › Create Preview); the inspector of the project consumes
/// it and sets `WindowState.inspectorMessage` back to nil.
struct InspectorMessage: Hashable {
    let id = UUID()
    var projectID: String
    var text: String
}
