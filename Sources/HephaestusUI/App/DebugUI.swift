// OWNER: ui-shell — the MCPDebugUI implementation installed into the engine with
// HEPHAESTUS_DEBUG_TOOLS=1 (docs/architecture.md › Debug UI hook; docs/mcp.md › Debug tools).
import AppKit
import Foundation
import HephaestusCore

/// The windows of the app for `debug_ui_state`, `debug_screenshot`, `debug_navigate` and
/// `debug_click`. Every function works on the main actor; the engine calls them from its MCP
/// server.
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

    func click(windowID: Int, x: Int, y: Int) async throws -> [WindowInfo] {
        try await clickOnMain(windowID: windowID, x: x, y: y)
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
    /// state is updated, or fails with `conflict` as soon as the navigation shows an unsaved
    /// changes prompt, which then waits on the window for its answer.
    @MainActor
    private func navigateOnMain(_ target: NavigationTarget) async throws -> WindowInfo {
        guard let app else { throw EngineError(.unavailable, "No window is open.") }
        // While the app is launching, or while a main window's root has appeared but its window
        // is not registered yet, wait for that window rather than open a second one.
        let launchDeadline = Date().addingTimeInterval(10)
        while app.frontmostMainWindow == nil, !app.launchWindowsSettled || !app.windows.isEmpty, Date() < launchDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
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
        let sheetBefore = window.attachedSheet
        let progress = NavigationProgress()
        Task {
            await state.navigate(to: target)
            progress.finished = true
        }
        while !progress.finished {
            if let sheet = window.attachedSheet, sheet !== sheetBefore {
                throw EngineError(.conflict, "The window asks whether to save unsaved changes; the target is selected once the prompt is answered.")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return app.windowInfo(window)
    }

    /// Whether a navigation started by debug_navigate has finished.
    @MainActor
    private final class NavigationProgress {
        var finished = false
    }

    /// docs/mcp.md › debug_click: the point, in points from the top-left corner of the window's
    /// screenshot image (a sheet stands for the window it is attached to), is clicked on the
    /// frontmost of that window and its sheets whose frame contains it, with a left mouse down
    /// and mouse up built inside the app; nothing goes through the system. The windows are read
    /// 500 ms after the mouse up.
    @MainActor
    private func clickOnMain(windowID: Int, x: Int, y: Int) async throws -> [WindowInfo] {
        guard let app, let requested = app.debugWindows.first(where: { $0.windowNumber == windowID }) else {
            throw EngineError(.notFound, "No window with id \(windowID).")
        }
        let host = WindowCapture.hostWindow(of: requested)
        let frame = host.frame
        guard CGFloat(x) < frame.width, CGFloat(y) < frame.height else {
            throw EngineError(.invalid, "The point (\(x), \(y)) is outside the window \(windowID), which is "
                + "\(Self.points(frame.width)) × \(Self.points(frame.height)) points.")
        }
        let point = NSPoint(x: frame.minX + CGFloat(x), y: frame.maxY - CGFloat(y))
        let frontToBack = WindowCapture.overlayWindows(of: host).reversed() + [host]
        let window = frontToBack.first { $0.frame.contains(point) } ?? host
        let location = window.convertPoint(fromScreen: point)
        let time = ProcessInfo.processInfo.systemUptime
        let marker = ClickMarker()
        guard let down = Self.mouseEvent(.leftMouseDown, at: location, in: window, time: time, number: marker.number),
              let up = Self.mouseEvent(.leftMouseUp, at: location, in: window, time: time, number: marker.number),
              let end = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: time,
                                           windowNumber: 0, context: nil, subtype: Self.markerSubtype,
                                           data1: marker.number, data2: 0)
        else {
            throw EngineError(.internal, "The click could not be created.")
        }
        // The marker follows the mouse up in the queue, so it is dispatched once the mouse up
        // has been handled.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
            guard event.subtype.rawValue == Self.markerSubtype, event.data1 == marker.number else { return event }
            MainActor.assumeIsolated { marker.handled = true }
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        if let view = (window.contentView?.superview ?? window.contentView)?.hitTest(location),
           !window.isKeyWindow, !view.acceptsFirstMouse(for: down) {
            // A window that is not key, as every window of a check instance, which never
            // activates, takes the click as the one that only makes it key when the view refuses
            // first clicks, as a web view does. The events go to the view as the key window sends
            // them; the mouse up waits in the queue for a control's tracking loop.
            if view.acceptsFirstResponder {
                window.makeFirstResponder(view)
            }
            NSApp.postEvent(up, atStart: true)
            view.mouseDown(with: down)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true) {
                if pending.eventNumber == up.eventNumber, pending.windowNumber == up.windowNumber {
                    view.mouseUp(with: pending)
                } else {
                    NSApp.postEvent(pending, atStart: true)
                }
            }
        } else {
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        }
        NSApp.postEvent(end, atStart: false)
        let deadline = Date().addingTimeInterval(10)
        while !marker.handled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(500))
        return app.debugWindows.map(app.windowInfo)
    }

    /// The subtype of the application-defined event that follows a click in the queue.
    private static let markerSubtype: Int16 = 0x4843

    /// The marker of one click: its number, also the event number of its mouse events, and
    /// whether the app has dispatched it.
    @MainActor
    private final class ClickMarker {
        private static var count = 0
        let number: Int
        var handled = false

        init() {
            Self.count += 1
            number = Self.count
        }
    }

    @MainActor
    private static func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow,
                                   time: TimeInterval, number: Int) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time,
                           windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                           pressure: type == .leftMouseDown ? 1 : 0)
    }

    /// A size in points, without decimals when it is a whole number.
    private static func points(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(Double(value))
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
