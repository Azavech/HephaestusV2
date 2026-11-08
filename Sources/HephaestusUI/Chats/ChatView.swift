// OWNER: ui-chats — the chat view: header, transcript, pinned cards, status line and composer (docs/chats.md › Chat view).
import AppKit
import HephaestusCore
import SwiftUI
import UniformTypeIdentifiers

/// One chat of a device, or a draft chat; `chats.get` loads its transcript into
/// `DeviceWorkspace.transcripts`.
///
/// From top to bottom: the header, the transcript, the pinned permission card, the pinned
/// questions card, symbol card, color card, sound card, shortcut card, font card or animation card,
/// the status line and the composer. The header shows in the Chats section, the ticket and bundle
/// Chats tabs and chat windows; the inspector shows its picker instead.
struct ChatView: View {
    /// The chat id, an uppercase UUID string; nil for a draft.
    let chatID: String?
    let draft: DraftChat?
    let workspace: DeviceWorkspace
    var showsHeader = true
    /// Inside a chat window, Open in New Window is hidden.
    var isInChatWindow = false
    /// In the inspector, the view and its transcript draw no background, so the inspector's frosted
    /// material shows through (docs/chats.md › Chat view).
    var isInInspector = false
    /// Incremented to put the keyboard focus in the composer.
    var focusRequest = 0
    /// A draft shown by New Chat puts the keyboard focus in its composer when it appears.
    var focusesComposer = false
    /// Called with the chat that a draft's first Send created.
    var onCreated: (ChatMeta) -> Void = { _ in }
    /// The items of the window linked to the inspector chat (docs/chats.md › Linked items).
    var linkedItems: [LinkedItem] = []
    var onUnlink: ((LinkedItemRef) -> Void)?

    /// An existing chat.
    init(chatID: String, workspace: DeviceWorkspace, showsHeader: Bool = true, isInChatWindow: Bool = false,
         isInInspector: Bool = false, linkedItems: [LinkedItem] = [], onUnlink: ((LinkedItemRef) -> Void)? = nil) {
        self.chatID = chatID
        self.draft = nil
        self.workspace = workspace
        self.showsHeader = showsHeader
        self.isInChatWindow = isInChatWindow
        self.isInInspector = isInInspector
        self.linkedItems = linkedItems
        self.onUnlink = onUnlink
    }

    /// A draft chat: its composer has the keyboard focus, and its first Send calls `chats.create`.
    init(draft: DraftChat, workspace: DeviceWorkspace, showsHeader: Bool = true, isInInspector: Bool = false,
         focusRequest: Int = 0, focusesComposer: Bool = true, linkedItems: [LinkedItem] = [],
         onUnlink: ((LinkedItemRef) -> Void)? = nil, onCreated: @escaping (ChatMeta) -> Void) {
        self.chatID = nil
        self.draft = draft
        self.workspace = workspace
        self.showsHeader = showsHeader
        self.isInInspector = isInInspector
        self.linkedItems = linkedItems
        self.onUnlink = onUnlink
        self.focusRequest = focusRequest
        self.focusesComposer = focusesComposer
        self.onCreated = onCreated
    }

    var body: some View {
        ChatViewContent(chatID: chatID, draft: draft, workspace: workspace, showsHeader: showsHeader,
                        isInChatWindow: isInChatWindow, isInInspector: isInInspector, focusRequest: focusRequest,
                        focusesComposer: focusesComposer, linkedItems: linkedItems, onUnlink: onUnlink, onCreated: onCreated)
            .id(chatID ?? draft?.id.uuidString ?? "")
    }
}

/// A draft chat of a project, a ticket or a bundle (docs/chats.md › Draft chats): an empty chat
/// view whose composer (settings menus, attachments, CLI status lines) uses the default settings
/// and has the keyboard focus; its first Send calls `chats.create` with the kind, the ticket or
/// bundle, the message and the draft's settings, then `onCreated` receives the new chat's id. Show
/// a new draft (a new view identity) for each New Chat.
struct ChatDraftView: View {
    let projectID: String
    let kind: ChatKind
    var ticketID: String?
    var bundleID: String?
    let workspace: DeviceWorkspace
    let onCreated: (ChatID) -> Void
    @State private var draft: DraftChat

