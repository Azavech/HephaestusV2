// OWNER: ui-chats — the composer (docs/chats.md › Composer).
import HephaestusCore
import SwiftUI

/// The composer of a chat, or of a draft chat; unsent text of an existing chat lives in
/// `DeviceWorkspace.drafts`, that of a draft in its view.
///
/// ```
/// [image.png ×] [build.log ×]                     attachment chips
/// Message Claude…                                 text, 1–10 lines
/// (paperclip)  Opus 5.5 ▾   Effort: High ▾   Ask Every Time ▾   ■  ↑
/// ```
struct ComposerView: View {
    @Bindable var model: ChatViewModel

    var body: some View {
        let workspace = model.workspace
        VStack(alignment: .leading, spacing: 6) {
            ClaudeStatusBanner(workspace: workspace)
            VStack(alignment: .leading, spacing: 6) {
                let attachments = model.composer.attachments
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { index, upload in
                                ComposerAttachmentChip(upload: upload) {
                                    model.removeAttachment(at: index)
                                }
                            }
                        }
                    }
                }
                ChatTextEditor(
                    text: Binding(get: { model.composer.text }, set: { model.composer.text = $0 }),
                    placeholder: workspace.isConnected ? "Message Claude…" : "Not connected to \(workspace.deviceName)",
                    isEditable: workspace.isConnected,
                    minLines: 1,
                    maxLines: 10,
                    isComposer: true,
                    focusRequest: model.composerFocusRequest,
                    onSend: { model.send() },
                    onEscape: { model.stop() },
                    onPasteFiles: { model.addFiles($0) },
                    onPasteImage: { model.addPastedImage($0) }
                )
                controls
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
            .disabled(!workspace.isConnected)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    /// The controls row stays on one line: when the Model, Effort and Permissions menus do not
    /// fit, one `slider.horizontal.3` menu replaces them, followed by the red `Allow All` capsule
    /// while that mode is selected.
    private var controls: some View {
        let menus = ChatSettingsMenus(settings: model.settings, models: model.workspace.models) { model.changeSettings($0) }
        return ViewThatFits(in: .horizontal) {
            controlsRow {
                ChatModelMenuButton(menus: menus)
                ChatEffortMenuButton(menus: menus)
                ChatPermissionsMenuButton(menus: menus)
            }
            controlsRow {
                ChatCombinedSettingsMenuButton(menus: menus)
                if menus.settings.permissionMode == .bypassPermissions {
                    ChatPermissionsMenuButton(menus: menus)
                }
            }
        }
    }

    private func controlsRow<Menus: View>(@ViewBuilder menus: () -> Menus) -> some View {
        HStack(spacing: 8) {
            Button {
                model.chooseFiles()
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Attach")
            menus()
            Spacer(minLength: 8)
            if model.state.isChatRunning, model.chatID != nil {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop")
            }
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.borderless)
            .disabled(!model.canSend)
            .accessibilityLabel("Send")
        }
        .font(.callout)
    }
}

/// Above the composer: `Checking the Claude CLI…` with a small spinner while `checking` is true;
/// when the CLI is unavailable, a banner with the error (docs/chats.md › Composer).
struct ClaudeStatusBanner: View {
    let workspace: DeviceWorkspace
    @Environment(AppModel.self) private var app

    var body: some View {
        if let status = workspace.claudeStatus {
            if status.checking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Checking the Claude CLI…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 4)
            } else if !status.available {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if workspace.isLocal {
                        Text(status.error ?? "")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open Settings") {
                            app.openSettings(tab: .general)
                        }
                    } else {
                        Text("Claude CLI is not available on \(workspace.deviceName): \(status.error ?? "")")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.callout)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
    }
}
