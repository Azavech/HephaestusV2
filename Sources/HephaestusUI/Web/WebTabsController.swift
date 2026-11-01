// OWNER: ui-web-search — the web tabs of one main window: web view lifetimes, selection, the
// placeholder and popup tabs, syncing with `webTabs.updated`, the tab actions and the Web section's
// menu commands (docs/web-tabs.md › Tab strip, › New tab, › Navigation and the stored URL,
// › Locking, › Popups, › Page permissions and dialogs, › Remote windows; docs/ui.md › Closing tabs
// and windows).
import AppKit
import HephaestusCore
import Observation
import WebKit

/// The identity of an item of a window's tab strip.
enum WebStripID: Hashable {
    case stored(UUID)
    /// A popup that is local to the window until it is stored, by `WebPage.localID`.
    case popup(UUID)
    /// The placeholder tab of ⌘T.
    case placeholder
}

/// An item of a window's tab strip, in strip order.
enum WebStripItem: Identifiable {
    case stored(WebTab)
    case popup(WebPage)
    case placeholder

    var id: WebStripID {
        switch self {
        case .stored(let tab): return .stored(tab.id)
        case .popup(let page): return .popup(page.localID)
        case .placeholder: return .placeholder
        }
    }
}

/// What the Web section shows.
enum WebSelection: Equatable {
    case item(WebStripID)
    /// A navigation named a tab that does not exist (docs/ui.md › Resolving a target).
    case notFound(String)
    /// No tab, or a selected tab that has not arrived yet.
    case none
}

/// The find bar of the Web section (docs/documentation-viewer.md › Modes, the preview's find bar).
struct WebFindState: Equatable {
    var isVisible = false
    var text = ""
    var notFound = false
    /// Each change puts the focus in the find field.
    var focusRequest = 0
}

/// A request to focus the URL field.
struct URLFieldFocus: Equatable {
    var count = 0
    /// True when the field shows an empty text (⌘T); otherwise it keeps or restores its text and
    /// selects it (⌥⌘L).
    var clearsText = false
}

/// A JavaScript dialog waiting for its sheet (docs/web-tabs.md › Page permissions and dialogs).
struct WebPageDialog: Identifiable {
    enum Kind: Equatable {
        case alert
        case confirm
        case prompt(defaultText: String)
    }

    enum Answer {
        case dismissed
        case confirmed(Bool)
        case text(String?)
    }

    let id = UUID()
    let kind: Kind
    /// The page's host.
    let title: String
    let message: String
    /// The `WebPage.localID` of the page that asked.
    let pageID: UUID
    /// The `tabID` of `WindowSheet.webPageDialog`.
    let sheetTabID: String
    let complete: (Answer) -> Void
}

/// A drag of a tab whose `webTabs.move` has not come back as `webTabs.updated` yet.
struct PendingMove: Equatable {
    var tabs: [WebTab]
    var tabID: UUID
    var toIndex: Int
}

/// The web tabs of one main window. One controller per window lives as long as the window; its
/// web views belong to the window's active project and are released when the window activates
/// another project or device, or closes (docs/web-tabs.md › Web views). It is the Web section's
/// `SectionCommandHandler`.
@MainActor @Observable
final class WebTabsController: SectionCommandHandler {
    @ObservationIgnored private static var controllers: [UUID: WebTabsController] = [:]

    /// The controller of a window, created the first time the window shows its Web section.
    static func controller(for window: WindowState) -> WebTabsController {
        if let existing = controllers[window.id], !existing.isTornDown {
            return existing
        }
        let controller = WebTabsController(window: window)
        controllers[window.id] = controller
        controller.start()
        return controller
    }

    /// The controller of a window, when it has one.
    static func existing(for window: WindowState) -> WebTabsController? {
        controllers[window.id]
    }

    /// The projects whose `selectedWebTabID` a navigation set in a window that has no controller
    /// yet, by window id.
    @ObservationIgnored private static var navigatedSelections: [UUID: Set<ProjectKey>] = [:]

    /// A `webTab` target is about to set the selection of a project in a window: that selection
    /// was set by a navigation, so a tab it names that does not exist shows the not-found text
    /// (docs/web-tabs.md › Selection), also when the window shows its Web section for the first
    /// time since launch.
    static func willSelectByNavigation(in window: WindowState, projectID: String) {
        let key = ProjectKey(deviceID: window.deviceID, projectID: projectID)
        if let controller = controllers[window.id], !controller.isTornDown {
            controller.knownSelections[key] = nil
        } else {
            navigatedSelections[window.id, default: []].insert(key)
        }
    }

