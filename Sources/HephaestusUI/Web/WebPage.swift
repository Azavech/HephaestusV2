// OWNER: ui-web-search — the web view of one tab in one window: configuration, navigation policy,
// stored URL and title, sync loads, load errors, popups, page dialogs and permissions
// (docs/web-tabs.md › Navigation and the stored URL, › Popups, › Downloads, › Page permissions and
// dialogs, › Website data; docs/remote.md › Localhost rewrite).
import AppKit
import HephaestusCore
import WebKit

/// A failed main-frame load shown by the error view (docs/web-tabs.md › Load errors).
struct WebLoadError: Equatable {
    /// The error's `localizedDescription`.
    var message: String
    /// The URL that failed, in stored form.
    var url: String
}

/// The `WKWebView` of a tab. Edit ▸ Find shows the window's find bar for the page
/// (docs/ui.md › Menus and keyboard shortcuts, note 1).
final class TabWebView: WKWebView {
    /// Called with the find action of Edit ▸ Find (show, next, previous, use selection).
    var onFindAction: ((NSTextFinder.Action) -> Void)?
    /// True while the find bar has a search string, for Find Next and Find Previous.
    var hasFindString: () -> Bool = { false }
    /// When the primary mouse button last went down or up in the web view.
    private(set) var lastClickTime: Date?
    private var clickMonitor: Any?

    /// True when a navigation of the page comes after a user click (docs/web-tabs.md › Schemes):
    /// a link activation, or a script navigation or form submission within 1 second of a click.
    func isAfterUserClick(_ action: WKNavigationAction, now: Date = Date()) -> Bool {
        switch action.navigationType {
        case .linkActivated:
            return true
        case .formSubmitted, .other:
            guard let lastClickTime else { return false }
            return now.timeIntervalSince(lastClickTime) <= 1
        default:
            return false
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
        } else if clickMonitor == nil {
            // A monitor, so that the clicks are seen whichever view of WebKit handles them.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.noteClick(event)
                }
                return event
            }
        }
    }

    private func noteClick(_ event: NSEvent) {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        lastClickTime = Date()
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let action = Self.action(of: sender) else { return }
        onFindAction?(action)
    }

    /// The older selector of the standard Find menu items; same tags for the actions used here.
    @objc func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) || item.action == #selector(performFindPanelAction(_:)) {
            switch NSTextFinder.Action(rawValue: item.tag) {
            case .showFindInterface:
                return true
            case .nextMatch, .previousMatch:
                return hasFindString()
            default:
                return false
            }
        }
        return super.validateUserInterfaceItem(item)
    }

    private static func action(of sender: Any?) -> NSTextFinder.Action? {
        guard let item = sender as? NSValidatedUserInterfaceItem else { return .showFindInterface }
        let action = NSTextFinder.Action(rawValue: item.tag)
        switch action {
        case .showFindInterface, .nextMatch, .previousMatch:
            return action
        default:
            return nil
        }
    }
}

/// One web view of a window: a stored tab, or a popup that is local to the window until it reaches
/// an `http` or `https` URL (docs/web-tabs.md › Popups). Its controller is the window's
/// `WebTabsController`.
@MainActor @Observable
final class WebPage: NSObject {
    /// Identity of the page inside its window, also used for local popup tabs.
    let localID = UUID()
    /// The stored tab the page shows; nil for a popup not stored yet.
    var tabID: UUID?
    /// True for a page whose web view WebKit asked for (`window.open`, `target="_blank"`).
    let isScriptOpened: Bool
    /// The page that opened this popup, in this window.
    @ObservationIgnored var openerLocalID: UUID?
    @ObservationIgnored weak var controller: WebTabsController?
    @ObservationIgnored let webView: TabWebView

    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress = 0.0
    /// The web view's `title`.
    var pageTitle = ""
    /// The web view's `url`.
    var pageURL: URL?
    var loadError: WebLoadError?

