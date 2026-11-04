// OWNER: ui-chats — the state and actions of one chat view: the chat or draft it shows, the
// composer, the pinned cards and their keys, the header (docs/chats.md › Chat view, › Composer,
// › Pinned permission card, › Pinned questions card, › Pinned symbol card, › Pinned color card,
// › Pinned sound card, › Pinned shortcut card, › Pinned font card, › Pinned animation card,
// › Draft chats).
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

/// The choice of the symbol card: a symbol of the grid, or `Answer another way`.
enum SymbolChoice: Hashable {
    case symbol(String)
    case other
}

/// The choice of the sound card: a sound of the list, or `Answer another way`.
enum SoundChoice: Hashable {
    case sound(String)
    case other
}

/// The choice of the shortcut card: a suggestion, the recorder field, or `Answer another way`.
enum ShortcutChoice: Hashable {
    case suggestion(String)
    case recorder
    case other
}

/// The choice of the font card: a suggestion, a family or a text style of the search results, or
/// `Answer another way`.
enum FontChoice: Hashable {
    case suggestion(String)
    case family(String)
    case textStyle(FontTextStyle)
    case other
}

/// The choice of the animation card: a suggestion, the Custom row, or `Answer another way`.
enum AnimationChoice: Hashable {
    case suggestion(String)
    case custom
    case other
}

/// A lane of the animation card: a suggestion's, by its expression, or the Custom row's.
enum AnimationLaneID: Hashable {
    case suggestion(String)
    case custom
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
    /// The symbol request the symbol card shows, with its selection, field and search.
    var symbolRequestID: UUID?
    var symbolChoice: SymbolChoice = .other
    var symbolOther = ""
    var symbolSearch = ""
    /// The search results of `symbolSearch`, without the suggestions (docs/chats.md › Symbol search).
    var symbolResults: [String] = []
    var isSubmittingSymbol = false
    /// The color request the color card shows, with its selection and fields.
    var colorRequestID: UUID?
    var colorCard = ColorCardState()
    var isSubmittingColor = false
    /// The sound request the sound card shows, with its selection, field and search.
    var soundRequestID: UUID?
    var soundChoice: SoundChoice = .other
    var soundOther = ""
    var soundSearch = ""
    /// The names of the sound catalogue of the chat's project, from `sounds.list`; empty until
    /// they arrive (docs/chats.md › Pinned sound card).
    var soundNames: [String] = []
    /// The search results of `soundSearch`, without the suggestions (docs/chats.md › Sound search).
    var soundResults: [String] = []
    var isSubmittingSound = false
    /// The shortcut request the shortcut card shows, with its selection, recorder and field.
    var shortcutRequestID: UUID?
    var shortcutChoice: ShortcutChoice = .other
    /// The shortcut of the recorder field; nil until a combination is recorded.
    var recordedShortcut: KeyShortcut?
    var isRecordingShortcut = false
    var shortcutOther = ""
    var isSubmittingShortcut = false
    /// The font request the font card shows, with its selection, `Weight` and `Size`, field and
    /// search (docs/chats.md › Pinned font card).
    var fontRequestID: UUID?
    var fontChoice: FontChoice = .other
    var fontWeight = "Regular"
    /// The value of `fontWeight` in the family it was chosen in (docs/chats.md › Nearest weight).
    var fontWeightValue: Double = 0
    var fontSize = "17"
    var fontOther = ""
    var fontSearch = ""
    /// The search results of `fontSearch` (docs/chats.md › Font search).
    var fontResults: [FontCatalog.SearchResult] = []
    /// The catalogue the card searches: the families installed on this Mac and the project's.
    var fontCatalog = FontCatalog(installed: [], project: [])
    /// Changes when faces of project families are loaded, so that their rows draw again.
    var fontFacesRevision = 0
    var isSubmittingFont = false
    @ObservationIgnored var projectFonts: ProjectFonts?
    /// The animation request the animation card shows, with its selection, its Custom row, its
    /// field and the plays of its lanes.
    var animationRequestID: UUID?
    var animationChoice: AnimationChoice = .other
    var animationOther = ""
    var animationCustomPreset: AnimationPreset = .spring
    /// The values of the Duration, Bounce and Extra Bounce sliders, kept when the preset changes.
    var animationCustomValues: [AnimationParameter: Double] = [:]
    /// How many times each lane was played; a change plays the lane.
    var animationPlays: [AnimationLaneID: Int] = [:]
    var isSubmittingAnimation = false

