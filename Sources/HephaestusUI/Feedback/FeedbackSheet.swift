// OWNER: ui-skills-feedback — the Feedback sheet (docs/feedback.md › Feedback sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// Send Feedback: the screenshot (`AppModel.feedbackPreviews[previewID]`), the comment, the
/// project and the context; Send calls `chats.createFeedback` on the receiving device and opens
/// the returned chat in a new chat window (docs/feedback.md › Feedback sheet, › Creating the
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
    @State private var selectedProjectID: String?
    /// The user picked a project in the pop-up button; the pick is not saved.
    @State private var userPicked = false
    @State private var lookupFinished = false
    @State private var isSending = false
    /// The error of the last Send.
    @State private var sendError: String?
    @FocusState private var commentFocused: Bool

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
        .onAppear {
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
        if let png, let image = NSImage(data: png) {
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
        MultilineField(text: $comment)
            .focused($commentFocused)
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
            if !lookupFinished {
                ProgressView()
                    .controlSize(.small)
            }
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
        // DOC-GAP: docs/feedback.md › Feedback sheet does not cover a receiving device whose Claude
        // status is not known yet (no snapshot); it reads as still checking.
        guard let status = workspace.claudeStatus, !status.checking else {
            return "Checking the Claude CLI on \(name)…"
        }
        guard status.available else {
            return "Claude CLI is not available on \(name): \(status.error ?? "")"
        }
        return nil
    }

    private var canSend: Bool {
        guard !isSending, blockingMessage == nil, lookupFinished, let selectedProjectID,
              let workspace, workspace.project(selectedProjectID) != nil else { return false }
        return true
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
            context: capture.context
        )
        Task {
            do {
                let meta = try await workspace.call(ChatsCreateFeedback.self, params)
                closeSheet()
                app.openChatWindow(ChatWindowValue(deviceID: workspace.deviceID, chatID: meta.id.uuidString))
            } catch {
                // The sheet stays open; the comment and the project are kept.
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
