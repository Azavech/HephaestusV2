// OWNER: ui-shell — HEPHAESTUS_WINDOW_SCREEN (docs/architecture.md › Window placement).
import AppKit
import CoreGraphics
import HephaestusCore
import ObjectiveC

/// Places every window the process opens on the display `HEPHAESTUS_WINDOW_SCREEN` names, or
/// outside all displays (docs/architecture.md › Window placement).
///
/// Main windows, chat windows, the Settings window, the About window and the image viewer are
/// placed once, just before AppKit first orders them in, so they never appear elsewhere first.
/// With `offscreen` a window's frame is never constrained back onto a display, and the app never
/// activates itself.
@MainActor
enum WindowPlacement {
    /// The placement `HEPHAESTUS_WINDOW_SCREEN` asks for; nil leaves placement to macOS.
    private(set) static var requested: WindowScreen?
    /// The effective placement, once resolved: `builtin` without a built-in display is `offscreen`.
    private(set) static var screen: WindowScreen?
    /// True when the process neither restores nor saves window state (docs/architecture.md ›
    /// Environment overrides, rule 8).
    static var disablesRestoration = false

    private static var log: LogSink?
    private static var placedKey: UInt8 = 0
    private static var moveObserver: NSObjectProtocol?

    static var isOffscreen: Bool {
        resolveIfNeeded()
        return screen == .offscreen
    }

    /// Installs the placement at launch, before the app object and any window exist: every later
    /// first ordering of a window places it.
    static func install(_ requestedScreen: WindowScreen, log: LogSink) {
        guard requested == nil else { return }
        requested = requestedScreen
        self.log = log
        exchange(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.hph_order(_:relativeTo:)))
        exchange(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.hph_makeKeyAndOrderFront(_:)))
        exchange(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.hph_orderFront(_:)))
        exchange(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.hph_orderFrontRegardless))
        exchange(NSWindow.self, #selector(NSWindow.setIsVisible(_:)), #selector(NSWindow.hph_setIsVisible(_:)))
    }

    /// Resolves the effective placement once the app object exists (its displays are known):
    /// `builtin` without a built-in display behaves as `offscreen` and logs a warning. With
    /// `offscreen`, frames are never constrained onto a display, a window moved onto a display is
    /// placed again, and the app never activates itself.
    static func resolveIfNeeded() {
        guard screen == nil, let requested else { return }
        var effective = requested
        if requested == .builtin, builtinScreen == nil {
            // DOC-GAP: docs/architecture.md › Window placement asks for a warning without its text.
            log?.warn(.ui, "HEPHAESTUS_WINDOW_SCREEN=builtin: this Mac has no built-in display; windows open offscreen")
            effective = .offscreen
        }
        screen = effective
        guard effective == .offscreen else { return }
        exchange(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:)), #selector(NSWindow.hph_constrainFrameRect(_:to:)))
        exchange(NSApplication.self, NSSelectorFromString("activateIgnoringOtherApps:"),
                 #selector(NSApplication.hph_activate(ignoringOtherApps:)))
        exchange(NSApplication.self, NSSelectorFromString("activate"), #selector(NSApplication.hph_activateNow))
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil,
                                                              queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow, isPlaced(window), isOnAnyDisplay(window) else { return }
                place(window)
            }
        }
    }

    /// Places a window the first time it is ordered in.
    static func placeIfNeeded(_ window: NSWindow) {
        resolveIfNeeded()
        guard screen != nil, isPlaceable(window), !isPlaced(window) else { return }
        objc_setAssociatedObject(window, &placedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if disablesRestoration {
            window.isRestorable = false
        }
        place(window)
    }

    /// The windows of the scenes: titled windows that are neither sheets nor panels.
    private static func isPlaceable(_ window: NSWindow) -> Bool {
        window.sheetParent == nil && !(window is NSPanel) && window.styleMask.contains(.titled)
    }

    private static func isPlaced(_ window: NSWindow) -> Bool {
        objc_getAssociatedObject(window, &placedKey) != nil
    }

    private static func isOnAnyDisplay(_ window: NSWindow) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    private static func place(_ window: NSWindow) {
        let size = window.frame.size
        switch screen {
        case .offscreen:
            let rightEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 0
            window.setFrame(NSRect(x: rightEdge + 1000, y: 0, width: size.width, height: size.height), display: false)
        case .main:
            center(window, size: size, in: NSScreen.screens.first)
        case .builtin:
            center(window, size: size, in: builtinScreen)
        case nil:
            break
        }
    }

    /// Centered in the display's visible frame, reduced to fit it.
    private static func center(_ window: NSWindow, size: NSSize, in screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let frame = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        window.setFrame(frame.integral, display: false)
    }

    /// The screen whose display id satisfies `CGDisplayIsBuiltin`.
    private static var builtinScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    private static func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(type, original),
              let replacementMethod = class_getInstanceMethod(type, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

// After `method_exchangeImplementations`, each `hph_` method runs in place of the AppKit method,
// and calling `hph_…` from it runs the AppKit implementation.
extension NSWindow {
    @objc fileprivate func hph_order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        if place != .out {
            WindowPlacement.placeIfNeeded(self)
        }
        hph_order(place, relativeTo: otherWindow)
    }

    @objc fileprivate func hph_makeKeyAndOrderFront(_ sender: Any?) {
        WindowPlacement.placeIfNeeded(self)
        hph_makeKeyAndOrderFront(sender)
    }

    @objc fileprivate func hph_orderFront(_ sender: Any?) {
        WindowPlacement.placeIfNeeded(self)
        hph_orderFront(sender)
    }

    @objc fileprivate func hph_orderFrontRegardless() {
        WindowPlacement.placeIfNeeded(self)
        hph_orderFrontRegardless()
    }

    @objc fileprivate func hph_setIsVisible(_ flag: Bool) {
        if flag {
            WindowPlacement.placeIfNeeded(self)
        }
        hph_setIsVisible(flag)
    }

    /// With `offscreen`, a window's frame is never constrained back onto a display.
    @objc fileprivate func hph_constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

extension NSApplication {
    /// With `offscreen`, the app never activates itself.
    @objc fileprivate func hph_activate(ignoringOtherApps flag: Bool) {}

    @objc fileprivate func hph_activateNow() {}
}