    /// The last URL this window wrote for the tab with `webTabs.update` or `webTabs.open`, so that
    /// its own echo in `webTabs.updated` is not taken for a change by another client.
    @ObservationIgnored var lastWrittenURL: String?
    /// True while a popup's `webTabs.open` is in flight.
    @ObservationIgnored var isBeingStored = false
    @ObservationIgnored private var syncNavigation: WKNavigation?
    @ObservationIgnored private var syncLoading = false
    @ObservationIgnored private var syncQuietUntil: Date?
    @ObservationIgnored private var storeTask: Task<Void, Never>?
    @ObservationIgnored private var storeChangeFromSync = false
    /// The URLs, in stored form, and the cleaned titles the web view reached during a sync load:
    /// none of them is written back until the web view reaches another URL (docs/web-tabs.md ›
    /// Changes from other clients).
    @ObservationIgnored private(set) var syncReachedURLs: Set<String> = []
    @ObservationIgnored private(set) var syncReachedTitles: Set<String> = []
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var isClosed = false

    /// The configuration of every web view of the app (docs/web-tabs.md › Web view configuration).
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    /// A page with a new web view; a popup passes the configuration WebKit gave, so that
    /// `window.opener` works.
    init(controller: WebTabsController, configuration: WKWebViewConfiguration? = nil, tabID: UUID?, isScriptOpened: Bool) {
        self.controller = controller
        self.tabID = tabID
        self.isScriptOpened = isScriptOpened
        webView = TabWebView(frame: .zero, configuration: configuration ?? Self.makeConfiguration())
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.onFindAction = { [weak self] action in
            guard let self else { return }
            self.controller?.findAction(action, in: self)
        }
        webView.hasFindString = { [weak self] in
            guard let controller = self?.controller else { return false }
            return controller.findBar.isVisible && !controller.findBar.text.isEmpty
        }
        observeWebView()
    }

    // MARK: Loading

    /// Loads a URL given in stored form, after the forward rewrite of a remote window.
    @discardableResult
    func load(storedURL: String) -> WKNavigation? {
        let loaded = controller?.loadedForm(of: storedURL) ?? storedURL
        guard let url = URL(string: loaded) else { return nil }
        return webView.load(URLRequest(url: url))
    }

    /// docs/web-tabs.md › Changes from other clients: the stored URL changed. A URL this window
    /// wrote itself is its own echo; a URL the web view already shows needs no load; otherwise the
    /// web view loads it, and nothing it reaches until that load ends, plus the 1-second wait, is
    /// written back.
    func storedURLChanged(to storedURL: String) {
        if storedURL == lastWrittenURL {
            lastWrittenURL = nil
            return
        }
        if let shown = shownStoredURL, shown == storedURL { return }
        syncLoading = true
        syncQuietUntil = nil
        syncReachedURLs = []
        syncReachedTitles = []
        syncNavigation = load(storedURL: storedURL)
        if syncNavigation == nil {
            syncLoading = false
        }
    }

    /// Coming back to a locked tab: the web view loads its original URL as this window's own
    /// navigation, which ends a sync load in progress and forgets what it reached, so the page's
    /// URL and title are stored again (docs/web-tabs.md › Original URL).
    func loadAsOwnNavigation(storedURL: String) {
        syncLoading = false
        syncNavigation = nil
        syncQuietUntil = nil
        syncReachedURLs = []
        syncReachedTitles = []
        load(storedURL: storedURL)
    }

    /// The URL the web view shows, in stored form.
    var shownStoredURL: String? {
        guard let url = webView.url else { return nil }
        return controller?.storedForm(of: url.absoluteString, tabID: tabID) ?? url.absoluteString
    }

    /// True while changes come from a sync load: until it ends, plus 1 second.
    private var isSyncQuiet: Bool {
        if syncLoading { return true }
        if let until = syncQuietUntil, Date() < until { return true }
        return false
    }

    private func navigationEnded(_ navigation: WKNavigation?) {
        guard syncLoading, let navigation, navigation === syncNavigation else { return }
        syncLoading = false
        syncNavigation = nil
        syncQuietUntil = Date().addingTimeInterval(1)
    }

    // MARK: Observing the page (docs/web-tabs.md › Storing what the page shows)

