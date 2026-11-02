// OWNER: ui-skills-feedback — the Feedback sheet (docs/feedback.md › Feedback sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// Send Feedback: the screenshot (`AppModel.feedbackPreviews[previewID]`), the comment, the
/// project, the chat settings menus and the context; Send calls `chats.createFeedback` on the
/// receiving device and a main window shows the returned chat in its Chats section
/// (docs/feedback.md › Feedback sheet, › Chat settings menus, › Creating the feedback chat).
struct FeedbackSheet: View {
    let previewID: UUID
    let source: FeedbackSource
    /// Closes a sheet the controller attached to a window other than a main window; nil on a
    /// main window, whose sheet closes with `dismiss`.
    var close: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var comment = ""
    @State private var selectedProjectID: String?
    /// The user picked a project in the pop-up button; the pick is not saved.
    @State private var userPicked = false
    @State private var lookupFinished = false
    @State private var isSending = false
    /// The error of the last Send.
    @State private var sendError: String?
    /// The settings chosen in the menus; nil until a menu changes them, while the menus follow the
    /// selected project.
    @State private var chosenSettings: ChatSettings?
    /// The `chatDefaults` read with `projects.get` for selected projects whose detail the
    /// workspace has not loaded, by project id; `.some(nil)` for a project without them.
    @State private var readChatDefaults: [String: ChatSettings?] = [:]
    @FocusState private var commentFocused: Bool
    /// The screenshot, decoded once.
    @State private var image: NSImage?

    private var capture: FeedbackCapture? {
        app.feedbackController.capture(for: previewID)
    }

    private var png: Data? {
        app.feedbackPreviews[previewID]
    }

    /// The receiving device's workspace.
    private var workspace: DeviceWorkspace? {
        let deviceID: String
        if let capture {
            deviceID = capture.receivingDeviceID
        } else {
            switch source {
            case .main(let state): deviceID = state.deviceID
            case .chat(let value): deviceID = value.deviceID
            case .other: deviceID = app.localDeviceID
            }
        }
        return app.workspaces[deviceID]
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
            projectRow
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
        .task(id: lookupKey) {
            await lookUpDefaultProject()
        }
        .task(id: DefaultsKey(projectID: selectedProjectID, connected: workspace?.isConnected ?? false)) {
            await readSelectedChatDefaults()
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

    private var projectRow: some View {
        HStack(spacing: 8) {
            Text("Project")
            ProjectPopUpButton(items: ProjectPopUpButton.items(for: workspace?.projects ?? []), selection: projectSelection)
                .frame(maxWidth: .infinity)
            if !lookupFinished || !chatDefaultsKnown {
                ProgressView()
                    .controlSize(.small)
            }
        }
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

    private var projectSelection: Binding<String?> {
        Binding(get: { selectedProjectID }, set: { projectID in
            selectedProjectID = projectID
            userPicked = true
        })
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
        guard let workspace, !workspace.projects.isEmpty else {
            return "No project can receive feedback. Create or open a project first."
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
        guard !isSending, blockingMessage == nil, lookupFinished, chatDefaultsKnown, let selectedProjectID,
              let workspace, workspace.project(selectedProjectID) != nil else { return false }
        return true
    }

    // MARK: Chat settings (docs/feedback.md › Chat settings menus)

    /// The selected project's `chatDefaults`: from the loaded detail, else as read with
    /// `projects.get`; `.some(nil)` for a project without them, nil while they are not known.
    private var selectedChatDefaults: ChatSettings?? {
        guard let selectedProjectID, let workspace else { return nil }
        if let detail = workspace.details[selectedProjectID] {
            return .some(detail.project.chatDefaults)
        }
        return readChatDefaults[selectedProjectID]
    }

    /// The menus need no defaults once one of them was changed.
    private var chatDefaultsKnown: Bool {
        chosenSettings != nil || selectedChatDefaults != nil
    }

    /// The settings of the menus: the choice, else the selected project's `chatDefaults`, else the
    /// receiving device's `defaultChatSettings`.
    private var chatSettings: ChatSettings {
        if let chosenSettings { return chosenSettings }
        if let defaults = selectedChatDefaults ?? nil { return defaults }
        return workspace?.settings?.defaultChatSettings ?? ChatSettings()
    }

    private struct DefaultsKey: Hashable {
        var projectID: String?
        var connected: Bool
    }

    /// Reads the selected project's `chatDefaults` when the workspace has not loaded its detail; a
    /// failed read leaves the receiving device's defaults.
    private func readSelectedChatDefaults() async {
        guard let workspace, workspace.isConnected, let projectID = selectedProjectID,
              workspace.details[projectID] == nil, readChatDefaults[projectID] == nil
        else { return }
        let detail = try? await workspace.call(ProjectsGet.self, ProjectsGet.Params(projectID: projectID))
        guard !Task.isCancelled else { return }
        readChatDefaults[projectID] = .some(detail?.project.chatDefaults)
    }

    // MARK: Default project (docs/feedback.md › Feedback project)

    /// Runs the lookup again when the connection, the snapshot, the projects or the setting
    /// `feedbackProjectID` of the receiving device change.
    private struct LookupKey: Hashable {
        var connected: Bool
        var hasSnapshot: Bool
        var projectIDs: [String]
        var feedbackProjectID: String?
    }

    private var lookupKey: LookupKey {
        LookupKey(connected: workspace?.isConnected ?? false, hasSnapshot: workspace?.hasSnapshot ?? false,
                  projectIDs: workspace?.projects.map(\.id) ?? [], feedbackProjectID: workspace?.settings?.feedbackProjectID)
    }

    private func lookUpDefaultProject() async {
        guard let workspace else {
            lookupFinished = true
            return
        }
        let keepsPick = userPicked && selectedProjectID.map { workspace.project($0) != nil } == true
        if !keepsPick {
            lookupFinished = false
        }
        // Rule 3: the project selected in the captured main window, or the chat's project.
        let windowProjectID = capture?.context.projectID
        let projectID = await FeedbackProjectLookup.defaultProject(in: workspace, windowProjectID: windowProjectID)
        guard !Task.isCancelled else { return }
        if !(userPicked && selectedProjectID.map { workspace.project($0) != nil } == true) {
            selectedProjectID = projectID
            userPicked = false
        }
        lookupFinished = true
    }

    // MARK: Send (docs/feedback.md › Creating the feedback chat)

    private func send() {
        guard canSend, let workspace, let png, let capture, let projectID = selectedProjectID else { return }
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
                // The sheet stays open; the comment, the project and the chat settings are kept.
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