    init(projectID: String, kind: ChatKind, ticketID: String? = nil, bundleID: String? = nil, workspace: DeviceWorkspace,
         onCreated: @escaping (ChatID) -> Void) {
        self.projectID = projectID
        self.kind = kind
        self.ticketID = ticketID
        self.bundleID = bundleID
        self.workspace = workspace
        self.onCreated = onCreated
        _draft = State(initialValue: DraftChat(projectID: projectID, kind: kind, ticketID: ticketID, bundleID: bundleID))
    }

    var body: some View {
        ChatView(draft: draft, workspace: workspace) { meta in
            onCreated(meta.id)
        }
    }
}

/// The chat view of one chat or draft; a new chat or draft gets a new content view and model.
private struct ChatViewContent: View {
    let workspace: DeviceWorkspace
    let showsHeader: Bool
    let isInChatWindow: Bool
    let isInInspector: Bool
    let focusRequest: Int
    let focusesComposer: Bool
    let linkedItems: [LinkedItem]
    let onUnlink: ((LinkedItemRef) -> Void)?
    let onCreated: (ChatMeta) -> Void
    @State private var model: ChatViewModel
    @State private var cardsHeight: CGFloat = 0
    @Environment(AppModel.self) private var app

    init(chatID: String?, draft: DraftChat?, workspace: DeviceWorkspace, showsHeader: Bool, isInChatWindow: Bool,
         isInInspector: Bool, focusRequest: Int, focusesComposer: Bool, linkedItems: [LinkedItem],
         onUnlink: ((LinkedItemRef) -> Void)?, onCreated: @escaping (ChatMeta) -> Void) {
        self.workspace = workspace
        self.showsHeader = showsHeader
        self.isInChatWindow = isInChatWindow
        self.isInInspector = isInInspector
        self.focusRequest = focusRequest
        self.focusesComposer = focusesComposer
        self.linkedItems = linkedItems
        self.onUnlink = onUnlink
        self.onCreated = onCreated
        _model = State(initialValue: ChatViewModel(workspace: workspace, chatID: chatID, draft: draft))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if showsHeader {
                    ChatHeader(model: model, isInChatWindow: isInChatWindow)
                    Divider()
                }
                if model.transcript.findVisible {
                    TranscriptFindBar(controller: model.transcript)
                    Divider()
                }
                transcriptArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                pinnedCards(maxHeight: geometry.size.height / 2)
                ChatStatusLine(model: model)
                if model.isClosed {
                    ChatClosedLine()
                } else {
                    ComposerView(model: model)
                }
            }
        }
        .background(isInInspector ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .background(ChatWindowReader(reference: model.windowReference))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            model.drop(providers)
        }
        .onAppear {
            model.onCreated = onCreated
            model.onUnlink = onUnlink
            model.appear(app: app, focusComposer: focusesComposer)
        }
        .onDisappear {
            model.disappear()
        }
        .onChange(of: focusRequest) {
            model.composerFocusRequest += 1
        }
        .onChange(of: linkedItems, initial: true) {
            model.linkedItems = linkedItems
        }
        .task(id: workspace.connectionGeneration) {
            model.ensureLoaded()
        }
        .task(id: model.chatProjectID) {
            workspace.ensureProjectLoaded(model.chatProjectID)
        }
        .onChange(of: shownQuestionSet, initial: true) {
            // A loaded transcript whose card shows another set, or none, ends the minimized state.
            if let chatID = model.chatID, let shown = shownQuestionSet {
                app.forgetMinimizedQuestionSet(chatID: chatID, shownSetID: shown.setID)
            }
        }
    }

    /// The question set, symbol request, color request, sound request, shortcut request, font
    /// request or animation request of the chat once its transcript is loaded; nil while it is not.
    private var shownQuestionSet: ShownQuestionSet? {
        guard let chatID = model.chatID, let state = workspace.transcripts[chatID] else { return nil }
        return ShownQuestionSet(setID: state.incompleteQuestionSet?.questionSetID ?? state.waitingSymbolRequest?.requestID
                                ?? state.waitingColorRequest?.requestID
                                ?? state.waitingSoundRequest?.requestID
                                ?? state.waitingShortcutRequest?.requestID
                                ?? state.waitingFontRequest?.requestID
                                ?? state.waitingAnimationRequest?.requestID)
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptArea: some View {
        if let chatID = model.chatID {
            let phase = ChatTranscriptStore.shared.phase(of: chatID, in: workspace)
            if case .failed(let message, let notFound) = phase {
                if notFound {
                    NotFoundView(kind: "Chat", id: chatID)
                } else {
                    TranscriptLoadFailedView(message: message) {
                        model.ensureLoaded(force: true)
                    }
                }
            } else if let state = workspace.transcripts[chatID] {
                TranscriptWebView(controller: model.transcript,
                                  input: TranscriptInput(state: state, context: model.renderContext, placeholder: model.placeholder),
                                  transparent: isInInspector)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            TranscriptWebView(controller: model.transcript,
                              input: TranscriptInput(state: TranscriptState(), context: model.renderContext, placeholder: model.placeholder),
                              transparent: isInInspector)
        }
    }

    // MARK: Pinned cards

    /// The permission card, then the questions card, the symbol card, the color card, the sound card,
    /// the shortcut card, the font card or the animation card; together at most half of
    /// the view's height, scrolling inside only when they are taller than that, without bounce
    /// while they fit, their code blocks and tables always scrolling horizontally.
    @ViewBuilder
    private func pinnedCards(maxHeight: CGFloat) -> some View {
        let state = model.chatID.flatMap { workspace.transcripts[$0] }
        let pending = state?.pendingPermissionRequests ?? []
        let set = state?.incompleteQuestionSet
        let question = set.flatMap { model.displayedQuestion($0) }
        let symbolRequest = state?.waitingSymbolRequest
        let colorRequest = state?.waitingColorRequest
        let soundRequest = state?.waitingSoundRequest
        let shortcutRequest = state?.waitingShortcutRequest
        let fontRequest = state?.waitingFontRequest
        let animationRequest = state?.waitingAnimationRequest
        if !pending.isEmpty || question != nil || symbolRequest != nil || colorRequest != nil || soundRequest != nil
            || shortcutRequest != nil || fontRequest != nil || animationRequest != nil {
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    if let request = pending.first {
                        PermissionCard(model: model, request: request, count: pending.count)
                    }
                    if let chatID = model.chatID, let set, let question {
                        if app.isQuestionsCardMinimized(chatID: chatID, setID: set.questionSetID) {
                            QuestionsCollapsedBar(text: QuestionNavigation.header(set, question)) {
                                app.setQuestionsCardMinimized(false, chatID: chatID, setID: set.questionSetID)
                            }
                        } else {
                            QuestionsCard(model: model, set: set, question: question) {
                                app.setQuestionsCardMinimized(true, chatID: chatID, setID: set.questionSetID)
                            }
                        }
                    }
                    if let chatID = model.chatID, let symbolRequest {
                        if app.isQuestionsCardMinimized(chatID: chatID, setID: symbolRequest.requestID) {
                            QuestionsCollapsedBar(text: "Symbol") {
                                app.setQuestionsCardMinimized(false, chatID: chatID, setID: symbolRequest.requestID)
                            }
                        } else {
                            SymbolCard(model: model, request: symbolRequest) {
                                app.setQuestionsCardMinimized(true, chatID: chatID, setID: symbolRequest.requestID)
                            }
                        }
                    }
                    if let chatID = model.chatID, let colorRequest {
                        if app.isQuestionsCardMinimized(chatID: chatID, setID: colorRequest.requestID) {
                            QuestionsCollapsedBar(text: "Color") {
                                app.setQuestionsCardMinimized(false, chatID: chatID, setID: colorRequest.requestID)
                            }
                        } else {
                            ColorCard(model: model, request: colorRequest) {
                                app.setQuestionsCardMinimized(true, chatID: chatID, setID: colorRequest.requestID)
                            }
                        }
                    }
                    if let chatID = model.chatID, let soundRequest {
                        if app.isQuestionsCardMinimized(chatID: chatID, setID: soundRequest.requestID) {
                            QuestionsCollapsedBar(text: "Sound") {
                                app.setQuestionsCardMinimized(false, chatID: chatID, setID: soundRequest.requestID)
                            }
                        } else {
                            SoundCard(model: model, request: soundRequest) {
                                app.setQuestionsCardMinimized(true, chatID: chatID, setID: soundRequest.requestID)
                            }
                        }
                    }
                    if let chatID = model.chatID, let shortcutRequest {
                        if app.isQuestionsCardMinimized(chatID: chatID, setID: shortcutRequest.requestID) {
                            QuestionsCollapsedBar(text: "Shortcut") {
                                app.setQuestionsCardMinimized(false, chatID: chatID, setID: shortcutRequest.requestID)
                            }
                        } else {
                            ShortcutCard(model: model, request: shortcutRequest) {
                                app.setQuestionsCardMinimized(true, chatID: chatID, setID: shortcutRequest.requestID)
                            }
                        }
                    }
                    if let chatID = model.chatID, let fontRequest {
                        if app.isQuestionsCardMinimized(chatID: chatID, setID: fontRequest.requestID) {
                            QuestionsCollapsedBar(text: "Font") {
                                app.setQuestionsCardMinimized(false, chatID: chatID, setID: fontRequest.requestID)
                            }
                        } else {
                            FontCard(model: model, request: fontRequest) {
                                app.setQuestionsCardMinimized(true, chatID: chatID, setID: fontRequest.requestID)
                            }
                        }
                    }
                    if let chatID = model.chatID, let animationRequest {
                        if app.isQuestionsCardMinimized(chatID: chatID, setID: animationRequest.requestID) {
                            QuestionsCollapsedBar(text: "Animation") {
                                app.setQuestionsCardMinimized(false, chatID: chatID, setID: animationRequest.requestID)
                            }
                        } else {
                            AnimationCard(model: model, request: animationRequest) {
                                app.setQuestionsCardMinimized(true, chatID: chatID, setID: animationRequest.requestID)
                            }
                            // A new request starts with every circle at the left end.
                            .id(animationRequest.requestID)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                // Ticket and bundle ids of the cards open with the chat's window choice, also in a
                // ticket's or a bundle's Chats tab (docs/chats.md › Links, images and files).
                .transformEnvironment(\.markdownContext) { [weak model, projectIdentifiers = workspace.projectIdentifiers] context in
                    context.options.projectIdentifiers = projectIdentifiers
                    context.openID = { id in model?.openID(id) }
                    context.playSound = { name in model?.playSound(name) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    cardsHeight = height
                }
                // `scrollDisabled` below reaches every nested scroll view through the environment;
                // code blocks and tables in the cards keep their horizontal scrolling.
                .environment(\.isScrollEnabled, true)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(cardsHeight + 1 <= max(maxHeight, 80))
            .frame(height: min(cardsHeight + 1, max(maxHeight, 80)))
        }
    }
}

/// The question set of a loaded transcript, nil when it has none.
private struct ShownQuestionSet: Equatable {
    var setID: UUID?
}

/// `The chat could not be loaded.`, the error's message and Try Again; the composer stays usable
/// (docs/ui.md › Empty states).
private struct TranscriptLoadFailedView: View {
    let message: String
    let tryAgain: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("The chat could not be loaded.")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Try Again", action: tryAgain)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Status line

/// The line above the composer (docs/chats.md › Chat states): hidden for idle, `Starting Claude…`,
/// `Claude is working… m:ss`, `Waiting for your permission`, `Waiting for your answers`, or
/// `Claude stopped with an error` in red.
struct ChatStatusLine: View {
    let model: ChatViewModel

    var body: some View {
        Group {
            switch model.state {
            case .idle:
                EmptyView()
            case .starting:
                line("Starting Claude…")
            case .running:
                let start = model.chatID.flatMap { ChatTranscriptStore.shared.runningSince($0, in: model.workspace) } ?? Date()
                TimelineView(.periodic(from: start, by: 1)) { context in
                    line("Claude is working… " + ChatFormat.elapsed(since: start, now: context.date))
                }
            case .waitingPermission:
                line("Waiting for your permission")
            case .waitingAnswers:
                line("Waiting for your answers")
            case .error:
                line("Claude stopped with an error")
                    .foregroundStyle(.red)
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 6)
    }
}

// MARK: - Closed chat

/// `This conversation is over`, in place of the composer of a closed chat (docs/chats.md ›
/// Composer).
struct ChatClosedLine: View {
    static let text = "This conversation is over"

    var body: some View {
        Text(Self.text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 16)
    }
}

// MARK: - Header

/// The title (double-click edits it in place: Return renames, Escape cancels), the kind chip with
/// the linked ticket or bundle id, Open in New Window and the More menu with Close while the chat
/// is open or Reopen while it is closed, Rename… and Delete…, on one row as high as a pane header
/// (docs/ui.md › Pane headers).
struct ChatHeader: View {
    @Bindable var model: ChatViewModel
    let isInChatWindow: Bool
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if model.isRenaming {
                TextField("", text: $model.renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .focused($titleFocused)
                    .onSubmit {
                        model.commitRename()
                    }
                    .onExitCommand {
                        model.cancelRename()
                    }
                    .onAppear {
                        titleFocused = true
                    }
                    .onChange(of: titleFocused) { _, focused in
                        // Leaving the field cancels (docs/chats.md › Chat view).
                        if !focused {
                            model.cancelRename()
                        }
                    }
                    .frame(maxWidth: 360)
            } else {
                Text(model.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) {
                        model.startRename()
                    }
            }
            KindChip(model: model)
            Spacer(minLength: 8)
            // A draft's header has no Open in New Window and no More menu (docs/chats.md › Chat view).
            if model.meta != nil {
                if !isInChatWindow {
                    Button {
                        model.openInNewWindow()
                    } label: {
                        Image(systemName: "macwindow.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Open in New Window")
                    .accessibilityLabel("Open in New Window")
                }
                Menu {
                    if model.isClosed {
                        Button("Reopen") {
                            model.reopen()
                        }
                    } else {
                        Button("Close") {
                            model.confirmClose()
                        }
                    }
                    Button("Rename…") {
                        model.startRename()
                    }
                    Button("Delete…") {
                        model.confirmDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 12)
        .paneHeaderBar()
    }
}

/// The kind and, for ticket, bundle, CI and linked feedback chats, the ticket or bundle id; clicking
/// the id navigates to it.
private struct KindChip: View {
    let model: ChatViewModel

    var body: some View {
        let linkedID = model.meta?.bundleID ?? model.meta?.ticketID ?? model.draft?.bundleID ?? model.draft?.ticketID
        HStack(spacing: 4) {
            Text(ChatFormat.kindTitle(model.kind))
            if let linkedID {
                Button(linkedID) {
                    model.navigateToLink()
                }
                .buttonStyle(.link)
                .foregroundStyle(Color.accentColor)
                .font(.system(.caption, design: .monospaced))
                .disabled(model.meta == nil)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .fixedSize()
    }
}
