// OWNER: ui-chats — the state and actions of one chat view: the chat or draft it shows, the
// composer, the pinned cards and their keys, the header (docs/chats.md › Chat view, › Composer,
// › Pinned permission card, › Pinned questions card, › Draft chats).
import AppKit
import HephaestusCore
import Observation
import SwiftUI

/// A chat that is not stored yet (docs/chats.md › Draft chats): its first Send calls
/// `chats.create` with the message and the draft's settings.
struct DraftChat: Hashable {
    var projectID: String
    var kind: ChatKind
    var ticketID: String?
    var bundleID: String?
    /// Each New Chat shows a new draft; a draft that is closed or replaced is discarded.
    var id = UUID()

    init(projectID: String, kind: ChatKind = .project, ticketID: String? = nil, bundleID: String? = nil) {
        self.projectID = projectID
        self.kind = kind
        self.ticketID = ticketID
        self.bundleID = bundleID
    }
}

/// The choice of the questions card: an option's label, or `Answer another way`.
enum QuestionChoice: Hashable {
    case option(String)
    case other
}

/// The question a questions card displays: its set and its label.
struct QuestionKey: Hashable {
    var setID: UUID
    var label: String
}

@MainActor @Observable
final class ChatViewModel {
    let workspace: DeviceWorkspace
    /// The shown chat; nil for a draft.
    let chatID: String?
    /// The draft shown when `chatID` is nil.
    let draft: DraftChat?
    let projectID: String
    let transcript: TranscriptController
    @ObservationIgnored let windowReference = ChatWindowReference()
    @ObservationIgnored weak var app: AppModel?
    /// Called with the chat that the draft's first Send created.
    @ObservationIgnored var onCreated: ((ChatMeta) -> Void)?

    // MARK: Draft chat

    /// The unsent text and attachments of a draft chat (an existing chat's are in
    /// `DeviceWorkspace.drafts`).
    var draftComposer = ComposerDraft()
    /// The settings the draft is created with: the project's `chatDefaults`, else the host's
    /// `defaultChatSettings`, until a menu changes them.
    var draftSettings: ChatSettings?

    // MARK: Composer

    var composerFocusRequest = 0
    var isCreating = false
    /// The items of the window linked to the inspector chat; empty in every other chat view
    /// (docs/chats.md › Linked items).
    var linkedItems: [LinkedItem] = []
    /// Unlinks an item: set by the inspector.
    @ObservationIgnored var onUnlink: ((LinkedItemRef) -> Void)?

    // MARK: Cards

    /// The id of the permission request shown for at least 1 second.
    var permissionArmedID: String?
    var denyMessage = ""
    var permissionShowsAll = false
    /// The set and the label of the question the card displays.
    var questionKey: QuestionKey?
    var questionChoice: QuestionChoice = .other
    var questionOther = ""
    var isSubmittingAnswer = false

    // MARK: Header

    var isRenaming = false
    var renameText = ""

    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var opened = false

    init(workspace: DeviceWorkspace, chatID: String?, draft: DraftChat?) {
        self.workspace = workspace
        self.chatID = chatID
        self.draft = draft
        let projectID = draft?.projectID ?? chatID.flatMap { workspace.chats[$0]?.projectID } ?? ""
        self.projectID = projectID
        transcript = TranscriptController(connection: workspace.connection) { [weak workspace] in
            chatID.flatMap { workspace?.chats[$0]?.projectID } ?? projectID
        }
    }

    // MARK: Derived values

    var meta: ChatMeta? {
        chatID.flatMap { workspace.chats[$0] }
    }

    /// The project of the chat: the draft's, else the chat's metadata.
    var chatProjectID: String {
        meta?.projectID ?? projectID
    }

    var kind: ChatKind {
        meta?.kind ?? draft?.kind ?? .project
    }

    var state: ChatState {
        meta?.state ?? .idle
    }

    /// The chat is closed: `This conversation is over` replaces the composer and the More menu
    /// offers Reopen (docs/chats.md › Closing a chat).
    var isClosed: Bool {
        meta?.closed ?? false
    }

    var transcriptState: TranscriptState? {
        if let chatID { return workspace.transcripts[chatID] }
        return TranscriptState()
    }

    var title: String {
        meta?.title ?? ChatMeta.defaultTitle
    }

    /// The settings the composer's menus show.
    var settings: ChatSettings {
        meta?.settings ?? draftSettings ?? defaultSettings
    }

