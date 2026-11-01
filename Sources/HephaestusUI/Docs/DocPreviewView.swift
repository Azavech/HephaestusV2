// OWNER: ui-code-docs — the preview web view (docs/documentation-viewer.md › Preview web view, › Link activation).
import AppKit
import HephaestusCore
import HephaestusText
import SwiftUI
import WebKit

/// The `WKWebView` loading `doc.html`, `doc.js` and `markdown.css`, with its find bar.
struct DocPreviewView: View {
    let text: String
    /// Project path of the doc; its folder is the renderer's `baseDirectory`.
    let docPath: String
    let workspace: DeviceWorkspace
    let projectID: String
    /// The window whose navigation the links drive; without one, links do nothing.
    var window: WindowState?
    @State private var controller = DocPreviewController()

    init(buffer: EditorBuffer, workspace: DeviceWorkspace, projectID: String, window: WindowState? = nil) {
        self.text = buffer.text
        self.docPath = buffer.path
        self.workspace = workspace
        self.projectID = projectID
        self.window = window
    }

    /// A preview of any Markdown text belonging to `docPath`'s folder.
    init(text: String, docPath: String, workspace: DeviceWorkspace, projectID: String, window: WindowState? = nil) {
        self.text = text
        self.docPath = docPath
        self.workspace = workspace
        self.projectID = projectID
        self.window = window
    }

    var body: some View {
        VStack(spacing: 0) {
            if controller.findBarVisible {
                PreviewFindBar(controller: controller)
                Divider()
            }
            PreviewWebViewHost(controller: controller)
        }
        .onAppear {
            controller.configure(workspace: workspace, projectID: projectID, window: window)
            controller.show(text: text, docPath: docPath)
        }
        .onChange(of: text) { _, newText in
            controller.show(text: newText, docPath: docPath)
        }
        .onChange(of: docPath) { _, newPath in
            controller.show(text: text, docPath: newPath)
        }
    }
}

/// Hosts the controller's web view.
private struct PreviewWebViewHost: NSViewRepresentable {
    let controller: DocPreviewController

    func makeNSView(context: Context) -> EditorContainerView {
        let view = EditorContainerView()
        view.show(controller.webView)
        return view
    }

    func updateNSView(_ view: EditorContainerView, context: Context) {
        view.show(controller.webView)
    }

    static func dismantleNSView(_ view: EditorContainerView, coordinator: ()) {
        view.removeContent()
    }
}

