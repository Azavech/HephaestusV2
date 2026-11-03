// OWNER: ui-chats — the transcript web view and its bridge (docs/chats.md › Transcript view).
import AppKit
import HephaestusCore
import Observation
import SwiftUI
import WebKit

/// What the transcript page shows: the chat's transcript state and what its fragments depend on.
struct TranscriptInput {
    var state: TranscriptState
    var context: TranscriptRenderContext
    /// Shown when the transcript has no item (docs/chats.md › Empty transcript).
    var placeholder: String?
}

/// The `WKWebView` of a transcript loading `chat.html`, `chat.css` and `chat.js`.
struct TranscriptWebView: NSViewRepresentable {
    let controller: TranscriptController
    let input: TranscriptInput
    /// In the inspector: no background, so the frosted material shows through.
    var transparent = false

    func makeNSView(context: Context) -> TranscriptWKWebView {
        controller.makeWebView(transparent: transparent)
    }

    func updateNSView(_ view: TranscriptWKWebView, context: Context) {
        controller.sync(input)
    }

    static func dismantleNSView(_ view: TranscriptWKWebView, coordinator: ()) {
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: TranscriptController.messageHandlerName)
    }
}

/// The page of one chat view: the web view, the bridge calls that bring the page up to date with
/// the transcript state, the messages of the page and the find bar
/// (docs/chats.md › Web view and bridge, › Selection and copying, › Scrolling and long transcripts).
@MainActor @Observable
final class TranscriptController {
    static let messageHandlerName = "hephaestus"
    /// A transcript renders its last 300 items; Show Earlier Messages adds the 300 previous ones.
    static let pageSize = 300

    // MARK: Find bar (docs/documentation-viewer.md › Modes)

    var findVisible = false
    var findText = ""
    var findNotFound = false
    /// Incremented to put the focus in the find field.
    var findFocusRequest = 0

    // MARK: Messages of the page

    /// `openLink`: the `href` as written and whether ⌘ was held.
    @ObservationIgnored var onOpenLink: ((String, Bool) -> Void)?
    /// `openAttachment`: the data path.
    @ObservationIgnored var onOpenAttachment: ((String) -> Void)?
    /// `playSound`: the name of a sound marker (docs/chats.md › Sound playback).
    @ObservationIgnored var onPlaySound: ((String) -> Void)?

    @ObservationIgnored private(set) weak var webView: TranscriptWKWebView?
    @ObservationIgnored private let connection: any EngineConnection
    /// The chat's project, read when the web view is made: by then the chat's metadata is known.
    @ObservationIgnored private let projectID: () -> String
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var input: TranscriptInput?
    /// The index of the first shown item.
    @ObservationIgnored private var shownStart = 0
    @ObservationIgnored private var shownGeneration: Int?
    @ObservationIgnored private var renderKeys: [String: RenderKey] = [:]
    @ObservationIgnored private var sentHTML: [String: String] = [:]
    @ObservationIgnored private var sentStreams: [String: Int] = [:]

    /// What a fragment's HTML depends on besides its item.
    private struct RenderKey: Equatable {
        var revision: Int
        var projectRootPath: String?
        /// Ticket and bundle ids of these projects are links.
        var projectIdentifiers: Set<String>
        /// For tool cards: whether the spinner shows, the result's error flag and the steps.
        var spinner = false
        var hasResult = false
        var resultIsError = false
        var steps = 0
        /// For question sets: the label marked with ➡️.
        var markedLabel: String?
        /// For user and assistant items: the day their captions were rendered for.
        var today: Date?
    }

    /// `connection` and the chat's project serve the images of the page (`ResourceSchemeHandler`,
    /// one per web view).
    init(connection: any EngineConnection, projectID: @escaping () -> String) {
        self.connection = connection
        self.projectID = projectID
    }

