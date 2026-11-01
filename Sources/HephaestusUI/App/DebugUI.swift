// OWNER: ui-shell — the MCPDebugUI implementation installed into the engine with
// HEPHAESTUS_DEBUG_TOOLS=1 (docs/architecture.md › Debug UI hook; docs/mcp.md › Debug tools).
import AppKit
import Foundation
import HephaestusCore

/// The windows of the app for `debug_ui_state`, `debug_screenshot` and `debug_navigate`. Every
/// function works on the main actor; the engine calls them from its MCP server.
final class AppDebugUI: MCPDebugUI, @unchecked Sendable {
    /// Read only on the main actor.
    private weak var app: AppModel?

    @MainActor
    init(app: AppModel) {
        self.app = app
    }

    func windows() async -> [WindowInfo] {
        await windowsOnMain()
    }

    func screenshot(windowID: Int?) async throws -> DebugScreenshot {
        try await screenshotOnMain(windowID)
    }

    func navigate(to target: NavigationTarget) async throws -> WindowInfo {
        try await navigateOnMain(target)
    }

    @MainActor
    private func windowsOnMain() -> [WindowInfo] {
        guard let app else { return [] }
        return app.debugWindows.map(app.windowInfo)
    }

    /// docs/mcp.md › debug_screenshot: the window `windowID`, by default the key window or, when
    /// no window is key, the frontmost one, rendered in-process and written to
    /// `Runtime/screenshots/<window id>-<time>.png`.
    @MainActor
    private func screenshotOnMain(_ windowID: Int?) async throws -> DebugScreenshot {
        guard let app else { throw EngineError(.unavailable, "No window is open.") }
        let windows = app.debugWindows
        let window: NSWindow
        if let windowID {
            guard let match = windows.first(where: { $0.windowNumber == windowID }) else {
                throw EngineError(.notFound, "No window with id \(windowID).")
            }
            window = match
        } else {
            guard let match = windows.first(where: \.isKeyWindow) ?? windows.first else {
                throw EngineError(.unavailable, "No window is open.")
            }
            window = match
        }
        let capture: WindowCapture.Image
        do {
            capture = try await WindowCapture.capture(window)
        } catch {
            throw EngineError(.internal, "The window could not be rendered: \(errorMessage(error))")
        }
        let folder = app.engine.dataDirectory.screenshotsFolder
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let file = folder.appendingPathComponent("\(window.windowNumber)-\(formatter.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try capture.png.write(to: file, options: .atomic)
        } catch {
            throw EngineError(.internal, "The screenshot could not be written: \(error.localizedDescription)")
        }
        return DebugScreenshot(path: file.path, width: capture.width, height: capture.height)
    }

    /// docs/mcp.md › debug_navigate: the frontmost main window, switched to This Mac first when it
    /// shows another device, or a new main window on This Mac; returns its WindowInfo once its
    /// state is updated.
    @MainActor
    private func navigateOnMain(_ target: NavigationTarget) async throws -> WindowInfo {
        guard let app else { throw EngineError(.unavailable, "No window is open.") }
        let state: WindowState
        if let front = app.frontmostMainWindow {
            state = front
            state.switchDevice(to: app.localDeviceID)
        } else {
            let new = WindowState(deviceID: app.localDeviceID)
            new.needsDefaultProject = true
            app.openMainWindow(new)
            state = new
        }
        // A new window registers when SwiftUI shows it; the local workspace needs its snapshot.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              app.windowRegistry.window(forMain: state.id) == nil || !app.localWorkspace.hasSnapshot {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let window = app.windowRegistry.window(forMain: state.id) else {
            throw EngineError(.unavailable, "No window is open.")
        }
        state.reconcileProject(with: app.localWorkspace)
        await state.navigate(to: target)
        return app.windowInfo(window)
    }
}

extension AppModel {
    /// The visible windows of the app, sheets included, front to back.
    var debugWindows: [NSWindow] {
        NSApp.windows
            .filter { $0.isVisible && $0.level.rawValue < NSWindow.Level.statusBar.rawValue }
            .sorted { $0.orderedIndex < $1.orderedIndex }
    }

    /// The frontmost main window.
    var frontmostMainWindow: WindowState? {
        debugWindows.lazy.compactMap { self.windowRegistry.mainID(of: $0) }.compactMap { self.windows[$0] }.first
    }

    /// The WindowInfo of a window (docs/mcp.md › Window information).
    func windowInfo(_ window: NSWindow) -> WindowInfo {
        let role = windowRegistry.role(of: window)
        let kind: WindowInfo.Kind
        var state = JSONValue.null
        if window.sheetParent != nil || window.isSheet {
            kind = .sheet
        } else {
            switch role {
            case .main(let id):
                kind = .main
                if let windowState = windows[id], let value = try? EngineJSON.jsonValue(windowState) {
                    state = value
                }
            case .chat(let value):
                kind = .chat
                state = (try? EngineJSON.jsonValue(value)) ?? .null
            case .settings:
                kind = .settings
            case .about:
                kind = .about
            case .image, nil:
                kind = .other
            }
        }
        let frame = window.frame
        return WindowInfo(id: window.windowNumber, kind: kind, title: window.title, isKey: window.isKeyWindow,
                          frame: WindowInfo.Frame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                          state: state)
    }
}
