import Foundation

// docs/engine-api.md › Views and previews: the methods of the Views section (docs/views.md), with
// their types.

/// `views.list`: the views that the Swift files of a project declare. Actors: user.
public enum ViewsList: EngineMethod {
    public static let name = "views.list"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [ProjectView]
}

/// `previews.start`: starts a session that shows the previews of a view. Actors: user.
public enum PreviewsStart: EngineMethod {
    public static let name = "previews.start"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// Project path of the view's file.
        public var path: String
        /// The view's name, as `ProjectView.name` has it.
        public var name: String
        public var settings: PreviewSettings

        public init(projectID: ProjectID, path: String, name: String, settings: PreviewSettings) {
            self.projectID = projectID
            self.path = path
            self.name = name
            self.settings = settings
        }
    }
    public typealias Result = PreviewSession
}

/// `previews.update`: new settings for the previews of a session. Actors: user.
public enum PreviewsUpdate: EngineMethod {
    public static let name = "previews.update"
    public struct Params: Codable, Sendable, Hashable {
        public var sessionID: UUID
        public var settings: PreviewSettings

        public init(sessionID: UUID, settings: PreviewSettings) {
            self.sessionID = sessionID
            self.settings = settings
        }
    }
    public typealias Result = Empty
}

/// `previews.poll`: the status of a session once it changed after `after`. Actors: user.
public enum PreviewsPoll: EngineMethod {
    public static let name = "previews.poll"
    public struct Params: Codable, Sendable, Hashable {
        public var sessionID: UUID
        /// The `sequence` of the last status received, 0 at first.
        public var after: Int

        public init(sessionID: UUID, after: Int) {
            self.sessionID = sessionID
            self.after = after
        }
    }
    public typealias Result = PreviewStatus
}

/// `previews.input`: a click, move, scroll or key for one preview of a session. Actors: user.
public enum PreviewsInput: EngineMethod {
    public static let name = "previews.input"
    public struct Params: Codable, Sendable, Hashable {
        public var sessionID: UUID
        /// The preview's `index`.
        public var preview: Int
        /// The `device` of the frame; nil for a Mac preview.
        public var device: String?
        public var event: PreviewInputEvent

        public init(sessionID: UUID, preview: Int, device: String? = nil, event: PreviewInputEvent) {
            self.sessionID = sessionID
            self.preview = preview
            self.device = device
            self.event = event
        }
    }
    public typealias Result = Empty
}

/// `previews.stop`: ends a session. Actors: user.
public enum PreviewsStop: EngineMethod {
    public static let name = "previews.stop"
    public struct Params: Codable, Sendable, Hashable {
        public var sessionID: UUID

        public init(sessionID: UUID) {
            self.sessionID = sessionID
        }
    }
    public typealias Result = Empty
}

/// `previews.capture`: the images of the previews of a view after their last build, for
/// `get_view_previews`. Actors: claude.
public enum PreviewsCapture: EngineMethod {
    public static let name = "previews.capture"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// Project path of the view's file.
        public var path: String
        /// The view's name, as `ProjectView.name` has it.
        public var name: String
        public var settings: PreviewSettings

        public init(projectID: ProjectID, path: String, name: String, settings: PreviewSettings = PreviewSettings()) {
            self.projectID = projectID
            self.path = path
            self.name = name
            self.settings = settings
        }
    }
    public typealias Result = PreviewCapture
}

// MARK: Types

/// A view that a Swift file of a project declares (docs/engine-api.md › ProjectView).
public struct ProjectView: Codable, Sendable, Hashable {
    /// The type's name after the names of the types it is declared in, separated by `.`.
    public var name: String
    /// Project path of its file.
    public var path: String
    /// The line of its declaration, from 1.
    public var line: Int
    public var kind: ViewKind
    /// Its preview blocks, in the order of the file.
    public var previews: [ViewPreview]

    public init(name: String, path: String, line: Int, kind: ViewKind, previews: [ViewPreview] = []) {
        self.name = name
        self.path = path
        self.line = line
        self.kind = kind
        self.previews = previews
    }
}

