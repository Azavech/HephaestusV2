// OWNER: ui-skills-feedback — the Feedback sheet (docs/feedback.md › Feedback sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// Send Feedback: the screenshot (`AppModel.feedbackPreviews[previewID]`), the comment, the chat
/// settings menus and the context; Send calls `chats.createFeedback` on the receiving device with
/// its HephaestusV2 project, and a main window shows the returned chat in its Chats section
/// (docs/feedback.md › Feedback sheet, › Chat settings menus, › Feedback project, › Creating the
/// feedback chat).
struct FeedbackSheet: View {
    let previewID: UUID
    let source: FeedbackSource
    /// Closes a sheet the controller attached to a window other than a main window; nil on a
    /// main window, whose sheet closes with `dismiss`.
    var close: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var comment = ""
    @State private var isSending = false
    /// The error of the last Send.
    @State private var sendError: String?
    /// The settings chosen in the menus; nil until a menu changes them, while the menus show the
    /// HephaestusV2 project's defaults.
    @State private var chosenSettings: ChatSettings?
    /// The `chatDefaults` of the HephaestusV2 project read with `projects.get` when the workspace
    /// has not loaded its detail; `.some(nil)` for a project without them, nil while not read.
    @State private var readChatDefaults: ChatSettings??
    @FocusState private var commentFocused: Bool
    /// The screenshot, decoded once.
    @State private var image: NSImage?

    private var capture: FeedbackCapture? {
        app.feedbackController.capture(for: previewID)
    }

    private var png: Data? {
        app.feedbackPreviews[previewID]
    }

    /// The receiving device.
    private var receivingDeviceID: String {
        capture?.receivingDeviceID ?? FeedbackProject.receivingDeviceID(of: source, app: app)
    }

    /// The receiving device's workspace.
    private var workspace: DeviceWorkspace? {
        app.workspaces[receivingDeviceID]
    }

