// OWNER: ui-chats — the Model, Effort and Permissions menus of the composer, also used by Settings
// > General for the default chat settings (docs/chats.md › Chat settings; docs/ui.md › General).
import AppKit
import HephaestusCore
import SwiftUI

/// The chat settings menus over a `ChatSettings` value: every choice calls `change` with the
/// complete new settings.
struct ChatSettingsMenus {
    var settings: ChatSettings
    /// `claude.models`, in order.
    var models: [ClaudeModel]
    var change: (ChatSettings) -> Void

    /// The help text of the Ultracode toggle.
    static let ultracodeHelp = "Standing dynamic-workflow orchestration for this chat, at any effort level."
    /// The help text of the Effort menu when the model has no effort setting.
    static let noEffortHelp = "This model has no effort setting"

    /// The menu subtitles of docs/chats.md › Permission mode.
    static func subtitle(_ mode: PermissionMode) -> String {
        switch mode {
        case .manual: return "Claude asks before it edits files or runs commands."
        case .acceptEdits: return "File edits are accepted; other actions ask."
        case .plan: return "Claude plans and changes nothing."
        case .auto: return "A classifier approves or denies each request."
        case .dontAsk: return "Anything not pre-approved is denied without asking."
        case .bypassPermissions: return "Every action runs without asking."
        }
    }

    /// The selected model's entry.
    var selectedModel: ClaudeModel? {
        models.first { $0.value == settings.model }
    }

    /// The Model menu button: the `displayName` of the selected value (the raw value when no entry
    /// matches), followed by ` · Ultracode` when ultracode is on.
    var modelTitle: String {
        (selectedModel?.displayName ?? settings.model) + (settings.ultracode ? " · Ultracode" : "")
    }

    /// The selected model's effort values; nil when no entry matches the stored value.
    // DOC-GAP: docs/chats.md › Effort disables the values that are not in the selected model's
    // supportedEffortLevels but does not cover a stored model value that matches no entry; every
    // value is enabled then.
    var supportedEfforts: Set<String>? {
        selectedModel.map { Set($0.supportedEffortLevels) }
    }

    /// The whole Effort menu is disabled when the selected model's list is empty.
    var effortDisabled: Bool {
        supportedEfforts?.isEmpty == true
    }

    // MARK: Menus

    /// Every entry of `claude.models` with its description as subtitle and a checkmark on the
    /// selected value; a divider and the `Ultracode` toggle follow.
    func modelMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for model in models {
            menu.addItem(ChatMenuItem(title: model.displayName, subtitle: model.description, checked: model.value == settings.model) {
                var new = settings
                new.model = model.value
                change(new)
            })
        }
        menu.addItem(.separator())
        let ultracode = ChatMenuItem(title: "Ultracode", checked: settings.ultracode) {
            var new = settings
            new.ultracode.toggle()
            change(new)
        }
        ultracode.toolTip = Self.ultracodeHelp
        menu.addItem(ultracode)
        return menu
    }

    /// Low to Max; values the selected model does not support are disabled.
    func effortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let supported = supportedEfforts
        for effort in Effort.allCases {
            let item = ChatMenuItem(title: effort.label, checked: effort == settings.effort) {
                var new = settings
                new.effort = effort
                change(new)
            }
            item.isEnabled = supported?.contains(effort.rawValue) ?? true
            menu.addItem(item)
        }
        return menu
    }

    /// The six modes with their subtitles; `Allow All` is drawn in red.
    func permissionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in PermissionMode.allCases {
            let item = ChatMenuItem(title: mode.label, subtitle: Self.subtitle(mode), checked: mode == settings.permissionMode) {
                var new = settings
                new.permissionMode = mode
                change(new)
            }
            if mode == .bypassPermissions {
                item.attributedTitle = NSAttributedString(string: mode.label, attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.menuFont(ofSize: 0),
                ])
            }
            menu.addItem(item)
        }
        return menu
    }

    /// The menu of the narrow composer: the submenus Model (with its Ultracode toggle), Effort and
    /// Permissions.
    func combinedMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let model = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        model.submenu = modelMenu()
        let effort = NSMenuItem(title: "Effort", action: nil, keyEquivalent: "")
        effort.submenu = effortMenu()
        effort.isEnabled = !effortDisabled
        if effortDisabled {
            effort.toolTip = Self.noEffortHelp
        }
        let permissions = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permissions.submenu = permissionsMenu()
        menu.addItem(model)
        menu.addItem(effort)
        menu.addItem(permissions)
        return menu
    }
}

/// A menu item that runs a closure.
final class ChatMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, subtitle: String? = nil, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(perform(_:)), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        if let subtitle, !subtitle.isEmpty {
            self.subtitle = subtitle
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func perform(_ sender: Any?) {
        handler()
    }
}

// MARK: - Buttons

/// A button that opens an `NSMenu` under itself.
struct ChatMenuButton<Label: View>: View {
    let menu: () -> NSMenu
    @ViewBuilder let label: () -> Label
    @State private var anchor = ChatMenuAnchor()

    var body: some View {
        Button {
            anchor.popUp(menu())
        } label: {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ChatMenuAnchorView(anchor: anchor))
    }
}

/// The view a menu opens under.
@MainActor
final class ChatMenuAnchor {
    weak var view: NSView?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }
}

private struct ChatMenuAnchorView: NSViewRepresentable {
    let anchor: ChatMenuAnchor

    func makeNSView(context: Context) -> FlippedView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: FlippedView, context: Context) {
        anchor.view = view
    }

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// The label of a menu button: a title and a chevron.
struct ChatMenuButtonLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// The Model menu button with its Ultracode toggle.
struct ChatModelMenuButton: View {
    let menus: ChatSettingsMenus

    var body: some View {
        ChatMenuButton(menu: menus.modelMenu) {
            ChatMenuButtonLabel(title: menus.modelTitle)
        }
        .accessibilityLabel("Model")
    }
}

/// The Effort menu button: `Effort: <UI label>`, or only the value when `compact`.
struct ChatEffortMenuButton: View {
    let menus: ChatSettingsMenus
    var compact = false

    var body: some View {
        ChatMenuButton(menu: menus.effortMenu) {
            ChatMenuButtonLabel(title: compact ? menus.settings.effort.label : "Effort: \(menus.settings.effort.label)")
        }
        .disabled(menus.effortDisabled)
        .help(menus.effortDisabled ? ChatSettingsMenus.noEffortHelp : "")
        .accessibilityLabel("Effort")
    }
}

/// The Permissions menu button: the UI label, or, while Allow All is selected, a red capsule with
/// the white text `Allow All`, the red badge of the composer.
struct ChatPermissionsMenuButton: View {
    let menus: ChatSettingsMenus

    var body: some View {
        ChatMenuButton(menu: menus.permissionsMenu) {
            if menus.settings.permissionMode == .bypassPermissions {
                AllowAllBadge()
            } else {
                ChatMenuButtonLabel(title: menus.settings.permissionMode.label)
            }
        }
        .accessibilityLabel("Permissions")
    }
}

/// The red `Allow All` capsule.
struct AllowAllBadge: View {
    var body: some View {
        Text(PermissionMode.bypassPermissions.label)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red))
    }
}

/// The single menu button of a narrow composer (`slider.horizontal.3`).
struct ChatCombinedSettingsMenuButton: View {
    let menus: ChatSettingsMenus

    var body: some View {
        ChatMenuButton(menu: menus.combinedMenu) {
            Image(systemName: "slider.horizontal.3")
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .accessibilityLabel("Chat Settings")
    }
}
