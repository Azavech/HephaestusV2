import AppKit
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Changing settings: every choice of the Model, Effort and Permissions menus, and
/// of the submenus of the `slider.horizontal.3` menu, calls `change` with the complete new settings.
@MainActor
@Suite("Chat settings menus")
struct ChatSettingsMenusTests {
    let models = [
        ClaudeModel(value: "default", displayName: "Default (recommended)", description: "", supportedEffortLevels: ["low", "medium", "high"]),
        ClaudeModel(value: "opus", displayName: "Opus", description: "", supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]),
    ]

    init() {
        // A menu item's action goes through `NSApp.sendAction`, which needs the application.
        _ = NSApplication.shared
    }

    /// The menus over the default settings, recording every change.
    func menus(recording changes: Recorder) -> ChatSettingsMenus {
        ChatSettingsMenus(settings: ChatSettings(), models: models) { changes.values.append($0) }
    }

    /// Chooses the item titled `title`, as a click does.
    func choose(_ title: String, in menu: NSMenu) {
        let index = menu.indexOfItem(withTitle: title)
        #expect(index >= 0, "no item \(title)")
        menu.performActionForItem(at: index)
    }

    @Test func menuItemRunsItsHandler() {
        var runs = 0
        let menu = NSMenu()
        menu.addItem(ChatMenuItem(title: "Item") { runs += 1 })
        menu.performActionForItem(at: 0)
        #expect(runs == 1)
    }

    @Test func effortChoiceChangesTheEffort() {
        let changes = Recorder()
        choose("Medium", in: menus(recording: changes).effortMenu())
        #expect(changes.values.map(\.effort) == [.medium])
    }

    @Test func modelChoiceChangesTheModel() {
        let changes = Recorder()
        choose("Opus", in: menus(recording: changes).modelMenu())
        #expect(changes.values.map(\.model) == ["opus"])
    }

    @Test func ultracodeToggleChangesUltracode() {
        let changes = Recorder()
        choose("Ultracode", in: menus(recording: changes).modelMenu())
        #expect(changes.values.map(\.ultracode) == [true])
    }

    @Test func permissionsChoiceChangesTheMode() {
        let changes = Recorder()
        choose("Accept Edits", in: menus(recording: changes).permissionsMenu())
        #expect(changes.values.map(\.permissionMode) == [.acceptEdits])
    }

    @Test func combinedMenuSubmenusChangeTheSettings() throws {
        let changes = Recorder()
        let combined = menus(recording: changes).combinedMenu()
        choose("Opus", in: try #require(combined.item(withTitle: "Model")?.submenu))
        choose("Low", in: try #require(combined.item(withTitle: "Effort")?.submenu))
        choose("Plan Only", in: try #require(combined.item(withTitle: "Permissions")?.submenu))
        #expect(changes.values.map(\.model) == ["opus", "default", "default"])
        #expect(changes.values.map(\.effort) == [.high, .low, .high])
        #expect(changes.values.map(\.permissionMode) == [.manual, .manual, .plan])
    }

    /// docs/chats.md › Effort: the button shows `Effort: <UI label>` for every value.
    @Test(arguments: Effort.allCases)
    func effortTitleNamesTheEffort(effort: Effort) {
        let menus = ChatSettingsMenus(settings: ChatSettings(effort: effort), models: models) { _ in }
        #expect(menus.effortTitle == "Effort: \(effort.label)")
    }

    @Test func choiceKeepsTheOtherFields() {
        let changes = Recorder()
        var settings = ChatSettings(model: "opus", effort: .max, permissionMode: .auto)
        settings.ultracode = true
        let menus = ChatSettingsMenus(settings: settings, models: models) { changes.values.append($0) }
        choose("Medium", in: menus.effortMenu())
        var expected = settings
        expected.effort = .medium
        #expect(changes.values == [expected])
    }
}

/// The settings passed to `change`, in order.
@MainActor
final class Recorder {
    var values: [ChatSettings] = []
}