    @ObservationIgnored let windowID: UUID
    @ObservationIgnored private(set) weak var window: WindowState?
    /// The project whose tabs the web views show.
    @ObservationIgnored private(set) var key: ProjectKey?
    @ObservationIgnored private var isBound = false
    /// The tab list last applied, to find what changed (nil until the project's tabs are loaded).
    @ObservationIgnored private var syncedTabs: [WebTab]?

    /// Web views of stored tabs, by tab id.
    private(set) var pages: [UUID: WebPage] = [:]
    /// Popups not stored yet, in creation order.
    private(set) var popups: [WebPage] = []
    /// The placeholder tab of ⌘T: at most one per window and project.
    private(set) var hasPlaceholder = false
    /// A selected placeholder or popup; nil when a stored tab is selected.
    private(set) var localSelection: WebStripID?
    /// A navigation's tab that does not exist.
    private(set) var notFoundTabID: String?
    /// The locked tab whose `This tab is locked` label shows.
    private(set) var lockedNoticeTabID: UUID?
    private(set) var urlFieldFocus = URLFieldFocus()
    /// The last `urlFieldFocus.count` an address bar has seen: a request made while no address
    /// bar was shown (⌘T with no tab) is performed by the next address bar when it appears.
    @ObservationIgnored var seenURLFieldFocus = 0
    var findBar = WebFindState()
    let downloads = WebDownloads()
    /// JavaScript dialogs, the first one shown in the window's sheet.
    private(set) var dialogs: [WebPageDialog] = []
    private(set) var pendingMove: PendingMove?

    /// The selected tab id last seen or written for the bound project.
    @ObservationIgnored private var lastSeenSelection: String?
    /// The selection of each project as this controller last knew it; a selection that differs
    /// was set by a navigation (docs/ui.md › Resolving a target).
    @ObservationIgnored fileprivate var knownSelections: [ProjectKey: String] = [:]
    /// Tabs this window opened or adopted that no `webTabs.updated` listed yet.
    @ObservationIgnored private var awaitedTabIDs: Set<UUID> = []
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    @ObservationIgnored private var noticeMonitor: Any?
    @ObservationIgnored private var noticeToken = UUID()
    @ObservationIgnored private(set) var isTornDown = false

    private init(window: WindowState) {
        windowID = window.id
        self.window = window
        let navigated = Self.navigatedSelections.removeValue(forKey: window.id) ?? []
        for (key, state) in window.projectStates where !navigated.contains(key) {
            if let selected = state.selectedWebTabID {
                knownSelections[key] = selected
            }
        }
    }

    private func start() {
        Task { @MainActor [weak self] in
            self?.refresh()
            self?.observe()
        }
    }

    // MARK: Observation

    /// Follows the window's project, device, sheet and selection and the project's tabs.
    private func observe() {
        guard !isTornDown else { return }
        withObservationTracking { [weak self] in
            self?.readInputs()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    private func readInputs() {
        guard let window else { return }
        _ = window.deviceID
        _ = window.sheet
        guard let projectID = window.projectID else { return }
        _ = window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)]?.selectedWebTabID
        if let workspace = window.workspace {
            _ = workspace.webTabs[projectID]
            _ = workspace.state
        }
    }

    private func refresh() {
        guard !isTornDown else { return }
        guard let window, Self.controllers[windowID] === self else {
            teardown()
            return
        }
        observeWindowClose()
        bindIfNeeded()
        if let key, let workspace = window.workspace, workspace.deviceID == key.deviceID,
           let tabs = workspace.webTabs[key.projectID] {
            sync(tabs, connected: workspace.isConnected)
        }
        detectSelectionChange()
        presentNextDialog()
    }

    /// Releases everything of the previous project when the window activates another project or
    /// device.
    func bindIfNeeded() {
        guard let window, !isTornDown else { return }
        let newKey = window.activeProjectKey
        guard !isBound || newKey != key else { return }
        if let key {
            knownSelections[key] = window.projectStates[key]?.selectedWebTabID
        }
        releaseAll()
        key = newKey
        isBound = true
        syncedTabs = nil
        awaitedTabIDs.removeAll()
        lastSeenSelection = newKey.flatMap { window.projectStates[$0]?.selectedWebTabID }
    }