    // MARK: Header

    var isRenaming = false
    var renameText = ""

    @ObservationIgnored private var keyMonitor: Any?
    /// While the recorder field records: the click monitor and the key-status observer that stop
    /// it (docs/chats.md › Shortcut recorder).
    @ObservationIgnored private var recordingMonitor: Any?
    @ObservationIgnored private var recordingObserver: NSObjectProtocol?
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
    /// offers Reopen in place of Close (docs/chats.md › Closing a chat).
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
        workspace.defaultChatSettings(of: chatProjectID)
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
                                       displayedQuestion: displayed, projectIdentifiers: workspace.projectIdentifiers,
                                       today: TranscriptDay.shared.today, models: workspace.models)
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
        app.chatNotifier.chatViewOpened(self)
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
        transcript.onPlaySound = { [weak self] name in
            self?.playSound(name)
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
        app?.chatNotifier.chatViewClosed(self)
        if let chatID, opened {
            opened = false
            ChatTranscriptStore.shared.close(chatID, in: workspace)
        }
        stopKeyMonitor()
        stopRecordingShortcut()
    }

    /// Loads the transcript for the workspace's current connection.
    func ensureLoaded(force: Bool = false) {
        guard let chatID else { return }
        ChatTranscriptStore.shared.ensureLoaded(chatID, in: workspace, force: force)
    }

    // MARK: Composer actions

    /// Send: `chats.send`, or `chats.create` for a draft; sending clears the text and the
    /// attachment chips. The linked items go with the message, outside its text, and stay linked
    /// (docs/chats.md › Linked items).
    func send() {
        guard canSend else { return }
        let sent = composer
        let linked = linkedItems.map(\.chatLinkedItem)
        let message = ChatMessageInput(text: sent.text, attachments: sent.attachments.isEmpty ? nil : sent.attachments,
                                       linkedItems: linked.isEmpty ? nil : linked)
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

    // MARK: Symbol card

    /// The card appeared for a request: the recommended suggestion selected, the field and the
    /// search empty. The same request keeps its selection.
    func symbolRequestShown(_ request: SymbolItem) {
        guard symbolRequestID != request.requestID else { return }
        symbolRequestID = request.requestID
        symbolChoice = .symbol(request.recommended)
        symbolOther = ""
        symbolSearch = ""
        symbolResults = []
    }

    /// Searches the catalogue of this Mac for `symbolSearch`, off the main actor; a result that
    /// arrives after the query changed is dropped.
    func searchSymbols(excluding suggestions: [String]) {
        let query = symbolSearch
        let excluded = Set(suggestions)
        Task {
            let results = await Task.detached { SFSymbolCatalog.system.search(query, excluding: excluded) }.value
            if symbolSearch == query {
                symbolResults = results
            }
        }
    }

    /// The answer the card submits: `![](sf:<name>)` for the selected symbol, or the field's text.
    var symbolAnswer: String {
        switch symbolChoice {
        case .symbol(let name): return "![](sf:\(name))"
        case .other: return symbolOther.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var canSubmitSymbol: Bool {
        !symbolAnswer.isEmpty && !isSubmittingSymbol
    }

    /// Submit: `chats.answerSymbol` with the selected answer.
    func submitSymbol() {
        guard canSubmitSymbol else { return }
        answerSymbolRequest(symbolAnswer, action: "Submit")
    }

    /// Skip: `chats.answerSymbol` with `Skipped`.
    func skipSymbol() {
        guard !isSubmittingSymbol else { return }
        answerSymbolRequest(QuestionNavigation.skipped, action: "Skip")
    }

    /// Stores the answer of the waiting symbol request. An answer that fails because the request
    /// was answered on another device shows no alert.
    private func answerSymbolRequest(_ answer: String, action: String) {
        guard let chatID, let uuid = UUID(uuidString: chatID), let request = transcriptState?.waitingSymbolRequest else { return }
        isSubmittingSymbol = true
        Task {
            defer { isSubmittingSymbol = false }
            do {
                _ = try await workspace.call(ChatsAnswerSymbol.self, ChatsAnswerSymbol.Params(
                    chatID: uuid, requestID: request.requestID, answer: answer))
            } catch let error as EngineError where error.code == .conflict && answeredElsewhere(request.id) {
                return
            } catch {
                alert(.failure(action, error))
            }
        }
    }

    private func answeredElsewhere(_ itemID: String) -> Bool {
        switch transcriptState?.item(itemID) {
        case .symbol(let request)?: return request.answer != nil
        case .color(let request)?: return request.answer != nil
        default: return false
        }
    }

    // MARK: Color card

    /// The color card appears for a request: the toggle as Claude asked, the recommended
    /// suggestion chosen, the field empty (docs/chats.md › Pinned color card).
    func colorRequestShown(_ request: ColorItem) {
        guard colorRequestID != request.requestID else { return }
        colorRequestID = request.requestID
        colorCard = ColorCardState(request: request)
    }

    var canSubmitColor: Bool {
        colorCard.answer != nil && !isSubmittingColor
    }

    /// Submit: `chats.answerColor` with the chosen color, pair or text.
    func submitColor() {
        guard canSubmitColor, let answer = colorCard.answer else { return }
        answerColorRequest(answer, action: "Submit")
    }

    /// Skip: `chats.answerColor` with `Skipped`.
    func skipColor() {
        guard !isSubmittingColor else { return }
        answerColorRequest(QuestionNavigation.skipped, action: "Skip")
    }

    /// Stores the answer of the waiting color request. An answer that fails because the request
    /// was answered on another device shows no alert.
    private func answerColorRequest(_ answer: String, action: String) {
        guard let chatID, let uuid = UUID(uuidString: chatID), let request = transcriptState?.waitingColorRequest else { return }
        isSubmittingColor = true
        Task {
            defer { isSubmittingColor = false }
            do {
                _ = try await workspace.call(ChatsAnswerColor.self, ChatsAnswerColor.Params(
                    chatID: uuid, requestID: request.requestID, answer: answer))
            } catch let error as EngineError where error.code == .conflict && answeredElsewhere(request.id) {
                return
            } catch {
                alert(.failure(action, error))
            }
        }
    }

    // MARK: Sound card

    /// The card appeared for a request: the recommended suggestion selected without playing, the
    /// field and the search empty, and the catalogue asked with `sounds.list`. The same request
    /// keeps its selection.
    func soundRequestShown(_ request: SoundItem) {
        guard soundRequestID != request.requestID else { return }
        soundRequestID = request.requestID
        soundChoice = .sound(request.recommended)
        soundOther = ""
        soundSearch = ""
        soundNames = []
        soundResults = []
        let projectID = chatProjectID
        Task {
            guard let names = try? await workspace.call(SoundsList.self, SoundsList.Params(projectID: projectID)),
                  soundRequestID == request.requestID else { return }
            soundNames = names
            searchSounds(excluding: request.suggestions)
        }
    }

    /// Searches the catalogue for `soundSearch` (docs/chats.md › Sound search).
    func searchSounds(excluding suggestions: [String]) {
        soundResults = SoundCatalog.search(soundSearch, in: soundNames, excluding: Set(suggestions))
    }

    /// A click on a row: selects its sound and plays it.
    func chooseSound(_ name: String) {
        soundChoice = .sound(name)
        playSound(name)
    }

    /// The answer the card submits: `![](sound:<name>)` for the selected sound, or the field's
    /// text.
    var soundAnswer: String {
        switch soundChoice {
        case .sound(let name): return "![](sound:\(name))"
        case .other: return soundOther.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var canSubmitSound: Bool {
        !soundAnswer.isEmpty && !isSubmittingSound
    }

    /// Submit: `chats.answerSound` with the selected answer.
    func submitSound() {
        guard canSubmitSound else { return }
        answerSoundRequest(soundAnswer, action: "Submit")
    }

    /// Skip: `chats.answerSound` with `Skipped`.
    func skipSound() {
        guard !isSubmittingSound else { return }
        answerSoundRequest(QuestionNavigation.skipped, action: "Skip")
    }

    /// Stores the answer of the waiting sound request. An answer that fails because the request
    /// was answered on another device shows no alert.
    private func answerSoundRequest(_ answer: String, action: String) {
        guard let chatID, let uuid = UUID(uuidString: chatID), let request = transcriptState?.waitingSoundRequest else { return }
        isSubmittingSound = true
        Task {
            defer { isSubmittingSound = false }
            do {
                _ = try await workspace.call(ChatsAnswerSound.self, ChatsAnswerSound.Params(
                    chatID: uuid, requestID: request.requestID, answer: answer))
            } catch let error as EngineError where error.code == .conflict && soundAnsweredElsewhere(request.id) {
                return
            } catch {
                alert(.failure(action, error))
            }
        }
    }

    private func soundAnsweredElsewhere(_ itemID: String) -> Bool {
        guard case .sound(let request)? = transcriptState?.item(itemID) else { return false }
        return request.answer != nil
    }

    /// Plays a sound of the chat's project: a row of the sound card or the play button of a sound
    /// marker (docs/chats.md › Sound playback).
    func playSound(_ name: String) {
        let projectID = chatProjectID
        Task {
            do {
                try await SoundPlayer.play(name, projectID: projectID, workspace: workspace)
            } catch {
                alert(.failure("Play Sound", error))
            }
        }
    }

    // MARK: Shortcut card

    /// The card appeared for a request: the recommended suggestion selected, the recorder field
    /// empty and not recording, the answer field empty. The same request keeps its selection.
    func shortcutRequestShown(_ request: ShortcutItem) {
        guard shortcutRequestID != request.requestID else { return }
        shortcutRequestID = request.requestID
        shortcutChoice = .suggestion(request.recommended)
        recordedShortcut = nil
        stopRecordingShortcut()
        shortcutOther = ""
    }

    /// The selected shortcut: the selected suggestion or the recorder field's shortcut; nil while
    /// `Answer another way` or an empty recorder field is selected.
    var selectedShortcut: String? {
        switch shortcutChoice {
        case .suggestion(let shortcut): return shortcut
        case .recorder: return recordedShortcut?.notation
        case .other: return nil
        }
    }

    /// The warnings of the selected shortcut (docs/chats.md › Shortcut warnings): the macOS line,
    /// then the app line.
    func shortcutWarnings(_ request: ShortcutItem) -> [String] {
        guard let shortcut = selectedShortcut else { return [] }
        var warnings: [String] = []
        if let action = StandardShortcuts.action(for: shortcut) {
            warnings.append("Used by macOS: \(action)")
        }
        if let use = request.inUse.first(where: { $0.shortcut == shortcut }) {
            warnings.append("Used by the app: \(use.command)")
        }
        return warnings
    }

    /// The answer the card submits: `![](shortcut:<shortcut>)` for the selected shortcut, or the
    /// field's text.
    var shortcutAnswer: String {
        switch shortcutChoice {
        case .suggestion(let shortcut): return KeyShortcut(shortcut)?.marker ?? "![](shortcut:\(shortcut))"
        case .recorder: return recordedShortcut?.marker ?? ""
        case .other: return shortcutOther.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var canSubmitShortcut: Bool {
        !shortcutAnswer.isEmpty && !isSubmittingShortcut
    }

    /// A click on the recorder field: selects it and starts recording; a click anywhere in the
    /// window or the window losing its key status stops recording.
    func startRecordingShortcut() {
        stopRecordingShortcut()
        shortcutChoice = .recorder
        isRecordingShortcut = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.stopRecordingShortcut() }
            return event
        }
        if let window {
            recordingObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                       queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecordingShortcut() }
            }
        }
    }

    /// Stops recording; the recorder field keeps its shortcut.
    func stopRecordingShortcut() {
        isRecordingShortcut = false
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
        }
        recordingMonitor = nil
        if let recordingObserver {
            NotificationCenter.default.removeObserver(recordingObserver)
        }
        recordingObserver = nil
    }

    /// A key press while the recorder field records (docs/chats.md › Shortcut recorder): a key
    /// the notation can write records the shortcut with the modifiers held and stops recording;
    /// another key records nothing. Every key press is consumed.
    func recordShortcutKey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, unmodifiedCharacters: String?) {
        guard isRecordingShortcut,
              let key = KeyShortcut.recordedKey(keyCode: keyCode, unmodifiedCharacters: unmodifiedCharacters) else { return }
        var modifiers: [KeyShortcut.Modifier] = []
        if modifierFlags.contains(.control) { modifiers.append(.control) }
        if modifierFlags.contains(.option) { modifiers.append(.option) }
        if modifierFlags.contains(.shift) { modifiers.append(.shift) }
        if modifierFlags.contains(.command) { modifiers.append(.command) }
        guard let shortcut = KeyShortcut(modifiers: modifiers, key: key) else { return }
        recordedShortcut = shortcut
        shortcutChoice = .recorder
        stopRecordingShortcut()
    }

    /// Submit: `chats.answerShortcut` with the selected answer.
    func submitShortcut() {
        guard canSubmitShortcut else { return }
        answerShortcutRequest(shortcutAnswer, action: "Submit")
    }

    /// Skip: `chats.answerShortcut` with `Skipped`.
    func skipShortcut() {
        guard !isSubmittingShortcut else { return }
        answerShortcutRequest(QuestionNavigation.skipped, action: "Skip")
    }

    /// Stores the answer of the waiting shortcut request. An answer that fails because the
    /// request was answered on another device shows no alert.
    private func answerShortcutRequest(_ answer: String, action: String) {
        guard let chatID, let uuid = UUID(uuidString: chatID), let request = transcriptState?.waitingShortcutRequest else { return }
        stopRecordingShortcut()
        isSubmittingShortcut = true
        Task {
            defer { isSubmittingShortcut = false }
            do {
                _ = try await workspace.call(ChatsAnswerShortcut.self, ChatsAnswerShortcut.Params(
                    chatID: uuid, requestID: request.requestID, answer: answer))
            } catch let error as EngineError where error.code == .conflict && shortcutAnsweredElsewhere(request.id) {
                return
            } catch {
                alert(.failure(action, error))
            }
        }
    }

    private func shortcutAnsweredElsewhere(_ itemID: String) -> Bool {
        guard case .shortcut(let request)? = transcriptState?.item(itemID) else { return false }
        return request.answer != nil
    }

    // MARK: Animation card

    /// The card appeared for a request: the recommended suggestion selected, the Custom row
    /// holding its preset and parameters, the field empty and every circle at the left end. The
    /// same request keeps its state.
    func animationRequestShown(_ request: AnimationItem) {
        guard animationRequestID != request.requestID else { return }
        animationRequestID = request.requestID
        animationChoice = .suggestion(request.recommended)
        animationOther = ""
        let recommended = (try? AnimationExpression(parsing: request.recommended)) ?? AnimationExpression(preset: .spring)
        animationCustomPreset = recommended.preset
        animationCustomValues = Dictionary(uniqueKeysWithValues: AnimationParameter.allCases.map { ($0, recommended.value($0)) })
        animationPlays = [:]
    }

    /// The Custom row's animation: its preset with the values of the preset's sliders.
    var animationCustom: AnimationExpression {
        AnimationExpression(preset: animationCustomPreset,
                            values: animationCustomValues.filter { animationCustomPreset.parameters.contains($0.key) })
    }

    /// Plays a lane again from the left end.
    func playAnimationLane(_ lane: AnimationLaneID) {
        animationPlays[lane, default: 0] += 1
    }

    /// Play All: every suggestion's lane and the Custom lane together.
    func playAllAnimationLanes(_ request: AnimationItem) {
        for suggestion in request.suggestions {
            playAnimationLane(.suggestion(suggestion))
        }
        playAnimationLane(.custom)
    }

    /// A click on a suggestion's row: selects it and plays its lane.
    func selectAnimationSuggestion(_ expression: String) {
        animationChoice = .suggestion(expression)
        playAnimationLane(.suggestion(expression))
    }

    /// A click on the Custom row: selects it and plays its lane.
    func selectAnimationCustom() {
        animationChoice = .custom
        playAnimationLane(.custom)
    }

    /// Choosing a preset selects the Custom row and plays its lane.
    func setAnimationCustomPreset(_ preset: AnimationPreset) {
        animationCustomPreset = preset
        animationChoice = .custom
        playAnimationLane(.custom)
    }

    /// Moving a slider selects the Custom row; the value is kept rounded to two decimals.
    func setAnimationCustomValue(_ value: Double, for parameter: AnimationParameter) {
        let hundredths = (value * 100).rounded()
        let rounded = hundredths == 0 ? 0 : hundredths / 100
        animationCustomValues[parameter] = min(max(rounded, parameter.range.lowerBound), parameter.range.upperBound)
        animationChoice = .custom
    }

    /// The value of a slider of the Custom row.
    func animationCustomValue(_ parameter: AnimationParameter) -> Double {
        animationCustomValues[parameter] ?? animationCustomPreset.defaultValue(parameter)
    }

    /// The answer the card submits: `![](animation:<expression>)` for the selected suggestion or
    /// the Custom row, or the field's text.
    var animationAnswer: String {
        switch animationChoice {
        case .suggestion(let expression): return "![](animation:\(expression))"
        case .custom: return "![](animation:\(animationCustom.fullExpression))"
        case .other: return animationOther.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var canSubmitAnimation: Bool {
        !animationAnswer.isEmpty && !isSubmittingAnimation
    }

    /// Submit: `chats.answerAnimation` with the selected answer.
    func submitAnimation() {
        guard canSubmitAnimation else { return }
        answerAnimationRequest(animationAnswer, action: "Submit")
    }

    /// Skip: `chats.answerAnimation` with `Skipped`.
    func skipAnimation() {
        guard !isSubmittingAnimation else { return }
        answerAnimationRequest(QuestionNavigation.skipped, action: "Skip")
    }

    /// Stores the answer of the waiting animation request. An answer that fails because the
    /// request was answered on another device shows no alert.
    private func answerAnimationRequest(_ answer: String, action: String) {
        guard let chatID, let uuid = UUID(uuidString: chatID), let request = transcriptState?.waitingAnimationRequest else {
            return
        }
        isSubmittingAnimation = true
        Task {
            defer { isSubmittingAnimation = false }
            do {
                _ = try await workspace.call(ChatsAnswerAnimation.self, ChatsAnswerAnimation.Params(
                    chatID: uuid, requestID: request.requestID, answer: answer))
            } catch let error as EngineError where error.code == .conflict && animationAnsweredElsewhere(request.id) {
                return
            } catch {
                alert(.failure(action, error))
            }
        }
    }

    private func animationAnsweredElsewhere(_ itemID: String) -> Bool {
        guard case .animation(let request)? = transcriptState?.item(itemID) else { return false }
        return request.answer != nil
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

    /// While the shortcut card's recorder field records, every key press of the window goes to
    /// it. Otherwise ⌘Return, ⌥⌘Return and ⇧⌘Return answer the permission card once its request
    /// has been shown for 1 second; ⌘Return submits the questions card, the symbol card, the color
    /// card, the sound card, the shortcut card, the font card or the animation card when no
    /// permission card is shown and the card is not minimized. Both act only while the focus is in
    /// this chat view outside its composer.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        if isRecordingShortcut {
            recordShortcutKey(keyCode: event.keyCode, modifierFlags: event.modifierFlags,
                              unmodifiedCharacters: event.characters(byApplyingModifiers: []))
            return true
        }
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
        if flags == [.command], let request = state.waitingSymbolRequest, let chatID,
           app?.isQuestionsCardMinimized(chatID: chatID, setID: request.requestID) != true {
            submitSymbol()
            return true
        }
        if flags == [.command], let request = state.waitingColorRequest, let chatID,
           app?.isQuestionsCardMinimized(chatID: chatID, setID: request.requestID) != true {
            submitColor()
            return true
        }
        if flags == [.command], let request = state.waitingSoundRequest, let chatID,
           app?.isQuestionsCardMinimized(chatID: chatID, setID: request.requestID) != true {
            submitSound()
            return true
        }
        if flags == [.command], let request = state.waitingShortcutRequest, let chatID,
           app?.isQuestionsCardMinimized(chatID: chatID, setID: request.requestID) != true {
            submitShortcut()
            return true
        }
        if flags == [.command], let request = state.waitingFontRequest, let chatID,
           app?.isQuestionsCardMinimized(chatID: chatID, setID: request.requestID) != true {
            submitFont()
            return true
        }
        if flags == [.command], let request = state.waitingAnimationRequest, let chatID,
           app?.isQuestionsCardMinimized(chatID: chatID, setID: request.requestID) != true {
            submitAnimation()
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

    /// Close in the More menu: the confirmation, then `chats.close`.
    func confirmClose() {
        guard let meta, let app else { return }
        ChatActions.confirmClose([meta], workspace: workspace, window: window, app: app)
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

    /// A ticket or bundle id clicked in a pinned card (docs/chats.md › Links, images and files).
    func openID(_ id: String) {
        guard let app else { return }
        ChatNavigator.navigate(to: .item(id: id), from: window, workspace: workspace, app: app)
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

    /// Close is enabled when at least one of the chats it acts on has `closed` false
    /// (docs/chats.md › Closing a chat).
    static func canClose(_ chats: [ChatMeta]) -> Bool {
        chats.contains { !$0.closed }
    }

    /// `Close the chat “<title>”?` for one chat, `Close <n> chats?` for several.
    static func closeQuestion(_ chats: [ChatMeta]) -> String {
        if chats.count == 1, let meta = chats.first {
            return "Close the chat “\(meta.title)”?"
        }
        return "Close \(chats.count) chats?"
    }

    /// Close asks `closeQuestion` with the buttons Close and Cancel, then calls `chats.close` for
    /// each chat whose `closed` is false, in the given order; the first failure shows `Close
    /// failed` and the chats after it are not closed.
    static func confirmClose(_ chats: [ChatMeta], workspace: DeviceWorkspace, window: NSWindow?, app: AppModel) {
        guard canClose(chats) else { return }
        let alert = NSAlert()
        alert.messageText = closeQuestion(chats)
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        ChatAlerts.present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                for meta in chats where !(workspace.chats[meta.id.uuidString] ?? meta).closed {
                    do {
                        _ = try await workspace.call(ChatsClose.self, ChatsClose.Params(chatID: meta.id))
                    } catch {
                        ChatAlerts.failure("Close", error, in: window, app: app)
                        return
                    }
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
