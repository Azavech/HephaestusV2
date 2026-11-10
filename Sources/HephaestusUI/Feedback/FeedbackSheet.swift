// OWNER: ui-skills-feedback — the Feedback sheet (docs/feedback.md › Feedback sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// The icon in the top-right corner of the Feedback sheet's screenshot preview: it shows whether
/// Send sends the screenshot, and a click on it switches (docs/feedback.md › Screenshot preview).
struct FeedbackScreenshotIcon: Equatable {
    /// The SF Symbol: `eye` while the screenshot is included, `eye.slash` while it is excluded.
    let symbol: String
    /// The tooltip and the accessibility label, which name what a click does.
    let label: String
    /// The icon shows while the pointer is over the preview, and always while the screenshot is
    /// excluded.
    let isShown: Bool
    /// False when the window could not be captured: no screenshot can be included.
    let isEnabled: Bool

    init(captured: Bool, included: Bool, hovered: Bool) {
        let sent = captured && included
        symbol = sent ? "eye" : "eye.slash"
        label = sent ? "Exclude Screenshot" : "Include Screenshot"
        isShown = hovered || !sent
        isEnabled = captured
    }
}

/// Send Feedback: the screenshot (`AppModel.feedbackPreviews[previewID]`) with the icon that
/// leaves it out, the comment, the files the user adds, the chat settings menus and the context;
/// Send calls `chats.createFeedback` on the receiving device with its HephaestusV2 project, and a
/// main window shows the returned chat in its Chats section (docs/feedback.md › Feedback sheet,
/// › Screenshot preview, › Chat settings menus, › Added files, › Feedback project, › Creating the
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
    /// The files the user added, with their chips under the comment field; Send sends them with
    /// the feedback and Cancel discards them (docs/feedback.md › Added files).
    @State private var files = FeedbackAttachments()
    /// The sheet's window, which the open panel of the Attach button attaches to.
    @State private var windowReference = ChatWindowReference()
    /// The settings chosen in the menus; nil until a menu changes them, while the menus show the
    /// HephaestusV2 project's defaults.
    @State private var chosenSettings: ChatSettings?
    /// The `chatDefaults` of the HephaestusV2 project read with `projects.get` when the workspace
    /// has not loaded its detail; `.some(nil)` for a project without them, nil while not read.
    @State private var readChatDefaults: ChatSettings??
    /// Incremented to put the keyboard focus in the comment field.
    @State private var commentFocusRequest = 0
    /// The screenshot, decoded once.
    @State private var image: NSImage?
    /// Whether Send sends the screenshot: true each time the sheet opens, and never saved.
    @State private var screenshotIncluded = true
    /// True while the pointer is over the preview.
    @State private var previewHovered = false

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
        FeedbackSheetColumn(minimumWidth: 480, spacing: 12) {
            Text("Send Feedback")
                .font(.headline)
            screenshot
            commentField
            if !files.uploads.isEmpty {
                attachmentChips
            }
            if let message = blockingMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let sendError {
                ValidationMessage(text: sendError)
            }
            settingsRow
                .layoutValue(key: FeedbackSheetColumn.SetsWidth.self, value: true)
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
        .disabled(isSending)
        .background(ChatWindowReader(reference: windowReference))
        // Files dropped anywhere on the sheet are added (docs/feedback.md › Added files).
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !isSending else { return false }
            Task {
                addFiles(await TicketDroppedFiles.urls(from: providers))
            }
            return true
        }
        .alert(files.alert?.title ?? "", isPresented: attachmentAlertShown, presenting: files.alert) { _ in
            Button("OK") {}
        } message: { alert in
            if !alert.message.isEmpty {
                Text(alert.message)
            }
        }
        .task(id: workspace?.isConnected ?? false) {
            await ensureHephaestusProject()
        }
        .task(id: DefaultsKey(available: hephaestusProject != nil, connected: workspace?.isConnected ?? false)) {
            await readHephaestusChatDefaults()
        }
        .onAppear {
            image = png.flatMap { NSImage(data: $0) }
            commentFocusRequest += 1
        }
        .onDisappear {
            app.feedbackController.finish(previewID)
        }
    }

    // MARK: Elements

    /// The PNG scaled to fit 480 × 300 pt, dimmed while the screenshot is excluded, with the icon
    /// in its top-right corner; a click outside the icon opens it in the image viewer.
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
                    .opacity(screenshotIncluded ? 1 : Self.excludedOpacity)
                    .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Screenshot")
            .overlay(alignment: .topTrailing) {
                screenshotIcon(FeedbackScreenshotIcon(captured: true, included: screenshotIncluded, hovered: previewHovered))
            }
            .onHover { previewHovered = $0 }
            .frame(maxWidth: .infinity)
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
                .overlay(alignment: .topTrailing) {
                    screenshotIcon(FeedbackScreenshotIcon(captured: false, included: screenshotIncluded, hovered: false))
                }
                .frame(maxWidth: .infinity)
        }
    }

    /// The opacity of the preview while the screenshot is excluded.
    private static let excludedOpacity = 0.4

    /// The icon, white on a small circle of dark material, 8 pt from the top and right edges of
    /// the preview: a button that takes a click also while the icon is hidden. The black fill
    /// over the material keeps the circle dark on dark screenshots and where the material is not
    /// blurred, as in the in-process capture.
    private func screenshotIcon(_ icon: FeedbackScreenshotIcon) -> some View {
        Button {
            screenshotIncluded.toggle()
        } label: {
            Image(systemName: icon.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(.black.opacity(0.4))
                }
                .environment(\.colorScheme, .dark)
                .opacity(icon.isShown ? 1 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!icon.isEnabled)
        .help(icon.label)
        .accessibilityLabel(icon.label)
        .padding(8)
    }

    /// A multi-line field with the focus; Send needs a comment that is not blank.
    private var commentField: some View {
        // ⌘V adds the files or the image data of the pasteboard, and files dropped on the field
        // are added (docs/feedback.md › Added files); ⌘Return and Escape press Send and Cancel.
        TicketTextEditor(text: $comment, minLines: 5, maxLines: 5, focusRequest: commentFocusRequest, isEditable: !isSending,
                         textInset: NSSize(width: 4, height: 4),
                         onCommandReturn: { send() },
                         onEscape: { if !isSending { closeSheet() } },
                         onPaste: { pasteboard in !isSending && files.paste(pasteboard) },
                         onDropFiles: { urls in addFiles(urls) })
            .frame(height: 96, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
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

    /// One chip per added file, in the order the files were added, as in the composer.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(files.uploads.enumerated()), id: \.offset) { index, upload in
                    ComposerAttachmentChip(upload: upload) {
                        files.remove(at: index)
                    }
                }
            }
        }
    }

    /// The Attach button, then the composer's Model, Effort, Context and Permissions menus, in one
    /// row, which gives the sheet its width when it is wider than the screenshot area.
    private var settingsRow: some View {
        let menus = ChatSettingsMenus(settings: chatSettings, models: workspace?.models ?? []) { chosenSettings = $0 }
        return HStack(spacing: 8) {
            Button {
                chooseFiles()
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Attach")
            ChatModelMenuButton(menus: menus)
                .fixedSize()
            ChatEffortMenuButton(menus: menus)
                .fixedSize()
            ChatContextMenuButton(menus: menus)
                .fixedSize()
            ChatPermissionsMenuButton(menus: menus)
                .fixedSize()
            if hephaestusProject != nil, !chatDefaultsKnown {
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

    private func contextProjectName(_ capture: FeedbackCapture) -> String? {
        guard let projectID = capture.context.projectID else { return nil }
        return app.workspaces[capture.receivingDeviceID]?.project(projectID)?.name
    }

    // MARK: Send conditions

    /// The first failing condition's message, or nil when no condition with a message fails
    /// (docs/feedback.md › Feedback sheet). A screenshot is not a condition.
    private var blockingMessage: String? {
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
        !isSending && blockingMessage == nil && chatDefaultsKnown && hephaestusProject != nil && !Self.isBlank(comment)
            && !files.isReading
    }

    /// A comment of white space and line breaks alone is blank; the condition has no message.
    static func isBlank(_ comment: String) -> Bool {
        comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    // MARK: Added files (docs/feedback.md › Added files)

    /// Files from the open panel, a drop or ⌘V; none is added while Send runs.
    private func addFiles(_ urls: [URL]) {
        guard !isSending else { return }
        files.add(urls)
    }

    /// The Attach button: an open panel for files, several at once, no folders.
    private func chooseFiles() {
        Task {
            addFiles(await TicketPendingFiles.chooseFiles(in: windowReference.window))
        }
    }

    private var attachmentAlertShown: Binding<Bool> {
        Binding(get: { files.alert != nil }, set: { if !$0 { files.alert = nil } })
    }

    // MARK: Send (docs/feedback.md › Creating the feedback chat)

    /// The `screenshot` param of Send: nil, so left out, while the screenshot is excluded and when
    /// the window could not be captured.
    static func screenshotUpload(png: Data?, included: Bool) -> AttachmentUpload? {
        guard included, let png else { return nil }
        return AttachmentUpload(name: "screenshot.png", contentType: "image/png", dataBase64: png.base64EncodedString())
    }

    private func send() {
        guard canSend, let workspace, let capture else { return }
        let projectID = FeedbackProject.projectID
        isSending = true
        sendError = nil
        let params = ChatsCreateFeedback.Params(
            projectID: projectID,
            comment: comment,
            screenshot: Self.screenshotUpload(png: png, included: screenshotIncluded),
            context: capture.context,
            settings: chatSettings,
            attachments: files.uploads.isEmpty ? nil : files.uploads
        )
        Task {
            do {
                let meta = try await workspace.call(ChatsCreateFeedback.self, params)
                closeSheet()
                await app.feedbackController.showChat(meta, in: workspace, source: source)
            } catch {
                // The sheet stays open; the comment, the state of the screenshot, the added files
                // and the chat settings are kept.
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

/// The column of the Feedback sheet: its subviews one under the other, each as wide as the column.
/// The column is `minimumWidth` wide, or as wide as a subview marked with `SetsWidth` when that
/// subview needs more: the chat settings row, which is neither folded nor clipped
/// (docs/feedback.md › Chat settings menus).
struct FeedbackSheetColumn: Layout {
    /// True for a subview whose ideal width the column takes when it is wider than `minimumWidth`.
    struct SetsWidth: LayoutValueKey {
        static let defaultValue = false
    }

    var minimumWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(of: subviews)
        let heights = heights(of: subviews, width: width)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights(of: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    private func width(of subviews: Subviews) -> CGFloat {
        subviews.filter { $0[SetsWidth.self] }.map { $0.sizeThatFits(.unspecified).width }.reduce(minimumWidth, max)
    }

    private func heights(of subviews: Subviews, width: CGFloat) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }
}