    /// docs/web-tabs.md › Changes from other clients: the strip follows the list; a tab that
    /// disappeared releases its web view and passes the selection on; a changed stored URL that
    /// the web view does not show is a sync load.
    private func sync(_ tabs: [WebTab], connected: Bool) {
        let previous = syncedTabs
        guard previous != tabs else { return }
        syncedTabs = tabs
        pendingMove = nil
        let ids = Set(tabs.map(\.id))
        awaitedTabIDs.subtract(ids)
        guard let previous else {
            validateInitialSelection(tabs)
            return
        }
        if localSelection == nil, let selected = storedSelectionID, previous.contains(where: { $0.id == selected }), !ids.contains(selected) {
            let oldItems = stripItems(tabs: previous).map(\.id)
            let newItems = stripItems(tabs: tabs).map(\.id)
            if let index = oldItems.firstIndex(of: .stored(selected)) {
                select(index < newItems.count ? newItems[index] : newItems.last)
            }
        }
        let released = pages.filter { !ids.contains($0.key) && !awaitedTabIDs.contains($0.key) }
        for (id, page) in released {
            releasePage(page)
            pages[id] = nil
        }
        if connected {
            let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for tab in tabs {
                if let page = pages[tab.id], let old = before[tab.id], old.url != tab.url {
                    page.storedURLChanged(to: tab.url)
                }
            }
        }
        if let notFound = notFoundTabID, let id = UUID(uuidString: notFound), ids.contains(id) {
            notFoundTabID = nil
        }
    }

    /// The first tab list of a binding: a selection that is nil, or names a tab that no longer
    /// exists, selects the first tab; a navigation's tab that does not exist shows the not-found
    /// text.
    // A selection this window wrote, or found when it first showed its Web section, follows the
    // first rule of docs/web-tabs.md › Selection; one set by a navigation (`knownSelections` has no
    // entry for it, `willSelectByNavigation`) follows the second.
    private func validateInitialSelection(_ tabs: [WebTab]) {
        guard let key, localSelection == nil, let window else { return }
        let selected = window.projectStates[key]?.selectedWebTabID
        if let selected {
            if let id = UUID(uuidString: selected), tabs.contains(where: { $0.id == id }) { return }
            if knownSelections[key] != selected {
                notFoundTabID = selected
                return
            }
        }
        if let first = tabs.first {
            writeSelection(first.id)
        }
    }

    /// A selection set from outside (a navigation) replaces a selected placeholder or popup.
    private func detectSelectionChange() {
        guard let key, let window, window.activeProjectKey == key else { return }
        let selected = window.projectStates[key]?.selectedWebTabID
        guard selected != lastSeenSelection else { return }
        lastSeenSelection = selected
        guard let selected else { return }
        localSelection = nil
        if let tabs = syncedTabs, !tabs.contains(where: { $0.id == UUID(uuidString: selected) }) {
            notFoundTabID = selected
        } else {
            notFoundTabID = nil
        }
    }

    // MARK: Strip and selection

    /// The window's tab strip: the stored tabs in order (a dragged tab at its drop position until
    /// the move comes back), each followed by the popups it opened, newest first; popups whose
    /// opener is gone; then the placeholder.
    func stripItems(tabs: [WebTab]) -> [WebStripItem] {
        var ordered = tabs
        if let move = pendingMove, move.tabs == tabs, let from = ordered.firstIndex(where: { $0.id == move.tabID }) {
            let tab = ordered.remove(at: from)
            ordered.insert(tab, at: min(max(move.toIndex, 0), ordered.count))
        }
        var children: [UUID: [WebPage]] = [:]
        for popup in popups {
            if let opener = popup.openerLocalID {
                children[opener, default: []].insert(popup, at: 0)
            }
        }
        var items: [WebStripItem] = []
        var placed = Set<UUID>()
        func appendChildren(of localID: UUID?) {
            guard let localID else { return }
            for child in children[localID] ?? [] where !placed.contains(child.localID) {
                placed.insert(child.localID)
                items.append(.popup(child))
                appendChildren(of: child.localID)
            }
        }
        for tab in ordered {
            items.append(.stored(tab))
            appendChildren(of: pages[tab.id]?.localID)
        }
        for popup in popups where !placed.contains(popup.localID) {
            placed.insert(popup.localID)
            items.append(.popup(popup))
            appendChildren(of: popup.localID)
        }
        if hasPlaceholder {
            items.append(.placeholder)
        }
        return items
    }