    /// The project's `chatDefaults`, else the host's `defaultChatSettings`
    /// (docs/chats.md › Fields and defaults).
    var defaultSettings: ChatSettings {
        workspace.details[chatProjectID]?.project.chatDefaults ?? workspace.settings?.defaultChatSettings ?? ChatSettings()
    }

    var composer: ComposerDraft {
        get {
            if let chatID { return workspace.drafts[chatID] ?? ComposerDraft() }
            return draftComposer
        }
        set {
            if let chatID {
                workspace.drafts[chatID] = newValue.text.isEmpty && newValue.attachments.isEmpty ? nil : newValue
            } else {
                draftComposer = newValue
            }
        }
    }

    var placeholder: String? {
        let projectName = workspace.project(chatProjectID)?.name ?? chatProjectID
        return ChatFormat.placeholder(kind: kind, projectName: projectName, ticketID: meta?.ticketID ?? draft?.ticketID,
                                      bundleID: meta?.bundleID ?? draft?.bundleID)
    }

    var renderContext: TranscriptRenderContext {
        let set = transcriptState?.incompleteQuestionSet
        let displayed = set.flatMap { set in displayedQuestion(set).map { QuestionKey(setID: set.questionSetID, label: $0.label) } }
        return TranscriptRenderContext(projectRootPath: workspace.project(chatProjectID)?.rootPath, chatIsRunning: state.isChatRunning,
                                       displayedQuestion: displayed)
    }

    /// Send is enabled when the text is not blank or there is an attachment, the window's device is
    /// connected and the CLI is available.
    var canSend: Bool {
        let draft = composer
        let hasContent = !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
        let status = workspace.claudeStatus
        return hasContent && workspace.isConnected && status?.available == true && status?.checking == false && !isCreating
    }

    var window: NSWindow? {
        windowReference.window
    }

    // MARK: Lifecycle

    func appear(app: AppModel, focusComposer: Bool) {
        self.app = app
        if let chatID, !opened {
            opened = true
            ChatTranscriptStore.shared.open(chatID, in: workspace)
        }
        transcript.onOpenLink = { [weak self] url, commandKey in
            self?.openLink(url, commandKey: commandKey)
        }
        transcript.onOpenAttachment = { [weak self] path in
            self?.openAttachment(path)
        }
        startKeyMonitor()
        if chatID == nil {
            ChatDrafts.register(self)
        }
        if chatID == nil, focusComposer {
            composerFocusRequest += 1
        }
    }

    func disappear() {
        ChatDrafts.unregister(self)
        if let chatID, opened {
            opened = false
            ChatTranscriptStore.shared.close(chatID, in: workspace)
        }
        stopKeyMonitor()
    }

    /// Loads the transcript for the workspace's current connection.
    func ensureLoaded(force: Bool = false) {
        guard let chatID else { return }
        ChatTranscriptStore.shared.ensureLoaded(chatID, in: workspace, force: force)
    }

    // MARK: Composer actions

    /// Send: `chats.send`, or `chats.create` for a draft; sending clears the text and the
    /// attachment chips. The message starts with the `Open in the app:` lines of the linked items,
    /// which stay linked.
    func send() {
        guard canSend else { return }
        let sent = composer
        let text = LinkedItems.messageText(sent.text, linked: linkedItems)
        let message = ChatMessageInput(text: text, attachments: sent.attachments.isEmpty ? nil : sent.attachments)
        composer = ComposerDraft()
        Task {
            do {
                if let chatID, let uuid = UUID(uuidString: chatID) {
                    _ = try await workspace.call(ChatsSend.self, ChatsSend.Params(chatID: uuid, message: message))
                } else if let draft {
                    isCreating = true
                    defer { isCreating = false }
                    let meta = try await workspace.call(ChatsCreate.self, ChatsCreate.Params(
                        projectID: draft.projectID, kind: draft.kind, ticketID: draft.ticketID, bundleID: draft.bundleID,
                        settings: settings, message: message))
                    onCreated?(meta)
                }
            } catch {
                // The message comes back when the composer is still empty (docs/chats.md › Composer).
                let current = composer
                if current.text.isEmpty, current.attachments.isEmpty {
                    composer = sent
                }
                alert(.failure("Send", error))
            }
        }
    }

    /// Stop and Escape while running: `chats.interrupt`.
    func stop() {
        guard let chatID, let uuid = UUID(uuidString: chatID), state.isChatRunning else { return }
        Task {
            do {
                _ = try await workspace.call(ChatsInterrupt.self, ChatsInterrupt.Params(chatID: uuid))
            } catch {
                alert(.failure("Stop", error))
            }
        }
    }

