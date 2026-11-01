// OWNER: ui-shell — the menu state that depends on the key window and its first responder, which
// SwiftUI does not observe (docs/ui.md › Menus and keyboard shortcuts).
import AppKit
import Observation

/// The key window and the first-responder validation of the menu items that SwiftUI cannot
/// validate through the responder chain. It is refreshed after every event
/// (`NSApplication.didUpdateNotification`, posted when AppKit updates its windows after each
/// event) and when a window becomes or stops being key, so that the commands that read it update
/// their enabled state.
@MainActor @Observable
final class MenuValidation {
    static let shared = MenuValidation()

    /// The window number of the key window; nil when no window is key.
    private(set) var keyWindowNumber: Int?
    /// True when the key window is a sheet or shows one.
    private(set) var keyWindowShowsSheet = false
    /// Edit ▸ Paste and Match Style: an editable view that pastes plain text has the focus.
    private(set) var canPasteAndMatchStyle = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Starts following the key window and the first responder; called once at launch.
    func start() {
        guard observers.isEmpty else { return }
        let names = [NSApplication.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    func refresh() {
        let key = NSApp.keyWindow
        let number = key?.windowNumber
        if keyWindowNumber != number {
            keyWindowNumber = number
        }
        let showsSheet = key.map { $0.attachedSheet != nil || $0.sheetParent != nil } ?? false
        if keyWindowShowsSheet != showsSheet {
            keyWindowShowsSheet = showsSheet
        }
        let paste = Self.validate(#selector(NSTextView.pasteAsPlainText(_:)))
        if canPasteAndMatchStyle != paste {
            canPasteAndMatchStyle = paste
        }
    }

    /// Validates an action as AppKit validates a menu item without a target: the first responder
    /// of the key window's chain that implements it, asked with `validateMenuItem(_:)` or
    /// `validateUserInterfaceItem(_:)`.
    static func validate(_ action: Selector, tag: Int = 0) -> Bool {
        let item = NSMenuItem()
        item.action = action
        item.tag = tag
        guard let target = NSApp.target(forAction: action, to: nil, from: item) else { return false }
        if let validator = target as? NSMenuItemValidation {
            return validator.validateMenuItem(item)
        }
        if let validator = target as? NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(item)
        }
        return true
    }
}