    /// The receiving device's HephaestusV2 project, while it is loaded and shown.
    private var hephaestusProject: ProjectSummary? {
        FeedbackProject.project(in: workspace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Feedback")
                .font(.headline)
            screenshot
            commentField
            if let message = blockingMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let sendError {
                ValidationMessage(text: sendError)
            }
            settingsRow
            if let capture {
                let line = FeedbackController.contextLine(capture.context, projectName: contextProjectName(capture))
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line)
                    .textSelection(.enabled)
            }
            buttons
        }
        .padding(20)
        .frame(width: 520)
        .disabled(isSending)
        .task(id: workspace?.isConnected ?? false) {
            await ensureHephaestusProject()
        }
        .task(id: DefaultsKey(available: hephaestusProject != nil, connected: workspace?.isConnected ?? false)) {
            await readHephaestusChatDefaults()
        }
        .onAppear {
            image = png.flatMap { NSImage(data: $0) }
            commentFocused = true
        }
        .onDisappear {
            app.feedbackController.finish(previewID)
        }
    }

    // MARK: Elements

    /// The PNG scaled to fit 480 × 300 pt; a click opens it in the image viewer.
    @ViewBuilder
    private var screenshot: some View {
        if let image {
            Button {
                app.openImageViewer(.feedbackPreview(previewID: previewID))
            } label: {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480, maxHeight: 300)
                    .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Screenshot")
        } else if png != nil {
            // The PNG is being decoded.
            Color.clear
                .frame(width: 480, height: 300)
                .frame(maxWidth: .infinity)
        } else {
            Text("The window could not be captured.")
                .foregroundStyle(.secondary)
                .frame(width: 480, height: 300)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3)))
                .frame(maxWidth: .infinity)
        }
    }

    /// A multi-line field with the focus; it may stay empty.
    private var commentField: some View {
        MultilineField(text: $comment, focus: $commentFocused)
            .frame(height: 96)
            .overlay(alignment: .topLeading) {
                if comment.isEmpty {
                    Text("What happened, and what did you expect?")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 9)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Comment")
    }

    /// The composer's Model, Effort and Permissions menus, in one row.
    private var settingsRow: some View {
        let menus = ChatSettingsMenus(settings: chatSettings, models: workspace?.models ?? []) { chosenSettings = $0 }
        return HStack(spacing: 8) {
            ChatModelMenuButton(menus: menus)
                .fixedSize()
            ChatEffortMenuButton(menus: menus)
                .fixedSize()
            ChatPermissionsMenuButton(menus: menus)
                .fixedSize()
            if hephaestusProject != nil, !chatDefaultsKnown {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                closeSheet()
            }
            .keyboardShortcut(.cancelAction)
            Button {
                send()
            } label: {
                if isSending {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Send")
                    }
                } else {
                    Text("Send")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSend)
        }
        .background {
            // ⌘Return presses Send, also from the comment field.
            Button("Send") {
                send()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func contextProjectName(_ capture: FeedbackCapture) -> String? {
        guard let projectID = capture.context.projectID else { return nil }
        return app.workspaces[capture.receivingDeviceID]?.project(projectID)?.name
    }

    // MARK: Send conditions

    /// The first failing condition's message, or nil when no condition with a message fails
    /// (docs/feedback.md › Feedback sheet).
    private var blockingMessage: String? {
        if png == nil {
            return "The window could not be captured."
        }
        guard let workspace, hephaestusProject != nil else {
            return "HephaestusV2 is not available on \(workspace?.deviceName ?? app.deviceName(receivingDeviceID))."
        }
        let name = workspace.deviceName
        guard workspace.isConnected else {
            return "Not connected to \(name). Send is available when the connection is back."
        }
        // A status not known yet (no snapshot) reads as checking (docs/feedback.md › Feedback sheet).
        guard let status = workspace.claudeStatus, !status.checking else {
            return "Checking the Claude CLI on \(name)…"
        }
        guard status.available else {
            return "Claude CLI is not available on \(name): \(status.error ?? "")"
        }
        return nil
    }

    private var canSend: Bool {
        !isSending && blockingMessage == nil && chatDefaultsKnown && hephaestusProject != nil
    }

    // MARK: Chat settings (docs/feedback.md › Chat settings menus)

    /// The HephaestusV2 project's `chatDefaults`: from the loaded detail, else as read with
    /// `projects.get`; `.some(nil)` for a project without them, nil while they are not known.
    private var hephaestusChatDefaults: ChatSettings?? {
        guard hephaestusProject != nil, let workspace else { return nil }
        if let detail = workspace.details[FeedbackProject.projectID] {
            return .some(detail.project.chatDefaults)
        }
        return readChatDefaults
    }

    /// The menus need no defaults once one of them was changed.
    private var chatDefaultsKnown: Bool {
        chosenSettings != nil || hephaestusChatDefaults != nil
    }

    /// The settings of the menus: the choice, else the HephaestusV2 project's `chatDefaults`, else
    /// the receiving device's `defaultChatSettings`.
    private var chatSettings: ChatSettings {
        if let chosenSettings { return chosenSettings }
        if let defaults = hephaestusChatDefaults ?? nil { return defaults }
        return workspace?.settings?.defaultChatSettings ?? ChatSettings()
    }

    private struct DefaultsKey: Hashable {
        var available: Bool
        var connected: Bool
    }

    /// Reads the HephaestusV2 project's `chatDefaults` when the workspace has not loaded its
    /// detail; a failed read leaves the receiving device's defaults.
    private func readHephaestusChatDefaults() async {
        guard let workspace, workspace.isConnected, hephaestusProject != nil,
              workspace.details[FeedbackProject.projectID] == nil, readChatDefaults == nil
        else { return }
        let detail = try? await workspace.call(ProjectsGet.self, ProjectsGet.Params(projectID: FeedbackProject.projectID))
        guard !Task.isCancelled else { return }
        readChatDefaults = .some(detail?.project.chatDefaults)
    }

    // MARK: HephaestusV2 project (docs/feedback.md › Feedback sheet)

    /// `projects.ensureHephaestus` on the receiving device, when the sheet opens and each time the
    /// connection comes back: a device whose clone failed tries again. The sheet does not wait for
    /// the clone; the project arrives with `projects.changed`.
    private func ensureHephaestusProject() async {
        guard let workspace, workspace.isConnected else { return }
        _ = try? await workspace.call(ProjectsEnsureHephaestus.self)
    }

    // MARK: Send (docs/feedback.md › Creating the feedback chat)

    private func send() {
        guard canSend, let workspace, let png, let capture else { return }
        let projectID = FeedbackProject.projectID
        isSending = true
        sendError = nil
        let params = ChatsCreateFeedback.Params(
            projectID: projectID,
            comment: comment,
            screenshot: AttachmentUpload(name: "screenshot.png", contentType: "image/png", dataBase64: png.base64EncodedString()),
            context: capture.context,
            settings: chatSettings
        )
        Task {
            do {
                let meta = try await workspace.call(ChatsCreateFeedback.self, params)
                closeSheet()
                await app.feedbackController.showChat(meta, in: workspace, source: source)
            } catch {
                // The sheet stays open; the comment and the chat settings are kept.
                sendError = errorMessage(error)
                isSending = false
            }
        }
    }

    private func closeSheet() {
        if let close {
            close()
        } else {
            dismiss()
        }
    }
}