    /// × on a linked item chip.
    func unlink(_ item: LinkedItem) {
        onUnlink?(item.ref)
    }

    /// A menu change: `chats.updateSettings` at once for an existing chat; in a draft it changes
    /// the settings the chat is created with.
    func changeSettings(_ new: ChatSettings) {
        guard let chatID, let uuid = UUID(uuidString: chatID) else {
            draftSettings = new
            return
        }
        Task {
            do {
                _ = try await workspace.call(ChatsUpdateSettings.self, ChatsUpdateSettings.Params(chatID: uuid, settings: new))
            } catch {
                // docs/ui.md › Principles, Errors.
                alert(.failure("Chat Settings", error))
            }
        }
    }

    /// Files from the open panel, a drop or ⌘V.
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty, workspace.isConnected else { return }
        Task {
            switch await ChatAttachmentFiles.uploads(from: urls) {
            case .success(let uploads):
                composer.attachments += uploads
            case .failure(let problem):
                alert(WindowAlert(title: problem.title, message: problem.message))
            }
        }
    }

    /// Pasted image data without a file.
    func addPastedImage(_ png: Data) {
        switch ChatAttachmentFiles.pastedImage(png) {
        case .success(let upload):
            composer.attachments.append(upload)
        case .failure(let problem):
            alert(WindowAlert(title: problem.title, message: problem.message))
        }
    }

    func removeAttachment(at index: Int) {
        guard composer.attachments.indices.contains(index) else { return }
        composer.attachments.remove(at: index)
    }

    /// The paperclip: an open panel for files, several at once, no folders.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.addFiles(panel.urls)
        }
        if let window, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    /// Files dropped anywhere on the chat view.
    func drop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty, workspace.isConnected else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadURL(provider), url.isFileURL {
                    urls.append(url)
                }
            }
            addFiles(urls)
        }
        return true
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: Permission card

    /// Allow Once, Always Allow and Deny of the shown request; a conflict shows no alert, since
    /// the card follows the `chat.item` event.
    func answerPermission(_ request: PermissionRequestItem, _ decision: PermissionDecision) {
        guard let chatID, let uuid = UUID(uuidString: chatID) else { return }
        let trimmed = denyMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = decision == .deny && !trimmed.isEmpty ? trimmed : nil
        Task {
            do {
                _ = try await workspace.call(ChatsAnswerPermission.self, ChatsAnswerPermission.Params(
                    chatID: uuid, requestID: request.requestID, decision: decision, message: message))
            } catch let error as EngineError where error.code == .conflict {
                return
            } catch {
                alert(.failure(decision.label, error))
            }
        }
    }

    /// The shown request changed: its keys wait 1 second, its field and Show All start anew.
    func permissionShown(_ requestID: String?) {
        if permissionArmedID != requestID {
            permissionArmedID = nil
        }
        denyMessage = ""
        permissionShowsAll = false
    }

    // MARK: Questions card

    /// The question the card displays for `set`: the one this view chose for this set, else the
    /// first question without an answer.
    func displayedQuestion(_ set: QuestionsItem) -> Question? {
        if questionKey?.setID == set.questionSetID, let label = questionKey?.label,
           let question = set.questions.first(where: { $0.label == label }) {
            return question
        }
        return QuestionNavigation.firstUnanswered(set)
    }

    /// The displayed question appeared, or its stored answer changed: the selection shows the
    /// stored answer, else the recommended option with an empty field.
    func questionShown(_ set: QuestionsItem, _ question: Question) {
        questionKey = QuestionKey(setID: set.questionSetID, label: question.label)
        (questionChoice, questionOther) = QuestionNavigation.selection(question, answer: set.answers[question.label])
    }

    /// The previous or next arrow: the neighbouring question of the set, in label order.
    func showQuestion(_ label: String, of set: QuestionsItem) {
        guard let question = set.questions.first(where: { $0.label == label }) else { return }
        questionShown(set, question)
    }

    /// The answer the card submits: the selected option's label, or the field's text.
    var questionAnswer: String {
        switch questionChoice {
        case .option(let label): return label
        case .other: return questionOther.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var canSubmitAnswer: Bool {
        !questionAnswer.isEmpty && !isSubmittingAnswer
    }

    /// Submit: `chats.answerQuestion` for the displayed question with the selected answer.
    func submitAnswer() {
        guard canSubmitAnswer else { return }
        answerDisplayedQuestion(questionAnswer, action: "Submit")
    }

    /// Skip: `chats.answerQuestion` for the displayed question with `Skipped`.
    func skipQuestion() {
        guard !isSubmittingAnswer else { return }
        answerDisplayedQuestion(QuestionNavigation.skipped, action: "Skip")
    }

    /// Stores an answer of the displayed question, then displays the next question without an
    /// answer. An answer that fails because the set was completed on another device shows no alert.
    private func answerDisplayedQuestion(_ answer: String, action: String) {
        guard let chatID, let uuid = UUID(uuidString: chatID), let set = transcriptState?.incompleteQuestionSet,
              let question = displayedQuestion(set) else { return }
        isSubmittingAnswer = true
        Task {
            defer { isSubmittingAnswer = false }
            do {
                _ = try await workspace.call(ChatsAnswerQuestion.self, ChatsAnswerQuestion.Params(
                    chatID: uuid, questionSetID: set.questionSetID, label: question.label, answer: answer))
                let latest = transcriptState?.incompleteQuestionSet ?? set
                guard latest.questionSetID == set.questionSetID,
                      let next = QuestionNavigation.nextUnanswered(latest, after: question.label) else { return }
                showQuestion(next, of: latest)
            } catch let error as EngineError where error.code == .conflict && completedElsewhere(set.id) {
                return
            } catch {
                alert(.failure(action, error))
            }
        }
    }

    private func completedElsewhere(_ itemID: String) -> Bool {
        guard case .questions(let set)? = transcriptState?.item(itemID) else { return false }
        return set.completed
    }

    // MARK: Card keys (docs/chats.md › Keyboard shortcuts)

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// ⌘Return, ⌥⌘Return and ⇧⌘Return answer the permission card once its request has been shown
    /// for 1 second; ⌘Return submits the questions card when no permission card is shown and the
    /// card is not minimized. Both act
    /// only while the focus is in this chat view outside its composer.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if handleFindKey(event, flags: flags, window: window) { return true }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        let decision: PermissionDecision?
        switch flags {
        case [.command]: decision = .allow
        case [.command, .option]: decision = .allowAlways
        case [.command, .shift]: decision = .deny
        default: return false
        }
        guard let state = transcriptState, focusIsInViewOutsideComposer() else { return false }
        if let request = state.pendingPermissionRequests.first, let decision {
            if permissionArmedID == request.id {
                answerPermission(request, decision)
            }
            return true
        }
        if flags == [.command], let set = state.incompleteQuestionSet, let chatID,
           app?.isQuestionsCardMinimized(chatID: chatID, setID: set.questionSetID) != true {
            submitAnswer()
            return true
        }
        return false
    }

    /// ⌘F with the focus in the transcript shows its find bar; ⌘G and ⇧⌘G find the next and
    /// previous match while the bar is shown and the focus is in the transcript or the bar
    /// (docs/ui.md › Menus and keyboard shortcuts, Edit ▸ Find).
    private func handleFindKey(_ event: NSEvent, flags: NSEvent.ModifierFlags, window: NSWindow) -> Bool {
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key == "f" || key == "g",
              let webView = transcript.webView else { return false }
        let responder = window.firstResponder as? NSView
        let inTranscript = responder.map { $0 === webView || $0.isDescendant(of: webView) } ?? false
        if key == "f", flags == [.command], inTranscript {
            transcript.showFind()
            return true
        }
        if key == "g", flags == [.command] || flags == [.command, .shift], transcript.findVisible,
           inTranscript || focusIsInViewOutsideComposer() {
            transcript.find(backwards: flags.contains(.shift))
            return true
        }
        return false
    }

    /// The first responder lies inside this chat view and is not its composer.
    private func focusIsInViewOutsideComposer() -> Bool {
        guard let window, let region = windowReference.view, let responder = window.firstResponder as? NSView else {
            return false
        }
        if let textView = responder as? ChatNSTextView, textView.isComposer { return false }
        if region.isDescendant(of: responder) { return false }
        let regionRect = region.convert(region.bounds, to: nil)
        let rect = responder.convert(responder.visibleRect.isEmpty ? responder.bounds : responder.visibleRect, to: nil)
        return regionRect.contains(NSPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: Header actions

    func startRename() {
        guard meta != nil else { return }
        renameText = title
        isRenaming = true
    }

    /// Return in the title field: `chats.rename`.
    func commitRename() {
        guard isRenaming, let chatID, let uuid = UUID(uuidString: chatID) else { return }
        isRenaming = false
        let newTitle = renameText
        guard newTitle != title else { return }
        Task {
            do {
                _ = try await workspace.call(ChatsRename.self, ChatsRename.Params(chatID: uuid, title: newTitle))
            } catch {
                alert(.failure("Rename", error))
            }
        }
    }

    func cancelRename() {
        isRenaming = false
    }

    func openInNewWindow() {
        guard let chatID else { return }
        app?.openChatWindow(ChatWindowValue(deviceID: workspace.deviceID, chatID: chatID))
    }

    /// Reopen in the More menu: `chats.reopen`.
    func reopen() {
        guard let chatID, let uuid = UUID(uuidString: chatID) else { return }
        Task {
            do {
                _ = try await workspace.call(ChatsReopen.self, ChatsReopen.Params(chatID: uuid))
            } catch {
                alert(.failure("Reopen", error))
            }
        }
    }

    func confirmDelete() {
        guard let meta, let app else { return }
        ChatActions.confirmDelete(meta, workspace: workspace, window: window, app: app)
    }

    /// The ticket or bundle id of the header's chip.
    func navigateToLink() {
        guard let app, let meta else { return }
        let target: NavigationTarget
        if let bundleID = meta.bundleID {
            target = .bundle(bundleID: bundleID)
        } else if let ticketID = meta.ticketID {
            target = .ticket(ticketID: ticketID)
        } else {
            return
        }
        ChatNavigator.navigate(to: target, from: window, workspace: workspace, app: app)
    }

    // MARK: Page messages

    private func openLink(_ url: String, commandKey: Bool) {
        guard let app else { return }
        ChatNavigator.openLink(url, commandKey: commandKey, projectID: chatProjectID, workspace: workspace, app: app, window: window)
    }

    private func openAttachment(_ path: String) {
        guard let app else { return }
        ChatNavigator.openAttachment(path: path, attachment: transcriptState?.attachment(atPath: path), projectID: chatProjectID,
                                     workspace: workspace, app: app, window: window)
    }

    func alert(_ alert: WindowAlert) {
        guard let app else { return }
        ChatAlerts.show(alert, in: window, app: app)
    }
}

/// The unsent composer content of this app: an existing chat's is in `DeviceWorkspace.drafts`, a
/// draft chat's in its shown view.
@MainActor
enum ChatDrafts {
    private static let draftModels = NSHashTable<ChatViewModel>.weakObjects()

    static func register(_ model: ChatViewModel) {
        draftModels.add(model)
    }

    static func unregister(_ model: ChatViewModel) {
        draftModels.remove(model)
    }

    /// True when a composer of these workspaces, an existing chat's or a shown draft chat's, holds
    /// text that is not blank or an attachment.
    static func hasUnsentDraftText(in workspaces: [DeviceWorkspace]) -> Bool {
        func unsent(_ draft: ComposerDraft) -> Bool {
            !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
        }
        let ids = Set(workspaces.map(ObjectIdentifier.init))
        if workspaces.contains(where: { $0.drafts.values.contains(where: unsent) }) { return true }
        return draftModels.allObjects.contains { ids.contains(ObjectIdentifier($0.workspace)) && unsent($0.draftComposer) }
    }
}

/// Actions shared by the chat view's header and the chat lists.
@MainActor
enum ChatActions {
    /// Delete… asks `Delete the chat “<title>”?` with the informative text `Its transcript and
    /// attachments are moved to the Trash.` and the buttons Delete (destructive) and Cancel, then
    /// calls `chats.delete`.
    static func confirmDelete(_ meta: ChatMeta, workspace: DeviceWorkspace, window: NSWindow?, app: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Delete the chat “\(meta.title)”?"
        alert.informativeText = "Its transcript and attachments are moved to the Trash."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        ChatAlerts.present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do {
                    _ = try await workspace.call(ChatsDelete.self, ChatsDelete.Params(chatID: meta.id))
                } catch {
                    ChatAlerts.failure("Delete", error, in: window, app: app)
                }
            }
        }
    }

    /// `chats.rename` from a list row.
    static func rename(_ meta: ChatMeta, to title: String, workspace: DeviceWorkspace, window: NSWindow?, app: AppModel) {
        guard title != meta.title else { return }
        Task {
            do {
                _ = try await workspace.call(ChatsRename.self, ChatsRename.Params(chatID: meta.id, title: title))
            } catch {
                ChatAlerts.failure("Rename", error, in: window, app: app)
            }
        }
    }
}
