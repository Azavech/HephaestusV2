// OWNER: ui-shell — the AppKit windows of the scenes, by role: window kinds and ids for the debug
// tools (docs/mcp.md › Window information), the key window order (docs/ui.md › AppModel) and the
// window of a feedback capture (docs/feedback.md › Starting feedback).
import AppKit
import ObjectiveC
import SwiftUI

/// The role of an app window.
enum WindowRole: Hashable {
    case main(UUID)
    case chat(ChatWindowValue)
    case settings
    case about
    case image(ImageViewerValue)

    /// The `kind` of `WindowInfo` (docs/mcp.md › Window information).
    var debugKind: String {
        switch self {
        case .main: return "main"
        case .chat: return "chat"
        case .settings: return "settings"
        case .about: return "about"
        case .image: return "other"
        }
    }
}

/// The windows of the scenes, registered by their root views.
@MainActor
final class WindowRegistry {
    private struct Entry {
        weak var window: NSWindow?
        var role: WindowRole
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Called when a scene's root view is in its window.
    func register(_ window: NSWindow, role: WindowRole) {
        entries = entries.filter { $0.value.window != nil }
        entries[ObjectIdentifier(window)] = Entry(window: window, role: role)
        if WindowPlacement.disablesRestoration {
            window.isRestorable = false
        }
    }

    func role(of window: NSWindow) -> WindowRole? {
        entries[ObjectIdentifier(window)].flatMap { $0.window === window ? $0.role : nil }
    }

    func window(forMain id: UUID) -> NSWindow? {
        entries.values.first { $0.role == .main(id) }?.window
    }

    func window(forChat value: ChatWindowValue) -> NSWindow? {
        entries.values.first { $0.role == .chat(value) }?.window
    }

    func window(for role: WindowRole) -> NSWindow? {
        entries.values.first { $0.role == role }?.window
    }

    /// The id of the main window shown by `window`, when it is one.
    func mainID(of window: NSWindow?) -> UUID? {
        guard let window, case .main(let id) = role(of: window) else { return nil }
        return id
    }
}

/// Reports the `NSWindow` that hosts a scene's root view.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {
        view.onWindow = onWindow
    }

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}

extension View {
    /// Registers the hosting window of this scene root with the app under `role`.
    func registersWindow(_ role: WindowRole, in app: AppModel) -> some View {
        background(WindowAccessor { window in
            app.windowRegistry.register(window, role: role)
            if case .main(let id) = role {
                app.interceptCloseButton(of: window, mainID: id)
            }
        })
    }
}

/// The target of a main window's close button: the window closes after the unsaved changes check
/// of its editors, as with File ▸ Close Window (docs/ui.md › Unsaved changes and quitting).
@MainActor
final class MainWindowCloseButtonTarget: NSObject {
    weak var app: AppModel?
    let mainID: UUID

    init(app: AppModel, mainID: UUID) {
        self.app = app
        self.mainID = mainID
    }

    @objc func closeWindow(_ sender: Any?) {
        guard let app, let state = app.windows[mainID] else {
            (sender as? NSView)?.window?.close()
            return
        }
        Task {
            await app.closeMainWindow(state)
        }
    }
}

private var closeButtonTargetKey: UInt8 = 0

extension AppModel {
    /// Points the close button of a main window at the unsaved changes check.
    func interceptCloseButton(of window: NSWindow, mainID: UUID) {
        guard let button = window.standardWindowButton(.closeButton) else { return }
        if let target = button.target as? MainWindowCloseButtonTarget, target.mainID == mainID { return }
        let target = MainWindowCloseButtonTarget(app: self, mainID: mainID)
        objc_setAssociatedObject(window, &closeButtonTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        button.target = target
        button.action = #selector(MainWindowCloseButtonTarget.closeWindow(_:))
    }
}
