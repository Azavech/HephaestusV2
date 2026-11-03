import Foundation

/// The standard macOS shortcuts and their actions (docs/chats.md › Standard macOS shortcuts),
/// taken from Apple's article "Mac keyboard shortcuts". The pinned shortcut card warns when the
/// selected shortcut is one of them.
public enum StandardShortcuts {
    /// One shortcut of the list and its action.
    public struct Entry: Sendable, Hashable {
        public let shortcut: String
        public let action: String
    }

    /// Every shortcut of the list, in the order of the docs table.
    public static let entries: [Entry] = [
        ("⌘X", "Cut"), ("⌘C", "Copy"), ("⌘V", "Paste"), ("⌘Z", "Undo"), ("⇧⌘Z", "Redo"), ("⌘A", "Select All"),
        ("⌘F", "Find"), ("⌘G", "Find Again"), ("⇧⌘G", "Find Previous"), ("⌘H", "Hide"), ("⌥⌘H", "Hide Others"),
        ("⌘M", "Minimize"), ("⌥⌘M", "Minimize All"), ("⌘O", "Open"), ("⌘P", "Print"), ("⌘Q", "Quit"), ("⌘S", "Save"),
        ("⌘T", "New Tab"), ("⌘W", "Close Window"), ("⌥⌘W", "Close All Windows"), ("⌥⌘⎋", "Force Quit"),
        ("⌘Space", "Spotlight"), ("⌥⌘Space", "Spotlight in Finder"), ("⌃⌘Space", "Character Viewer"),
        ("⌃⌘F", "Full Screen"), ("Space", "Quick Look"), ("⌘⇥", "Switch Apps"), ("⌘`", "Switch Windows"),
        ("⇧⌘3", "Screenshot"), ("⇧⌘4", "Screenshot"), ("⇧⌘5", "Screenshot or Recording"), ("⇧⌘N", "New Folder"),
        ("⌃⌘N", "New Folder with Selection"), ("⌘,", "Settings"),
        ("⌃⌘Q", "Lock Screen"), ("⇧⌘Q", "Log Out"), ("⌥⇧⌘Q", "Log Out Immediately"),
        ("⌥⌘D", "Show or Hide Dock"), ("⌃↑", "Mission Control"), ("⌃↓", "Application Windows"),
        ("⇧⌘6", "Ask Siri About Selection"), ("⇧⌘Space", "Ask Siri About Window"), ("⌃Space", "Previous Input Source"),
        ("⌃⌥Space", "Next Input Source"),
        ("⌃⌥⌘8", "Invert Colors"), ("⌃⌥⌘,", "Reduce Contrast"), ("⌃⌥⌘.", "Increase Contrast"), ("⌃F2", "Focus Menu Bar"),
        ("⌃F3", "Focus Dock"), ("⌃F4", "Focus Window"), ("⌃F5", "Focus Toolbar"), ("⌃F6", "Focus Floating Window"),
        ("⌃⇧F6", "Focus Previous Panel"), ("⌃F7", "Tab Focus Mode"), ("⌃F8", "Focus Status Menu"),
        ("⇧⌘`", "Previous Window"), ("⌥⌘`", "Focus Window Drawer"), ("⇥", "Next Control"), ("⇧⇥", "Previous Control"),
        ("⌃⇥", "Next Control"), ("⌃⇧⇥", "Previous Control Group"), ("←", "Move to Adjacent Item"),
        ("→", "Move to Adjacent Item"), ("↑", "Move to Adjacent Item"), ("↓", "Move to Adjacent Item"),
        ("⌃←", "Move to Adjacent Control"), ("⌃→", "Move to Adjacent Control"), ("⌥⌘F5", "Accessibility Shortcuts"),
    ].map { Entry(shortcut: $0.0, action: $0.1) }

    private static let actions: [String: String] = Dictionary(entries.map { ($0.shortcut, $0.action) }) { first, _ in first }

    /// The action of a standard macOS shortcut; nil for any other shortcut.
    public static func action(for shortcut: String) -> String? {
        actions[shortcut]
    }
}