    /// A new page; SwiftUI makes one each time the transcript appears. A transparent page draws no
    /// background: the web view's is off and the class `transparent` on the page's root element
    /// clears the page's (docs/chats.md › Web view and bridge).
    func makeWebView(transparent: Bool = false) -> TranscriptWKWebView {
        ready = false
        shownGeneration = nil
        let configuration = WKWebViewConfiguration()
        let schemeHandler = ResourceSchemeHandler(connection: connection, projectID: projectID())
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ResourceSchemeHandler.fileScheme)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ResourceSchemeHandler.attachmentScheme)
        configuration.setURLSchemeHandler(SymbolSchemeHandler(), forURLScheme: SymbolSchemeHandler.scheme)
        configuration.setURLSchemeHandler(FontSchemeHandler(connection: connection, projectID: projectID()),
                                          forURLScheme: FontSchemeHandler.scheme)
        configuration.userContentController.add(TranscriptMessageProxy(controller: self), name: Self.messageHandlerName)
        if transparent {
            configuration.userContentController.addUserScript(WKUserScript(
                source: "document.documentElement.classList.add('transparent');",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let view = TranscriptWKWebView(frame: .zero, configuration: configuration)
        // WebKit can draw the page's background beyond the web view's bounds, over the views
        // next to the transcript.
        view.clipsToBounds = true
        view.controller = self
        view.navigationDelegate = view
        view.uiDelegate = view
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        if transparent {
            view.setValue(false, forKey: "drawsBackground")
            view.underPageBackgroundColor = .clear
        } else {
            view.underPageBackgroundColor = .textBackgroundColor
        }
        webView = view
        if let page = Self.pageURL {
            view.pageURL = page
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    static var pageURL: URL? {
        Bundle.module.url(forResource: "chat", withExtension: "html", subdirectory: "Resources")
    }

    // MARK: Bridge

    /// Brings the page up to date: `reset` when the page is new or the transcript was loaded
    /// again, else `upsert` for every new or changed fragment, `stream` for every changed
    /// streaming bubble and `clearStreams` when bubbles were removed.
    func sync(_ newInput: TranscriptInput) {
        input = newInput
        guard ready else { return }
        let state = newInput.state
        if shownGeneration != state.generation {
            reset()
            return
        }
        var calls: [String] = []
        if shownStart > state.items.count {
            shownStart = state.items.count
        }
        for item in state.items[shownStart...] {
            if let fragment = renderedIfChanged(item, state: state, context: newInput.context) {
                calls.append("HephaestusChat.upsert(\(Self.json(fragment)));")
            }
        }
        let removed = sentStreams.keys.filter { state.streams[$0] == nil && state.item($0) == nil }
        if !removed.isEmpty {
            calls.append("HephaestusChat.clearStreams();")
            sentStreams.removeAll()
        }
        for id in sentStreams.keys where state.item(id) != nil {
            sentStreams[id] = nil
        }
        calls += streamCalls(state: state, context: newInput.context)
        evaluate(calls)
    }

    private func reset() {
        guard let input else { return }
        let state = input.state
        shownGeneration = state.generation
        shownStart = max(0, state.items.count - Self.pageSize)
        renderKeys.removeAll()
        sentHTML.removeAll()
        sentStreams.removeAll()
        var fragments: [TranscriptFragment] = []
        for item in state.items[shownStart...] {
            if let fragment = renderedIfChanged(item, state: state, context: input.context) {
                fragments.append(fragment)
            }
        }
        let options = ResetOptions(items: fragments, hasEarlier: shownStart > 0, placeholder: input.placeholder)
        evaluate(["HephaestusChat.reset(\(Self.json(options)));"] + streamCalls(state: state, context: input.context))
    }

    /// `loadEarlier`: the 300 items before the first shown, with `prepend`.
    private func loadEarlier() {
        guard let input, shownStart > 0 else { return }
        let state = input.state
        let newStart = max(0, shownStart - Self.pageSize)
        var fragments: [TranscriptFragment] = []
        for item in state.items[newStart..<shownStart] {
            if let fragment = renderedIfChanged(item, state: state, context: input.context) {
                fragments.append(fragment)
            }
        }
        shownStart = newStart
        evaluate(["HephaestusChat.prepend(\(Self.json(PrependOptions(items: fragments, hasEarlier: newStart > 0))));"])
    }

    /// The fragment of an item when its HTML differs from what the page shows.
    private func renderedIfChanged(_ item: ChatItem, state: TranscriptState, context: TranscriptRenderContext) -> TranscriptFragment? {
        var key = RenderKey(revision: state.itemRevisions[item.id] ?? 0, projectRootPath: context.projectRootPath,
                            projectIdentifiers: context.projectIdentifiers)
        if case .toolUse(let use) = item {
            let result = state.result(forToolUseID: use.toolUseID)
            key.hasResult = result != nil
            key.resultIsError = result?.isError ?? false
            key.spinner = result == nil && context.chatIsRunning
            key.steps = state.stepCount(ofToolUseID: use.toolUseID)
        }
        if case .questions(let set) = item {
            key.markedLabel = context.markedLabel(set)
        }
        switch item {
        case .user, .assistant: key.today = context.today
        default: break
        }
        guard renderKeys[item.id] != key else { return nil }
        renderKeys[item.id] = key
        let fragment = TranscriptRenderer.fragment(for: item, in: state, context: context)
        guard sentHTML[item.id] != fragment.html else { return nil }
        sentHTML[item.id] = fragment.html
        return fragment
    }

    private func streamCalls(state: TranscriptState, context: TranscriptRenderContext) -> [String] {
        var calls: [String] = []
        for id in state.streamOrder {
            guard let buffer = state.streams[id], sentStreams[id] != buffer.revision else { continue }
            sentStreams[id] = buffer.revision
            let options = StreamOptions(itemID: id, kind: buffer.kind.rawValue,
                                        html: TranscriptRenderer.streamHTML(kind: buffer.kind, text: buffer.text, context: context))
            calls.append("HephaestusChat.stream(\(Self.json(options)));")
        }
        return calls
    }

    private func evaluate(_ calls: [String]) {
        guard !calls.isEmpty, let webView else { return }
        webView.evaluateJavaScript(calls.joined(separator: "\n"), completionHandler: nil)
    }

    private struct ResetOptions: Encodable {
        var items: [TranscriptFragment]
        var hasEarlier: Bool
        var placeholder: String?

        enum CodingKeys: String, CodingKey { case items, hasEarlier, placeholder }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(items, forKey: .items)
            try c.encode(hasEarlier, forKey: .hasEarlier)
            try c.encode(placeholder, forKey: .placeholder)
        }
    }

    private struct PrependOptions: Encodable {
        var items: [TranscriptFragment]
        var hasEarlier: Bool
    }

    private struct StreamOptions: Encodable {
        var itemID: String
        var kind: String
        var html: String
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    // MARK: Messages from the page

    /// The messages of docs/chats.md › Web view and bridge; others are ignored.
    func receive(_ body: Any) {
        guard let message = body as? [String: Any], let action = message["action"] as? String else { return }
        switch action {
        case "ready":
            ready = true
            shownGeneration = nil
            if input != nil {
                reset()
            }
        case "openLink":
            guard let url = message["url"] as? String else { return }
            onOpenLink?(url, message["commandKey"] as? Bool ?? false)
        case "copy":
            guard let text = message["text"] as? String else { return }
            Self.copyToPasteboard(text)
        case "openAttachment":
            guard let path = message["path"] as? String else { return }
            onOpenAttachment?(path)
        case "loadEarlier":
            loadEarlier()
        case "playSound":
            guard let name = message["name"] as? String else { return }
            onPlaySound?(name)
        default:
            break
        }
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Find

    /// Edit ▸ Find ▸ Find… (⌘F) with the focus in the transcript.
    func showFind() {
        findVisible = true
        findFocusRequest += 1
    }

    func hideFind() {
        findVisible = false
        findNotFound = false
        if let webView {
            webView.window?.makeFirstResponder(webView)
        }
    }

    /// Finds the next or previous match, case-insensitive, wrapping.
    func find(backwards: Bool) {
        guard let webView, !findText.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.caseSensitive = false
        configuration.wraps = true
        configuration.backwards = backwards
        webView.find(findText, configuration: configuration) { [weak self] result in
            self?.findNotFound = !result.matchFound
        }
    }
}

/// Forwards the page's messages without retaining the controller.
private final class TranscriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var controller: TranscriptController?

    init(controller: TranscriptController) {
        self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated {
            controller?.receive(body)
        }
    }
}

/// The transcript's web view: it never navigates, copies plain text, shows the transcript's find
/// bar, keeps only Copy, Copy Link, Copy Image and Look Up in its context menu, and leaves dropped
/// files to the chat view.
final class TranscriptWKWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    weak var controller: TranscriptController?
    var pageURL: URL?
    private var pageLoaded = false

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // Dropped files become attachments of the chat view (docs/chats.md › Composer).
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    // MARK: Navigation: only the initial load of chat.html

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if !pageLoaded, let pageURL, navigationAction.request.url?.standardizedFileURL == pageURL.standardizedFileURL {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    // MARK: Copying (docs/chats.md › Selection and copying)

    @objc func copy(_ sender: Any?) {
        evaluateJavaScript("window.getSelection().toString()") { result, _ in
            guard let text = result as? String, !text.isEmpty else { return }
            TranscriptController.copyToPasteboard(text)
        }
    }

    // The context menu keeps the items of the doc preview (docs/chats.md › Web view and bridge).
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let kept: Set<String> = [
            "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierCopyImage",
            "WKMenuItemIdentifierLookUp",
        ]
        for item in menu.items where !(item.identifier.map { kept.contains($0.rawValue) } ?? false) {
            menu.removeItem(item)
        }
        while let first = menu.items.first, first.isSeparatorItem {
            menu.removeItem(first)
        }
        super.willOpenMenu(menu, with: event)
    }

    // MARK: Find (docs/ui.md › Menus and keyboard shortcuts, Edit ▸ Find)

    @objc override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        guard let controller, let action = NSTextFinder.Action(rawValue: tag) else { return }
        switch action {
        case .showFindInterface:
            controller.showFind()
        case .nextMatch:
            controller.find(backwards: false)
        case .previousMatch:
            controller.find(backwards: true)
        case .hideFindInterface:
            controller.hideFind()
        default:
            break
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) {
            switch NSTextFinder.Action(rawValue: item.tag) {
            case .showFindInterface: return true
            case .nextMatch, .previousMatch: return controller?.findVisible == true && controller?.findText.isEmpty == false
            case .hideFindInterface: return controller?.findVisible == true
            default: return false
            }
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// The find bar above the transcript: a search field, `◀` and `▶`, `Done`; `Not found` next to
/// the field when nothing matches (docs/documentation-viewer.md › Modes).
struct TranscriptFindBar: View {
    @Bindable var controller: TranscriptController
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find", text: $controller.findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($fieldFocused)
                .onSubmit {
                    controller.find(backwards: NSEvent.modifierFlags.contains(.shift))
                }
                .onExitCommand {
                    controller.hideFind()
                }
                .onChange(of: controller.findText) {
                    controller.findNotFound = false
                }
            if controller.findNotFound {
                Text("Not found")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Button {
                controller.find(backwards: true)
            } label: {
                Text("◀")
            }
            .disabled(controller.findText.isEmpty)
            Button {
                controller.find(backwards: false)
            } label: {
                Text("▶")
            }
            .disabled(controller.findText.isEmpty)
            Spacer(minLength: 0)
            Button("Done") {
                controller.hideFind()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
        .onAppear {
            fieldFocused = true
        }
        .onChange(of: controller.findFocusRequest) {
            fieldFocused = true
        }
    }
}
