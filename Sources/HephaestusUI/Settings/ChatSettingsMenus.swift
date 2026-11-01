// OWNER: ui-shell — the Model, Effort and Permissions menus of the default chat settings in
// Settings > General and of the chat defaults in Project Settings (docs/ui.md › General;
// docs/projects.md › Project settings; menus as docs/chats.md › Chat settings specifies).
import HephaestusCore
import SwiftUI

// DOC-GAP: docs/ui.md › General and docs/projects.md › Project settings reuse "the composer's"
// menus, which belong to the composer (ui-chats); these menus follow docs/chats.md › Chat
// settings for an edited `ChatSettings` value, so the settings forms do not depend on the
// composer's view.

/// The Model menu with its Ultracode toggle, the Effort menu and the Permissions menu, editing a
/// `ChatSettings` value.
struct ChatSettingsMenus: View {
    let settings: ChatSettings
    /// The `claude.models` list of the device.
    let models: [ClaudeModel]
    let change: (ChatSettings) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ModelMenu(settings: settings, models: models, change: change)
            EffortMenu(settings: settings, models: models, change: change)
            PermissionsMenu(settings: settings, change: change)
        }
    }
}

/// Every entry of `claude.models` in order (title `displayName`, subtitle `description`,
/// checkmark on the selected value), a divider and the Ultracode toggle. The button shows the
/// selected `displayName` (the raw value when no entry matches), followed by ` · Ultracode`.
struct ModelMenu: View {
    let settings: ChatSettings
    let models: [ClaudeModel]
    let change: (ChatSettings) -> Void

    var body: some View {
        Menu {
            ForEach(models, id: \.value) { model in
                Toggle(isOn: Binding(get: { settings.model == model.value }, set: { _ in
                    var updated = settings
                    updated.model = model.value
                    change(updated)
                })) {
                    Text(model.displayName)
                    Text(model.description)
                }
            }
            Divider()
            Toggle("Ultracode", isOn: Binding(get: { settings.ultracode }, set: { value in
                var updated = settings
                updated.ultracode = value
                change(updated)
            }))
            .help("Standing dynamic-workflow orchestration for this chat, at any effort level.")
        } label: {
            Text(title)
        }
        .fixedSize()
    }

    private var title: String {
        let name = models.first { $0.value == settings.model }?.displayName ?? settings.model
        return settings.ultracode ? "\(name) · Ultracode" : name
    }
}

/// `Effort: <UI label>`; items the selected model does not support are disabled, and the whole
/// menu is disabled when the model lists no effort level.
struct EffortMenu: View {
    let settings: ChatSettings
    let models: [ClaudeModel]
    let change: (ChatSettings) -> Void

    var body: some View {
        let supported = models.first { $0.value == settings.model }?.supportedEffortLevels ?? []
        Menu {
            ForEach(Effort.allCases, id: \.self) { effort in
                Toggle(effort.label, isOn: Binding(get: { settings.effort == effort }, set: { _ in
                    var updated = settings
                    updated.effort = effort
                    change(updated)
                }))
                .disabled(!supported.contains(effort.rawValue))
            }
        } label: {
            Text("Effort: \(settings.effort.label)")
        }
        .fixedSize()
        .disabled(supported.isEmpty)
        .help(supported.isEmpty ? "This model has no effort setting" : "")
    }
}

/// The permission modes with their subtitles, `Allow All` in red; while Allow All is selected the
/// button is a red capsule with the white text `Allow All`.
struct PermissionsMenu: View {
    let settings: ChatSettings
    let change: (ChatSettings) -> Void

    var body: some View {
        let allowAll = settings.permissionMode == .bypassPermissions
        Menu {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Toggle(isOn: Binding(get: { settings.permissionMode == mode }, set: { _ in
                    var updated = settings
                    updated.permissionMode = mode
                    change(updated)
                })) {
                    Text(mode.label)
                        .foregroundStyle(mode == .bypassPermissions ? Color.red : Color.primary)
                    Text(Self.subtitle(mode))
                }
            }
        } label: {
            if allowAll {
                Text("Allow All")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
            } else {
                Text(settings.permissionMode.label)
            }
        }
        .fixedSize()
    }

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
}