/// The kinds of views (docs/engine-api.md › ViewKind).
public enum ViewKind: String, Codable, Sendable, Hashable, CaseIterable {
    case swiftUI
    case appKit
    case uiKit

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// A `#Preview` block of a view (docs/engine-api.md › ViewPreview).
public struct ViewPreview: Codable, Sendable, Hashable {
    /// Absent for a block without a name.
    public var name: String?
    /// The line of its `#Preview`, from 1.
    public var line: Int

    public init(name: String? = nil, line: Int) {
        self.name = name
        self.line = line
    }
}

/// The settings of the previews of a session (docs/engine-api.md › PreviewSettings).
public struct PreviewSettings: Codable, Sendable, Hashable {
    /// Points, 50 to 2000.
    public var width: Int
    /// Points, 50 to 2000.
    public var height: Int
    public var appearance: PreviewAppearance
    public var dynamicTypeSize: DynamicTypeSize
    /// The orientation of the device previews.
    public var orientation: PreviewOrientation
    /// The devices checked, in the order of the devices popover (docs/views.md › Device rows).
    public var devices: [PreviewDevice]

    /// The range of the width and the height.
    public static let sizeRange = 50...2000

    public init(width: Int = 400, height: Int = 300, appearance: PreviewAppearance = .light, dynamicTypeSize: DynamicTypeSize = .large,
                orientation: PreviewOrientation = .portrait, devices: [PreviewDevice] = []) {
        self.width = width
        self.height = height
        self.appearance = appearance
        self.dynamicTypeSize = dynamicTypeSize
        self.orientation = orientation
        self.devices = devices
    }

    /// `orientation` and `devices` may be absent, in the settings of a window of an earlier
    /// version.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        appearance = try c.decode(PreviewAppearance.self, forKey: .appearance)
        dynamicTypeSize = try c.decode(DynamicTypeSize.self, forKey: .dynamicTypeSize)
        orientation = try c.decodeIfPresent(PreviewOrientation.self, forKey: .orientation) ?? .portrait
        devices = try c.decodeIfPresent([PreviewDevice].self, forKey: .devices) ?? []
    }
}

/// The appearances of the previews (docs/engine-api.md › PreviewAppearance).
public enum PreviewAppearance: String, Codable, Sendable, Hashable, CaseIterable {
    case light
    case dark

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// The Dynamic Type sizes, the cases of SwiftUI's `DynamicTypeSize` (docs/engine-api.md ›
/// DynamicTypeSize).
public enum DynamicTypeSize: String, Codable, Sendable, Hashable, CaseIterable {
    case xSmall
    case small
    case medium
    case large
    case xLarge
    case xxLarge
    case xxxLarge
    case accessibility1
    case accessibility2
    case accessibility3
    case accessibility4
    case accessibility5

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }

    /// The item of the `Dynamic Type` pop-up (docs/views.md › Preview settings).
    public var title: String {
        switch self {
        case .xSmall: return "Extra Small"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .xLarge: return "Extra Large"
        case .xxLarge: return "Extra Extra Large"
        case .xxxLarge: return "Extra Extra Extra Large"
        case .accessibility1: return "Accessibility 1"
        case .accessibility2: return "Accessibility 2"
        case .accessibility3: return "Accessibility 3"
        case .accessibility4: return "Accessibility 4"
        case .accessibility5: return "Accessibility 5"
        }
    }
}

/// The result of `previews.start` (docs/engine-api.md › PreviewSession).
public struct PreviewSession: Codable, Sendable, Hashable {
    public var sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}

/// The states of a preview session (docs/engine-api.md › PreviewState).
public enum PreviewState: String, Codable, Sendable, Hashable, CaseIterable {
    case building
    case running
    case buildFailed
    case stopped

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// The result of `previews.poll` (docs/engine-api.md › PreviewStatus).
public struct PreviewStatus: Codable, Sendable, Hashable {
    public var sequence: Int
    public var state: PreviewState
    /// `<n>/<m>` while building; nil before the first progress.
    public var progress: String?
    /// The end of the build the preview host runs.
    public var builtAt: Date?
    /// The errors of a failed build, or why the host stopped.
    public var messages: [String]
    public var previews: [PreviewFrame]

