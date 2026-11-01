// OWNER: ui-shell — the chat window's root: its workspace, title, subtitle, reconnect view and status
// bar around the chat view (docs/ui.md › Windows, › Status bar, › Empty states).
import HephaestusCore
import SwiftUI

/// The root of a chat window. A window restored without a value shows nothing and closes.
struct ChatWindowRoot: View {
    let value: ChatWindowValue?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let value {
            ChatWindowContent(value: value)
        } else {
            Color.clear
                .frame(minWidth: 480, minHeight: 480)
                .onAppear { dismiss() }
        }
    }
}

/// A chat window: the chat view of `value` above a status bar with the device state and the
/// ladybug; the reconnect view while its remote device is not connected.
private struct ChatWindowContent: View {
    let value: ChatWindowValue
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let workspace = app.workspaces[value.deviceID]
        VStack(spacing: 0) {
            Group {
                if let workspace, workspace.isLocal || workspace.isConnected {
                    ChatWindowView(value: value, workspace: workspace)
                } else if let workspace {
                    ReconnectView(workspace: workspace, window: nil)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBarView(context: .chat(value), workspace: workspace)
        }
        .frame(minWidth: 480, minHeight: 480)
        .navigationTitle(title(workspace))
        .navigationSubtitle(subtitle(workspace))
        .registersWindow(.chat(value), in: app)
        .focusedSceneValue(\.chatWindowValue, value)
        .onAppear {
            app.captureWindowActions(openWindow: openWindow, openSettings: openSettings)
            app.registerChatWindow(value)
            if app.workspaces[value.deviceID] == nil {
                // The chat's device is no longer paired.
                dismiss()
            }
        }
        .onDisappear {
            app.unregisterChatWindow(value)
        }
    }

    /// The chat's title, following every rename; empty until the chat's metadata is known
    /// (docs/ui.md › Windows).
    private func title(_ workspace: DeviceWorkspace?) -> String {
        workspace?.chats[value.chatID]?.title ?? ""
    }

    /// The project's name, followed by ` — <device name>` on a remote device.
    private func subtitle(_ workspace: DeviceWorkspace?) -> String {
        guard let workspace, let projectID = workspace.chats[value.chatID]?.projectID else { return "" }
        let name = workspace.project(projectID)?.name ?? projectID
        return workspace.isLocal ? name : "\(name) — \(workspace.deviceName)"
    }
}