/// The find bar above the preview: a search field, `◀` and `▶`, `Done`, and `Not found`
/// (docs/documentation-viewer.md › Modes, Find).
private struct PreviewFindBar: View {
    @Bindable var controller: DocPreviewController
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Search", text: $controller.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($fieldFocused)
                .onKeyPress(.return, phases: .down) { press in
                    controller.find(backwards: press.modifiers.contains(.shift))
                    return .handled
                }
                .onExitCommand {
                    controller.hideFindBar()
                }
            if controller.notFound {
                Text("Not found")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ControlGroup {
                Button {
                    controller.find(backwards: true)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .keyboardShortcut(fieldFocused ? KeyboardShortcut("g", modifiers: [.command, .shift]) : nil)
                Button {
                    controller.find(backwards: false)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .keyboardShortcut(fieldFocused ? KeyboardShortcut("g", modifiers: .command) : nil)
            }
            .fixedSize()
            Button("Done") {
                controller.hideFindBar()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            fieldFocused = true
        }
        .onChange(of: controller.focusFieldRequest) {
            fieldFocused = true
        }
    }
}

// MARK: - Controller

/// The web view of one preview: loading of `doc.html`, rendering, messages, link activation and
/// find.
@MainActor @Observable
final class DocPreviewController: NSObject, WKNavigationDelegate {
    @ObservationIgnored private(set) var webView: PreviewWebView!
    var findBarVisible = false
    var searchText = ""
    var notFound = false
    /// Incremented to put the focus in the find field.
    var focusFieldRequest = 0
    @ObservationIgnored private weak var workspace: DeviceWorkspace?
    @ObservationIgnored private var projectID = ""
    @ObservationIgnored private weak var window: WindowState?
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var didLoadPage = false
    @ObservationIgnored private var text = ""
    @ObservationIgnored private var docPath = ""
    @ObservationIgnored private var renderedPath: String?
    @ObservationIgnored private var renderGeneration = 0
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var hasRendered = false

    override init() {
        super.init()
    }

    /// Sets the engine and the window; creates the web view with its scheme handler once.
    func configure(workspace: DeviceWorkspace, projectID: String, window: WindowState?) {
        self.window = window
        guard webView == nil || self.workspace !== workspace || self.projectID != projectID else { return }
        self.workspace = workspace
        self.projectID = projectID
        let configuration = WKWebViewConfiguration()
        let handler = ResourceSchemeHandler(connection: workspace.connection, projectID: projectID)
        configuration.setURLSchemeHandler(handler, forURLScheme: ResourceSchemeHandler.fileScheme)
        configuration.setURLSchemeHandler(handler, forURLScheme: ResourceSchemeHandler.attachmentScheme)
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: "hephaestus")
        let view = PreviewWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.controller = self
        webView = view
        isReady = false
        didLoadPage = false
        hasRendered = false
        renderedPath = nil
        if let page = Bundle.module.url(forResource: "doc", withExtension: "html", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "doc", withExtension: "html") {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    /// Renders a text: at once for a new doc, 200 ms after the last change otherwise, keeping the
    /// scroll position (docs/documentation-viewer.md › Modes).
    func show(text: String, docPath: String) {
        let isNewDoc = docPath != self.docPath || !hasRendered
        guard isNewDoc || text != self.text else { return }
        self.text = text
        self.docPath = docPath
        renderTask?.cancel()
        let delay: Duration = isNewDoc ? .zero : .milliseconds(200)
        renderTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.render()
        }
    }

    private func render() async {
        guard isReady, let workspace else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let path = docPath
        let options = MarkdownRenderOptions(baseDirectory: ProjectPaths.parent(of: path),
                                            projectRootPath: workspace.project(projectID)?.rootPath,
                                            stripFrontMatter: true)
        let source = text
        let html = await Task.detached(priority: .userInitiated) {
            MarkdownHTMLRenderer.render(source, options: options)
        }.value
        guard generation == renderGeneration, let webView else { return }
        let keepScroll = renderedPath == path
        var fragment: String?
        if let window {
            let entry = CodeDocsStore.shared.entry(window: window, projectID: projectID)
            if let pending = entry.pendingFragment, pending.path == path {
                fragment = pending.fragment
                entry.pendingFragment = nil
            }
        }
        renderedPath = path
        hasRendered = true
        let payload: [String: Any] = ["html": html, "keepScroll": keepScroll, "fragment": fragment ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript("HephaestusDoc.render(\(json))")
    }

    /// Scrolls the shown doc to an element id.
    func scroll(to fragment: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [fragment]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("HephaestusDoc.scrollToFragment(\(json)[0])")
    }

    // MARK: Messages (docs/documentation-viewer.md › Preview web view)

    func receive(_ body: Any) {
        guard let message = body as? [String: Any], let action = message["action"] as? String else { return }
        switch action {
        case "ready":
            isReady = true
            hasRendered = false
            Task { await render() }
        case "openLink":
            guard let url = message["url"] as? String else { return }
            openLink(url, commandKey: message["commandKey"] as? Bool ?? false)
        case "copy":
            guard let text = message["text"] as? String else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        default:
            // Messages with an unknown action are ignored.
            break
        }
    }

    /// docs/documentation-viewer.md › Link activation.
    private func openLink(_ url: String, commandKey: Bool) {
        guard let workspace, let window else { return }
        let projectID = self.projectID
        let docsPath = workspace.details[projectID]?.project.docsPath ?? "docs"
        let activation = DocLinks.activation(of: url, baseDirectory: ProjectPaths.parent(of: docPath),
                                             projectRootPath: workspace.project(projectID)?.rootPath, docsPath: docsPath)
        switch activation {
        case .none:
            break
        case .scroll(let fragment):
            scroll(to: fragment)
        case .web(let address):
            if commandKey {
                if let link = URL(string: address) {
                    NSWorkspace.shared.open(link)
                }
                return
            }
            Task {
                do {
                    let tab = try await workspace.call(WebTabsOpen.self, WebTabsOpen.Params(projectID: projectID, url: address))
                    await window.navigate(to: .webTab(projectID: projectID, tabID: tab.id))
                } catch {
                    // DOC-GAP: docs/documentation-viewer.md › Link activation gives no failure
                    // text for `webTabs.open`; the alert of docs/ui.md › Principles is shown.
                    window.alert = .failure("Open Link", error)
                }
            }
        case .doc(let path, let fragment):
            if path == docPath {
                if let fragment {
                    scroll(to: fragment)
                }
                return
            }
            let entry = CodeDocsStore.shared.entry(window: window, projectID: projectID)
            entry.pendingFragment = fragment.map { (path, $0) }
            Task {
                await window.navigate(to: .doc(projectID: projectID, path: path))
                if FileActions.viewState(window, projectID).selectedDocPath != path, entry.pendingFragment?.path == path {
                    entry.pendingFragment = nil
                }
            }
        case .file(let path, let line):
            Task {
                await window.navigate(to: .file(projectID: projectID, path: path, line: line))
            }
        }
    }

    // MARK: Find

    func showFindBar() {
        findBarVisible = true
        focusFieldRequest += 1
    }

    func hideFindBar() {
        findBarVisible = false
        notFound = false
        webView?.window?.makeFirstResponder(webView)
    }

    /// Searches the rendered text, case-insensitive, wrapping.
    func find(backwards: Bool) {
        guard let webView, !searchText.isEmpty else {
            NSSound.beep()
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(searchText, configuration: configuration) { [weak self] result in
            self?.notFound = !result.matchFound
        }
    }

    /// Use Selection for Find.
    func useSelectionForFind() {
        webView?.evaluateJavaScript("window.getSelection().toString()") { [weak self] value, _ in
            guard let text = value as? String, !text.isEmpty else { return }
            MainActor.assumeIsolated {
                self?.searchText = text
            }
        }
    }

    // MARK: WKNavigationDelegate

    /// Only the initial load of `doc.html` is allowed; every other navigation is cancelled.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if !didLoadPage, navigationAction.request.url?.isFileURL == true,
           navigationAction.request.url?.lastPathComponent == "doc.html" {
            didLoadPage = true
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}

/// Forwards script messages without retaining the controller.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: DocPreviewController?

    init(_ target: DocPreviewController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.receive(message.body)
        }
    }
}

/// The preview's web view: the find bar, plain-text copy and the reduced context menu.
final class PreviewWebView: WKWebView {
    weak var controller: DocPreviewController?

    /// The context menu keeps Copy, Copy Link, Copy Image and Look Up.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let kept: Set<String> = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink",
                                 "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierLookUp"]
        for item in menu.items where !item.isSeparatorItem && !kept.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        // No leading, trailing or doubled separators.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator {
                    menu.removeItem(item)
                } else {
                    previousWasSeparator = true
                }
            } else {
                previousWasSeparator = false
            }
        }
        if let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
        super.willOpenMenu(menu, with: event)
    }

    /// ⌘C copies the selection as plain text.
    @objc func copy(_ sender: Any?) {
        evaluateJavaScript("window.getSelection().toString()") { value, _ in
            guard let text = value as? String else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0
        switch NSTextFinder.Action(rawValue: tag) {
        case .showFindInterface:
            controller?.showFindBar()
        case .nextMatch:
            controller?.find(backwards: false)
        case .previousMatch:
            controller?.find(backwards: true)
        case .setSearchString:
            controller?.useSelectionForFind()
        case .hideFindInterface:
            controller?.hideFindBar()
        default:
            break
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) {
            switch NSTextFinder.Action(rawValue: item.tag) {
            case .showFindInterface, .setSearchString:
                return true
            case .nextMatch, .previousMatch:
                return !(controller?.searchText.isEmpty ?? true)
            case .hideFindInterface:
                return controller?.findBarVisible ?? false
            default:
                return false
            }
        }
        return super.validateUserInterfaceItem(item)
    }
}