    public init(sequence: Int, state: PreviewState, progress: String? = nil, builtAt: Date? = nil, messages: [String] = [],
                previews: [PreviewFrame] = []) {
        self.sequence = sequence
        self.state = state
        self.progress = progress
        self.builtAt = builtAt
        self.messages = messages
        self.previews = previews
    }
}

/// One preview of a session with its image (docs/engine-api.md › PreviewFrame).
public struct PreviewFrame: Codable, Sendable, Hashable {
    /// Its rank among the view's previews, from 0.
    public var index: Int
    /// The name of its block, or `Preview <index + 1>`.
    public var title: String
    /// The name of its device; nil for a Mac preview.
    public var device: String?
    /// The sequence of the status that brought its image; 0 before its first image.
    public var sequence: Int
    /// A PNG at 2 pixels per point; present when it changed after the poll's `after`.
    public var pngBase64: String?
    /// Pixels; 0 before the first image.
    public var width: Int
    public var height: Int

    public init(index: Int, title: String, device: String? = nil, sequence: Int = 0, pngBase64: String? = nil, width: Int = 0,
                height: Int = 0) {
        self.index = index
        self.title = title
        self.device = device
        self.sequence = sequence
        self.pngBase64 = pngBase64
        self.width = width
        self.height = height
    }
}

/// The result of `previews.capture` (docs/engine-api.md › PreviewCapture).
public struct PreviewCapture: Codable, Sendable, Hashable {
    /// `running`, `buildFailed` or `stopped`.
    public var state: PreviewState
    /// The end of the build the preview host runs.
    public var builtAt: Date?
    /// The errors of a failed build, or why the host stopped; empty for `running`.
    public var messages: [String]
    /// The images, for `running`.
    public var previews: [PreviewImageFile]

    public init(state: PreviewState, builtAt: Date? = nil, messages: [String] = [], previews: [PreviewImageFile] = []) {
        self.state = state
        self.builtAt = builtAt
        self.messages = messages
        self.previews = previews
    }
}

/// The PNG file of one preview of `previews.capture` (docs/engine-api.md › PreviewImageFile).
public struct PreviewImageFile: Codable, Sendable, Hashable {
    /// Its rank among the view's previews, from 0.
    public var index: Int
    /// The name of its block, or `Preview <index + 1>`.
    public var title: String
    /// The absolute path of the PNG on the main device.
    public var path: String
    /// Pixels, 2 per point.
    public var width: Int
    public var height: Int

    public init(index: Int, title: String, path: String, width: Int, height: Int) {
        self.index = index
        self.title = title
        self.path = path
        self.width = width
        self.height = height
    }
}

/// A click, move, scroll or key for a preview (docs/engine-api.md › PreviewInputEvent).
public struct PreviewInputEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case mouseDown
        case mouseUp
        case mouseDragged
        case mouseMoved
        case scroll
        case keyDown
        case keyUp

        public init(from decoder: Decoder) throws {
            self = try APIEnumCoding.decode(decoder)
        }
    }

    public var kind: Kind
    /// Points from the preview's left edge.
    public var x: Double?
    /// Points from the preview's top edge.
    public var y: Double?
    /// `left` or `right`.
    public var button: String?
    public var clickCount: Int?
    public var deltaX: Double?
    public var deltaY: Double?
    public var characters: String?
    public var charactersIgnoringModifiers: String?
    public var keyCode: Int?
    /// `shift`, `control`, `option`, `command`, `capsLock`, `function`.
    public var modifiers: [String]?

    public init(kind: Kind, x: Double? = nil, y: Double? = nil, button: String? = nil, clickCount: Int? = nil,
                deltaX: Double? = nil, deltaY: Double? = nil, characters: String? = nil,
                charactersIgnoringModifiers: String? = nil, keyCode: Int? = nil, modifiers: [String]? = nil) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