    private func observeWebView() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.urlOrTitleChanged() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.urlOrTitleChanged() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
        ]
    }

    /// The web view's `url` or `title` changed: once both stay unchanged for 1 second, the
    /// controller compares them with the stored tab. Changes reached during a sync load are
    /// never written.
    private func urlOrTitleChanged() {
        guard !isClosed else { return }
        pageURL = webView.url
        pageTitle = webView.title ?? ""
        controller?.pageDidChange(self)
        storeChangeFromSync = isSyncQuiet
        rememberSyncReached(quiet: storeChangeFromSync)
        storeTask?.cancel()
        storeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            if !self.storeChangeFromSync {
                self.controller?.storePage(self)
            }
        }
    }

    /// During a sync load, notes the URL and title reached; afterwards, a URL that is not one of
    /// them forgets them.
    private func rememberSyncReached(quiet: Bool) {
        let shown = shownStoredURL
        if quiet {
            if let shown {
                syncReachedURLs.insert(shown)
            }
            let title = WebTabsController.cleanedTitle(pageTitle)
            if !title.isEmpty {
                syncReachedTitles.insert(title)
            }
        } else if let shown, !syncReachedURLs.isEmpty, !syncReachedURLs.contains(shown) {
            syncReachedURLs = []
            syncReachedTitles = []
        }
    }

    // MARK: Closing

    /// Releases the web view: stops it, removes it from its window and drops its delegates.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        storeTask?.cancel()
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onFindAction = nil
        webView.removeFromSuperview()
    }
}

// MARK: - Navigation (docs/web-tabs.md › Schemes, › Load errors, › Downloads)

extension WebPage: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch scheme {
        case "http", "https":
            let address = controller?.deviceAddress
            if let address, LocalhostRewrite.isLoopback(url.absoluteString) {
                let rewritten = LocalhostRewrite.forward(url.absoluteString, deviceAddress: address)
                if rewritten != url.absoluteString, let rewrittenURL = URL(string: rewritten) {
                    decisionHandler(.cancel)
                    redirect(navigationAction, to: rewrittenURL, isMainFrame: isMainFrame)
                    return
                }
            }
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case "data", "blob":
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case "about":
            let isBlankOrSrcdoc = ["about:blank", "about:srcdoc"].contains { url.absoluteString.lowercased().hasPrefix($0) }
            decisionHandler(isBlankOrSrcdoc ? .allow : .cancel)
        case "file", "javascript":
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
            // Other schemes in the main frame after a user click go to macOS on this Mac.
            if isMainFrame, self.webView.isAfterUserClick(navigationAction) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// The forward rewrite of a navigation: the main frame loads the rewritten request; a frame
    /// is sent to the rewritten URL with `location.replace` evaluated in that frame.
    private func redirect(_ navigationAction: WKNavigationAction, to url: URL, isMainFrame: Bool) {
        if isMainFrame {
            var request = navigationAction.request
            request.url = url
            webView.load(request)
        } else if let frame = navigationAction.targetFrame,
                  let data = try? JSONEncoder().encode(url.absoluteString), let literal = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("window.location.replace(\(literal))", in: frame, in: .defaultClient, completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        controller?.downloads.start(download, pageURL: webView.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        controller?.downloads.start(download, pageURL: webView.url)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationEnded(navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationEnded(navigation)
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationEnded(navigation)
        showLoadError(error)
    }

    /// HTTP authentication and server certificates: default handling, without a credentials
    /// dialog; a certificate error fails the load and the error view shows.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    /// docs/web-tabs.md › Load errors: a main-frame failure other than a cancellation or WebKit's
    /// "frame load interrupted" shows the error view with the URL that failed in stored form.
    private func showLoadError(_ error: any Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        let failed = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? webView.url?.absoluteString ?? ""
        let stored = controller?.storedForm(of: failed, tabID: tabID) ?? failed
        loadError = WebLoadError(message: nsError.localizedDescription, url: stored)
    }
}

// MARK: - UI (docs/web-tabs.md › Popups, › Page permissions and dialogs)

extension WebPage: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        controller?.openPopup(from: self, configuration: configuration)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        controller?.pageDidClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        guard let controller else {
            completionHandler()
            return
        }
        controller.enqueueDialog(.alert, message: message, page: self) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let controller else {
            completionHandler(false)
            return
        }
        controller.enqueueDialog(.confirm, message: message, page: self) { answer in
            if case .confirmed(let value) = answer { completionHandler(value) } else { completionHandler(false) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard let controller else {
            completionHandler(nil)
            return
        }
        controller.enqueueDialog(.prompt(defaultText: defaultText ?? ""), message: prompt, page: self) { answer in
            if case .text(let value) = answer { completionHandler(value) } else { completionHandler(nil) }
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Camera and microphone are denied.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}