    /// docs/web-tabs.md › Selection: a selected placeholder or popup; else the stored tab that
    /// `selectedWebTabID` names; a navigation's missing tab shows the not-found text; nil selects
    /// the first tab.
    func selection(tabs: [WebTab], items: [WebStripItem]) -> WebSelection {
        if let local = localSelection, items.contains(where: { $0.id == local }) {
            return .item(local)
        }
        guard let window, let projectID = window.projectID else { return .none }
        let selected = window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)]?.selectedWebTabID
        if let selected {
            if let id = UUID(uuidString: selected), tabs.contains(where: { $0.id == id }) {
                return .item(.stored(id))
            }
            return selected == notFoundTabID ? .notFound(selected) : .none
        }
        return items.first.map { .item($0.id) } ?? .none
    }

    /// Selects an item of the strip; nil selects nothing.
    func select(_ id: WebStripID?) {
        switch id {
        case .stored(let tabID)?:
            localSelection = nil
            writeSelection(tabID)
        case .popup?, .placeholder?:
            localSelection = id
            writeSelection(nil)
        case nil:
            localSelection = nil
            writeSelection(nil)
        }
    }

    private func writeSelection(_ tabID: UUID?) {
        guard let key, let window, window.deviceID == key.deviceID else { return }
        let value = tabID?.uuidString
        if window.projectStates[key]?.selectedWebTabID != value {
            window.updateViewState(of: key.projectID) { $0.selectedWebTabID = value }
        }
        lastSeenSelection = value
        knownSelections[key] = value
        notFoundTabID = nil
    }

    private var storedSelectionID: UUID? {
        guard let key, let window else { return nil }
        return window.projectStates[key]?.selectedWebTabID.flatMap(UUID.init(uuidString:))
    }

    /// The tabs of the bound project as the workspace has them.
    var currentTabs: [WebTab] {
        guard let key, let workspace = window?.workspace, workspace.deviceID == key.deviceID else { return [] }
        return workspace.webTabs[key.projectID] ?? []
    }

    var currentItems: [WebStripItem] {
        stripItems(tabs: currentTabs)
    }

    var currentSelection: WebSelection {
        let items = currentItems
        return selection(tabs: currentTabs, items: items)
    }

    func page(for id: WebStripID) -> WebPage? {
        switch id {
        case .stored(let tabID): return pages[tabID]
        case .popup(let localID): return popups.first { $0.localID == localID }
        case .placeholder: return nil
        }
    }

    var selectedPage: WebPage? {
        guard case .item(let id) = currentSelection else { return nil }
        return page(for: id)
    }

    /// Creates the web view of a stored tab the first time it is selected and loads its stored URL.
    func ensurePage(for id: WebStripID) {
        bindIfNeeded()
        guard case .stored(let tabID) = id, pages[tabID] == nil, let key, let workspace = window?.workspace,
              workspace.deviceID == key.deviceID, workspace.isConnected,
              let tab = workspace.webTabs[key.projectID]?.first(where: { $0.id == tabID }) else { return }
        let page = WebPage(controller: self, tabID: tabID, isScriptOpened: false)
        pages[tabID] = page
        page.load(storedURL: tab.url)
    }

    // MARK: Remote windows (docs/remote.md › Localhost rewrite)

    /// The device address of a window that shows a remote device; nil for This Mac. It is the
    /// paired record's host: the stored or typed host, or after a Bonjour connection the IPv4
    /// address of its remote endpoint (docs/remote.md › Paired devices).
    var deviceAddress: String? {
        guard let window, let workspace = window.workspace, !workspace.isLocal else { return nil }
        let deviceID = workspace.deviceID
        return window.app?.pairedDevices.first { $0.id.uuidString == deviceID }?.host
            ?? workspace.remoteConnection?.device.host
    }

    /// A stored URL as the web view loads it.
    func loadedForm(of storedURL: String) -> String {
        guard let address = deviceAddress else { return storedURL }
        return LocalhostRewrite.forward(storedURL, deviceAddress: address)
    }

    /// A URL of the web view in stored form, relative to the stored URL of a tab (or, for a popup,
    /// of its opener's tab).
    func storedForm(of loadedURL: String, tabID: UUID?) -> String {
        guard let address = deviceAddress, let reference = referenceURL(tabID: tabID) else { return loadedURL }
        return LocalhostRewrite.reverse(loadedURL, storedURL: reference, deviceAddress: address)
    }

    private func referenceURL(tabID: UUID?) -> String? {
        guard let tabID else { return nil }
        return currentTabs.first { $0.id == tabID }?.url
    }

    /// The stored tab a popup descends from, through its openers.
    private func storedAncestor(of page: WebPage) -> UUID? {
        var current: WebPage? = page
        var seen = Set<UUID>()
        while let candidate = current, !seen.contains(candidate.localID) {
            seen.insert(candidate.localID)
            if let tabID = candidate.tabID { return tabID }
            guard let opener = candidate.openerLocalID else { return nil }
            current = pages.values.first { $0.localID == opener } ?? popups.first { $0.localID == opener }
        }
        return nil
    }

    // MARK: Storing what the page shows (docs/web-tabs.md › Storing what the page shows)

    /// After 1 second without change: the changed `url` and `title` in one `webTabs.update`; a
    /// URL or title the page reached during a sync load is never written; a failure is written to
    /// the log and ignored.
    func storePage(_ page: WebPage) {
        guard let key, let tabID = page.tabID, let workspace = window?.workspace, workspace.deviceID == key.deviceID,
              workspace.isConnected, let tab = workspace.webTabs[key.projectID]?.first(where: { $0.id == tabID }) else { return }
        var url: String?
        if let current = page.webView.url, let scheme = current.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let stored = storedForm(of: current.absoluteString, tabID: tabID)
            if stored != tab.url, !page.syncReachedURLs.contains(stored) {
                url = stored
            }
        }
        var title: String?
        let cleaned = Self.cleanedTitle(page.webView.title ?? "")
        if !cleaned.isEmpty, cleaned != tab.title, String(cleaned.prefix(WebTabsController.titleLimit)) != tab.title,
           !page.syncReachedTitles.contains(cleaned) {
            title = cleaned
        }
        guard url != nil || title != nil else { return }
        if let url {
            page.lastWrittenURL = url
        }
        let params = WebTabsUpdate.Params(projectID: key.projectID, tabID: tabID, url: url, title: title)
        Task { [weak self] in
            do {
                _ = try await workspace.call(WebTabsUpdate.self, params)
            } catch {
                self?.log("webTabs.update of tab \(tabID.uuidString) in \(key.projectID) failed: \(errorMessage(error))")
            }
        }
    }

    /// The engine's title limit (docs/data-model.md › Web tab).
    static let titleLimit = 500

    /// A page title trimmed, with its line breaks as spaces.
    static func cleanedTitle(_ title: String) -> String {
        var result = ""
        for character in title.trimmingCharacters(in: .whitespacesAndNewlines) {
            result.append(character.isNewline ? " " : character)
        }
        return result
    }

    // MARK: Tab actions (docs/web-tabs.md › Context menu, › Closing tabs, › New tab)

    /// ⌘T, the `+` button and the empty state's `New Tab`: the placeholder at the end of the strip,
    /// selected, its URL field focused with an empty text.
    func newTab() {
        bindIfNeeded()
        guard key != nil else { return }
        hasPlaceholder = true
        select(.placeholder)
        urlFieldFocus = URLFieldFocus(count: urlFieldFocus.count + 1, clearsText: true)
    }

    /// ⌥⌘L: focuses the URL field and selects its text; with no tab at all it first opens the
    /// placeholder.
    func openLocation() {
        if currentItems.isEmpty {
            newTab()
        } else {
            urlFieldFocus = URLFieldFocus(count: urlFieldFocus.count + 1, clearsText: false)
        }
    }

    /// Return in the URL field with an address: the placeholder stores it first; a tab loads it.
    func load(_ url: URL, in id: WebStripID) {
        switch id {
        case .placeholder:
            openFromPlaceholder(url)
        case .stored(let tabID):
            ensurePage(for: id)
            pages[tabID]?.load(storedURL: url.absoluteString)
        case .popup:
            page(for: id)?.load(storedURL: url.absoluteString)
        }
    }

    /// docs/web-tabs.md › New tab, step 3: `webTabs.open` at the placeholder's position; the stored
    /// tab replaces the placeholder and is selected.
    private func openFromPlaceholder(_ url: URL) {
        guard let key, let workspace = window?.workspace else { return }
        let params = WebTabsOpen.Params(projectID: key.projectID, url: url.absoluteString, index: currentTabs.count)
        Task { [weak self] in
            do {
                let tab = try await workspace.call(WebTabsOpen.self, params)
                guard let self, self.key == key else { return }
                self.hasPlaceholder = false
                if self.syncedTabs?.contains(where: { $0.id == tab.id }) != true {
                    self.awaitedTabIDs.insert(tab.id)
                }
                self.select(.stored(tab.id))
            } catch {
                // DOC-GAP: docs/web-tabs.md › New tab does not say how a failed `webTabs.open` of the
                // placeholder shows; it is the failure alert of docs/ui.md › Principles, named
                // after the placeholder's label.
                self?.alert("New Tab", error)
            }
        }
    }

    /// The close button, ⌘W and the context menu's Close of a stored tab.
    func close(_ tab: WebTab, itemTitle: String) {
        guard let key, let workspace = window?.workspace else { return }
        Task { [weak self] in
            do {
                _ = try await workspace.call(WebTabsClose.self, .init(projectID: key.projectID, tabID: tab.id))
            } catch {
                self?.alert(itemTitle, error)
            }
        }
    }

    /// Close Other Tabs: every other unlocked tab, one `webTabs.close` per tab, left to right.
    func closeOtherTabs(than kept: WebTab) {
        guard let key, let workspace = window?.workspace else { return }
        let closing = currentTabs.filter { $0.id != kept.id && !$0.locked }
        Task { [weak self] in
            var failure: Error?
            for tab in closing {
                do {
                    _ = try await workspace.call(WebTabsClose.self, .init(projectID: key.projectID, tabID: tab.id))
                } catch {
                    failure = failure ?? error
                }
            }
            if let failure {
                self?.alert("Close Other Tabs", failure)
            }
        }
    }

    /// Lock or Unlock of the context menu.
    func setLocked(_ tab: WebTab, _ locked: Bool) {
        guard let key, let workspace = window?.workspace else { return }
        Task { [weak self] in
            do {
                _ = try await workspace.call(WebTabsUpdate.self, .init(projectID: key.projectID, tabID: tab.id, locked: locked))
            } catch {
                self?.alert(locked ? "Lock" : "Unlock", error)
            }
        }
    }

    /// Duplicate: the tab's stored URL and title, unlocked, right after it; selected here.
    func duplicate(_ tab: WebTab) {
        guard let key, let workspace = window?.workspace else { return }
        let index = (currentTabs.firstIndex { $0.id == tab.id } ?? currentTabs.count - 1) + 1
        let params = WebTabsOpen.Params(projectID: key.projectID, url: tab.url, title: tab.title, locked: false, index: index)
        Task { [weak self] in
            do {
                let created = try await workspace.call(WebTabsOpen.self, params)
                guard let self, self.key == key else { return }
                if self.syncedTabs?.contains(where: { $0.id == created.id }) != true {
                    self.awaitedTabIDs.insert(created.id)
                }
                self.select(.stored(created.id))
            } catch {
                self?.alert("Duplicate", error)
            }
        }
    }

    /// Dropping a dragged tab: `webTabs.move` with the drop position.
    func move(_ tabID: UUID, toIndex: Int) {
        guard let key, let workspace = window?.workspace else { return }
        let tabs = currentTabs
        guard let from = tabs.firstIndex(where: { $0.id == tabID }), from != toIndex else { return }
        pendingMove = PendingMove(tabs: tabs, tabID: tabID, toIndex: toIndex)
        Task { [weak self] in
            do {
                _ = try await workspace.call(WebTabsMove.self, .init(projectID: key.projectID, tabID: tabID, toIndex: toIndex))
            } catch {
                // DOC-GAP: docs/web-tabs.md › Tab strip does not say how a failed move shows; the
                // tab goes back to its place and the failure is logged.
                self?.pendingMove = nil
                self?.log("webTabs.move of tab \(tabID.uuidString) in \(key.projectID) failed: \(errorMessage(error))")
            }
        }
    }

    /// Closes the placeholder or a popup: it only disappears; a selected one passes the selection
    /// to the item that takes its place, else the new last item.
    func closeLocal(_ id: WebStripID) {
        let items = currentItems
        let wasSelected = currentSelection == .item(id)
        let index = items.firstIndex { $0.id == id }
        switch id {
        case .placeholder:
            hasPlaceholder = false
        case .popup(let localID):
            guard let popup = popups.first(where: { $0.localID == localID }) else { return }
            releasePage(popup)
            popups.removeAll { $0 === popup }
        case .stored:
            return
        }
        guard wasSelected else { return }
        let remaining = currentItems.map(\.id)
        if let index, index < remaining.count {
            select(remaining[index])
        } else {
            select(remaining.last)
        }
    }

    /// ⌘W on a locked tab: the beep, and `This tab is locked` below the tab for 2 seconds or until
    /// the next click.
    func refuseClose(of tabID: UUID) {
        NSSound.beep()
        hideLockedNotice()
        let token = UUID()
        noticeToken = token
        lockedNoticeTabID = tabID
        noticeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.hideLockedNotice() }
            return event
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.noticeToken == token else { return }
            self.hideLockedNotice()
        }
    }

    private func hideLockedNotice() {
        noticeToken = UUID()
        lockedNoticeTabID = nil
        if let noticeMonitor {
            NSEvent.removeMonitor(noticeMonitor)
            self.noticeMonitor = nil
        }
    }

    // MARK: Popups (docs/web-tabs.md › Popups)

    /// `target="_blank"` or `window.open` during a user click: a popup tab right after its opener,
    /// selected in this window, with the web view WebKit asked for.
    func openPopup(from opener: WebPage, configuration: WKWebViewConfiguration) -> WebPage? {
        guard key != nil, !isTornDown else { return nil }
        let popup = WebPage(controller: self, configuration: configuration, tabID: nil, isScriptOpened: true)
        popup.openerLocalID = opener.localID
        popups.append(popup)
        select(.popup(popup.localID))
        return popup
    }

    /// A popup that reaches an `http` or `https` URL is stored with `webTabs.open` right after its
    /// opener's tab; its web view stays.
    func pageDidChange(_ page: WebPage) {
        guard page.tabID == nil, !page.isBeingStored, popups.contains(where: { $0 === page }),
              let url = page.webView.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let key, let workspace = window?.workspace, workspace.deviceID == key.deviceID, workspace.isConnected else { return }
        let ancestor = storedAncestor(of: page)
        // DOC-GAP: docs/remote.md › Reverse rewrite is defined for a tab's stored URL; a popup has
        // none yet, so its opener's stored tab is the reference.
        let stored = storedForm(of: url.absoluteString, tabID: ancestor)
        let index = ancestor.flatMap { id in currentTabs.firstIndex { $0.id == id } }.map { $0 + 1 }
        let title = Self.cleanedTitle(page.pageTitle)
        let params = WebTabsOpen.Params(projectID: key.projectID, url: stored, title: title.isEmpty ? nil : title, index: index)
        page.isBeingStored = true
        Task { [weak self] in
            defer { page.isBeingStored = false }
            do {
                let tab = try await workspace.call(WebTabsOpen.self, params)
                guard let self, self.key == key, self.popups.contains(where: { $0 === page }) else { return }
                page.tabID = tab.id
                page.lastWrittenURL = stored
                self.popups.removeAll { $0 === page }
                self.pages[tab.id] = page
                if self.syncedTabs?.contains(where: { $0.id == tab.id }) != true {
                    self.awaitedTabIDs.insert(tab.id)
                }
                if self.localSelection == .popup(page.localID) {
                    self.select(.stored(tab.id))
                }
            } catch {
                self?.log("webTabs.open of a popup in \(key.projectID) failed: \(errorMessage(error))")
            }
        }
    }

    /// `window.close()` of a page opened by a script: a popup not stored disappears; a stored tab
    /// closes unless it is locked.
    func pageDidClose(_ page: WebPage) {
        if page.tabID == nil {
            closeLocal(.popup(page.localID))
        } else if page.isScriptOpened, let tabID = page.tabID, let tab = currentTabs.first(where: { $0.id == tabID }), !tab.locked {
            close(tab, itemTitle: "Close Tab")
        }
    }

    // MARK: Page dialogs (docs/web-tabs.md › Page permissions and dialogs)

    /// Queues an `alert`, `confirm` or `prompt`; it shows as a sheet on the window once the window
    /// shows no other sheet.
    func enqueueDialog(_ kind: WebPageDialog.Kind, message: String, page: WebPage, complete: @escaping (WebPageDialog.Answer) -> Void) {
        let shown = page.webView.url.map { storedForm(of: $0.absoluteString, tabID: page.tabID ?? storedAncestor(of: page)) }
        let host = shown.flatMap { URL(string: $0)?.host } ?? ""
        let sheetTabID = page.tabID?.uuidString ?? page.localID.uuidString
        dialogs.append(WebPageDialog(kind: kind, title: host, message: message, pageID: page.localID, sheetTabID: sheetTabID,
                                     complete: complete))
        presentNextDialog()
    }

    /// The dialog of the window's sheet.
    func dialog(forSheetTabID tabID: String) -> WebPageDialog? {
        guard let first = dialogs.first, first.sheetTabID == tabID else { return nil }
        return first
    }

    /// OK or Cancel of the dialog sheet.
    func answer(_ dialog: WebPageDialog, _ answer: WebPageDialog.Answer) {
        guard let index = dialogs.firstIndex(where: { $0.id == dialog.id }) else { return }
        let isShown = index == 0 && window?.sheet == .webPageDialog(tabID: dialog.sheetTabID)
        dialogs.remove(at: index)
        dialog.complete(answer)
        if isShown {
            window?.sheet = nil
        }
    }

    private func presentNextDialog() {
        guard let window, window.sheet == nil, let first = dialogs.first else { return }
        window.sheet = .webPageDialog(tabID: first.sheetTabID)
    }

    // MARK: Find bar

    /// Edit ▸ Find in a page: shows the find bar, or finds the next or previous match.
    func findAction(_ action: NSTextFinder.Action, in page: WebPage) {
        switch action {
        case .showFindInterface:
            findBar.isVisible = true
            findBar.focusRequest += 1
        case .nextMatch:
            find(backwards: false)
        case .previousMatch:
            find(backwards: true)
        default:
            break
        }
    }

    /// Searches the selected page with `WKWebView.find`, case-insensitive and wrapping.
    func find(backwards: Bool) {
        guard let page = selectedPage, !findBar.text.isEmpty else {
            findBar.notFound = false
            return
        }
        let configuration = WKFindConfiguration()
        configuration.caseSensitive = false
        configuration.wraps = true
        configuration.backwards = backwards
        page.webView.find(findBar.text, configuration: configuration) { [weak self] result in
            self?.findBar.notFound = !result.matchFound
        }
    }

    /// Done and Escape of the find bar: the bar closes and the page gets the focus.
    func closeFindBar() {
        findBar.isVisible = false
        findBar.notFound = false
        focusPage()
    }

    /// Moves the keyboard focus to the selected page.
    func focusPage() {
        guard let webView = selectedPage?.webView, let nsWindow = webView.window else { return }
        nsWindow.makeFirstResponder(webView)
    }

    // MARK: SectionCommandHandler (docs/ui.md › Menus and keyboard shortcuts)

    /// The window shows this controller's project in its Web section.
    private var isShown: Bool {
        guard let window, let key, !isTornDown else { return false }
        return window.section == .web && window.activeProjectKey == key && window.sheet == nil
            && (window.workspace?.isConnected ?? false)
    }

    var canCloseTab: Bool {
        guard isShown, case .item = currentSelection else { return false }
        return true
    }

    /// ⌘W: closes the selected tab; a locked tab is refused with the beep and its label.
    func closeTab() {
        guard isShown, case .item(let id) = currentSelection else { return }
        switch id {
        case .stored(let tabID):
            guard let tab = currentTabs.first(where: { $0.id == tabID }) else { return }
            if tab.locked {
                refuseClose(of: tabID)
            } else {
                close(tab, itemTitle: "Close Tab")
            }
        case .popup, .placeholder:
            closeLocal(id)
        }
    }

    var canGoBack: Bool {
        isShown && (selectedPage?.canGoBack ?? false)
    }

    func goBack() {
        guard isShown else { return }
        selectedPage?.webView.goBack()
    }

    var canGoForward: Bool {
        isShown && (selectedPage?.canGoForward ?? false)
    }

    func goForward() {
        guard isShown else { return }
        selectedPage?.webView.goForward()
    }

    /// Reload Page: the Web section has a selected stored tab.
    var canReloadPage: Bool {
        guard isShown, case .item(.stored) = currentSelection else { return false }
        return true
    }

    func reloadPage() {
        guard isShown, case .item(.stored(let tabID)) = currentSelection else { return }
        pages[tabID]?.webView.reload()
    }

    var canShowAdjacentTab: Bool {
        isShown && currentItems.count >= 2
    }

    func showPreviousTab() {
        showAdjacentTab(-1)
    }

    func showNextTab() {
        showAdjacentTab(1)
    }

    /// ⇧⌘[ and ⇧⌘]: the tab on the left or right, wrapping; the placeholder is the last tab.
    private func showAdjacentTab(_ offset: Int) {
        guard isShown else { return }
        let items = currentItems.map(\.id)
        guard items.count >= 2 else { return }
        var index = 0
        if case .item(let id) = currentSelection, let current = items.firstIndex(of: id) {
            index = (current + offset + items.count) % items.count
        }
        select(items[index])
    }

    // MARK: Lifetime

    private func releasePage(_ page: WebPage) {
        let pending = dialogs.filter { $0.pageID == page.localID }
        for dialog in pending {
            answer(dialog, .dismissed)
        }
        page.close()
    }

    /// Releases the web views, the popups and the placeholder of the bound project.
    private func releaseAll() {
        for page in pages.values {
            releasePage(page)
        }
        pages.removeAll()
        for popup in popups {
            releasePage(popup)
        }
        popups.removeAll()
        hasPlaceholder = false
        localSelection = nil
        notFoundTabID = nil
        pendingMove = nil
        findBar = WebFindState()
        hideLockedNotice()
    }

    private func observeWindowClose() {
        guard closeObserver == nil, let window, let nsWindow = window.app?.windowRegistry.window(forMain: window.id) else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nsWindow,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardown() }
        }
    }

    /// The window closed: its web views are released and its downloads cancelled.
    private func teardown() {
        guard !isTornDown else { return }
        releaseAll()
        downloads.cancelAll()
        isTornDown = true
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if let window, window.sectionCommands === self {
            window.sectionCommands = nil
        }
        if Self.controllers[windowID] === self {
            Self.controllers[windowID] = nil
        }
    }

    // MARK: Errors

    private func alert(_ itemTitle: String, _ error: Error) {
        window?.alert = .failure(itemTitle, error)
    }

    // DOC-GAP: docs/web-tabs.md › Storing what the page shows writes failures "to the window's
    // log"; windows have no log of their own, so they go to This Mac's engine.log as `ui`.
    private func log(_ message: String) {
        window?.app?.engine.log.warn(.ui, message)
    }
}
