import Foundation

/// The hook through which the debug MCP tools reach the windows without HephaestusCore importing
/// AppKit (docs/architecture.md › Debug UI hook, docs/mcp.md › Swift shape). `AppModel`
/// implements it and installs it with `MCPServer.installDebugUI(_:)` at launch, only with
/// `HEPHAESTUS_DEBUG_TOOLS=1`. An engine without the hook answers every debug tool with
/// `No UI is attached to this engine.` (`unavailable`).
///
/// The throwing functions throw `EngineError`, whose message becomes the tool result's text:
/// `No window with id <id>.` (`notFound`), `No window is open.` (`unavailable`), or `internal`
/// naming the system error (docs/mcp.md › debug_screenshot, › Swift shape).
public protocol MCPDebugUI: AnyObject, Sendable {
    /// The `WindowInfo` of every visible window, sheets included, front to back.
    func windows() async -> [WindowInfo]
    /// Renders the window in-process with the feedback capture, writes the PNG to
    /// `Runtime/screenshots/<window id>-<time>.png` and returns its path and size in pixels; the
    /// key window, or the frontmost one, when `windowID` is nil.
    func screenshot(windowID: Int?) async throws -> DebugScreenshot
    /// Navigates the window that docs/ui.md › Choosing the window chooses for `debug_navigate`
    /// and returns its `WindowInfo` once its state is updated.
    func navigate(to target: NavigationTarget) async throws -> WindowInfo
}

/// A window of the app, as `debug_navigate` and `debug_ui_state` return it
/// (docs/mcp.md › Window information).
public struct WindowInfo: Codable, Sendable, Hashable {
    /// `main`, `chat`, `settings`, `about`, `sheet` or `other`.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case main, chat, settings, about, sheet, other
    }

    /// `{x, y, width, height}` in points, in AppKit screen coordinates.
    public struct Frame: Codable, Sendable, Hashable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// The window's AppKit window number, stable while the window is open.
    public var id: Int
    public var kind: Kind
    public var title: String
    public var isKey: Bool
    public var frame: Frame
    /// The `WindowState` of a main window or the `ChatWindowValue` of a chat window encoded with
    /// `EngineJSON.encoder()`; `null` for the others.
    public var state: JSONValue

    public init(id: Int, kind: Kind, title: String, isKey: Bool, frame: Frame, state: JSONValue = .null) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isKey = isKey
        self.frame = frame
        self.state = state
    }
}

/// The result of `debug_screenshot` (docs/mcp.md › debug_screenshot).
public struct DebugScreenshot: Codable, Sendable, Hashable {
    /// Absolute path of the PNG file.
    public var path: String
    /// Width in pixels.
    public var width: Int
    /// Height in pixels.
    public var height: Int

    public init(path: String, width: Int, height: Int) {
        self.path = path
        self.width = width
        self.height = height
    }
}
