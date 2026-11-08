// OWNER: ui-shell — AppModel: workspaces, windows, devices, the server status service, routing of
// engine events to windows (docs/ui.md › AppModel, › Choosing the window; docs/architecture.md ›
// UI state architecture).
import AppKit
import Foundation
import HephaestusCore
import Observation
import SwiftUI
import UpdaterCore

/// The app's UI state: one per process (docs/ui.md › AppModel). It owns the local `Engine`, the
/// local-only services, the Updater (through `UpdateController`) and the `MCPDebugUI`
/// implementation. `AppModel.launch()` creates it at launch.
@MainActor @Observable
public final class AppModel {
    /// The model of this process, set by `launch()`.
    static var shared: AppModel?

    // MARK: Launch values

    @ObservationIgnored let environment: LaunchEnvironment
    @ObservationIgnored let engine: Engine
    @ObservationIgnored let appVersion: AppVersion
    /// False when the process neither restores nor saves window state: `HEPHAESTUS_DATA_DIR` or
    /// `HEPHAESTUS_WINDOW_SCREEN` is set, or this launch reopens the windows of a restart.
    @ObservationIgnored let restoresWindows: Bool
    /// False when the process neither reads nor writes window state (docs/ui.md › Persistence).
    @ObservationIgnored let persistsWindowState: Bool

    // MARK: docs/ui.md › AppModel

    /// This Mac's device id (`device.yml`).
    let localDeviceID: String
    /// The workspace of the in-process engine; created at launch, never closed.
    let localWorkspace: DeviceWorkspace
    /// Open workspaces by device id, This Mac's included.
    private(set) var workspaces: [String: DeviceWorkspace]
    /// The state of every open main window, by window id.
    private(set) var windows: [UUID: WindowState] = [:]
    /// Main window ids, most recently key first.
    private(set) var keyWindowOrder: [UUID] = []
    /// The open chat windows.
    private(set) var chatWindows: Set<ChatWindowValue> = []
    /// Last active project per device, persisted in `UserDefaults`.
    private(set) var lastProjectIDByDevice: [String: String]
    /// Minimized questions, symbol, color, sound, shortcut, font and animation cards: chat id → id
    /// of the minimized question set, symbol request, color request, sound request, shortcut
    /// request, font request or animation request, persisted in `UserDefaults` (docs/chats.md ›
    /// Pinned questions card, › Pinned symbol card, › Pinned color card, › Pinned sound card, ›
    /// Pinned shortcut card, › Pinned font card, › Pinned animation card).
    private(set) var minimizedQuestionSets: [String: String]
    /// The last status received from the Updater.
    var updaterStatus = UpdaterStatus.initial

    // MARK: Local-only services (docs/architecture.md › Local-only services)

    /// The MCP server's state, from the server status service.
    private(set) var mcpState = MCPServerState.stopped
    /// The sync server's state and open sessions, from the server status service.
    private(set) var syncStatus = SyncServerStatus()
    /// The paired devices, in the order of `remotes.yml`.
    private(set) var pairedDevices: [RemoteDevice] = []
    /// The devices Bonjour currently sees, This Mac excluded.
    private(set) var discoveredDevices: [DiscoveredDevice] = []

    // MARK: Windows and controllers

    /// The tab the Settings window shows.
    var settingsTab = SettingsTab.general
    /// PNG data of the Feedback sheets' screenshots, by preview id, while their sheet is open.
    var feedbackPreviews: [UUID: Data] = [:]
    /// True once a SIGTERM or SIGINT ended the open sheets: the SwiftUI sheets whose state belongs
    /// to a view stay closed.
    var sheetsEnded = false
    @ObservationIgnored let windowRegistry = WindowRegistry()
    @ObservationIgnored let updateController: UpdateController
    @ObservationIgnored let feedbackController: FeedbackController
    /// The macOS notifications of chats (docs/ui.md › Status bar).
    @ObservationIgnored let chatNotifier: ChatNotifier
    @ObservationIgnored var debugUI: AppDebugUI?
    /// Savers run after the quit checks, at most 5 seconds: the changed ticket description editors
    /// (docs/ui.md › Unsaved changes and quitting). Their owners add and remove them.
    @ObservationIgnored var quitSavers: [UUID: @MainActor () async throws -> Void] = [:]
    /// True when the termination skips the confirmations: SIGTERM, SIGINT, a restart for an update.
    @ObservationIgnored var skipsQuitConfirmations = false
    @ObservationIgnored var isShuttingDown = false
    /// True while the quit checks of a Quit run (`applicationShouldTerminate` answered
    /// `terminateLater`).
    @ObservationIgnored var quitChecksPending = false
    /// True once `app.quitting` was posted for this termination.
    @ObservationIgnored var appQuittingPosted = false
    /// Opens a window of a scene: the `openWindow` action of the SwiftUI environment, kept by
    /// `captureWindowActions` or `captureCommandsOpenWindow`.
    @ObservationIgnored var windowOpener: (@MainActor (SceneWindow) -> Void)?
    @ObservationIgnored private var openSettingsAction: OpenSettingsAction?
    @ObservationIgnored private var pendingMainWindows: [UUID: WindowState] = [:]
    @ObservationIgnored var restartMainWindowStates: [String] = []
    /// True when this launch reopens the windows of a restart and they hold no main window: the
    /// main window SwiftUI opens at launch closes at once.
    @ObservationIgnored private var suppressesLaunchWindow = false
    /// True when this launch reopens the windows of a restart: the app opens exactly those.
    @ObservationIgnored private let isRestartLaunch: Bool
    /// True once the restart windows were opened.
    @ObservationIgnored private var restartWindowsOpened = false
    /// True once the launch has its windows: the first main window root appeared, or the launch
    /// check ran (docs/ui.md › Windows).
    @ObservationIgnored private(set) var launchWindowsSettled = false
    @ObservationIgnored var restartChatWindows: [ChatWindowValue] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var waitingChatKeys: Set<String> = []

    /// `UserDefaults` keys (docs/ui.md › Persistence).
    static let lastProjectDefaultsKey = "lastProjectIDByDevice"
    static let windowsAtRestartDefaultsKey = "windowsAtRestart"
    static let minimizedQuestionSetsDefaultsKey = "minimizedQuestionSets"

    init(environment: LaunchEnvironment, engine: Engine, appVersion: AppVersion, connection: LocalEngineConnection,
         restartWindows: [RestartWindowRecord]?) {
        self.environment = environment
        self.engine = engine
        self.appVersion = appVersion
        persistsWindowState = environment.restoresWindowState
        restoresWindows = environment.restoresWindowState && restartWindows == nil
        localDeviceID = engine.deviceID
        let local = DeviceWorkspace(deviceID: engine.deviceID, connection: connection, isLocal: true)
        localWorkspace = local
        workspaces = [engine.deviceID: local]
        if persistsWindowState {
            lastProjectIDByDevice = UserDefaults.standard.dictionary(forKey: Self.lastProjectDefaultsKey) as? [String: String] ?? [:]
            minimizedQuestionSets = UserDefaults.standard.dictionary(forKey: Self.minimizedQuestionSetsDefaultsKey) as? [String: String]
                ?? [:]
        } else {
            lastProjectIDByDevice = [:]
            minimizedQuestionSets = [:]
        }
        for record in restartWindows ?? [] {
            if let json = record.main {
                restartMainWindowStates.append(json)
            } else if let chat = record.chat {
                restartChatWindows.append(chat)
            }
        }
        suppressesLaunchWindow = restartWindows != nil && restartMainWindowStates.isEmpty
        isRestartLaunch = restartWindows != nil
        updateController = UpdateController(environment: environment, appVersion: appVersion)
        feedbackController = FeedbackController()
        chatNotifier = ChatNotifier(enabled: environment.dataDirectory == nil)
        pairedDevices = engine.pairedDevices.devices
        updateController.app = self
        feedbackController.app = self
        chatNotifier.app = self
        observe(local)
        observeLocalServices()
        observeKeyWindows()
    }

    // MARK: Devices

    /// This Mac first, then the paired devices in the order of `remotes.yml`. A paired device is
    /// online when Bonjour sees it or when its connection is connected (docs/remote.md › Online
    /// status).
    var devices: [DeviceEntry] {
        let seen = Set(discoveredDevices.map(\.id))
        let local = DeviceEntry(id: localDeviceID, name: localWorkspace.deviceName, isLocal: true, online: true)
        return [local] + pairedDevices.map { device in
            let id = device.id.uuidString
            let connected = workspaces[id]?.state == .connected
            return DeviceEntry(id: id, name: workspaces[id]?.deviceInfo?.name ?? device.name, isLocal: false,
                               online: seen.contains(id) || connected)
        }
    }

    /// The name of a device: `This Mac` for this device in menus is the caller's choice.
    func deviceName(_ deviceID: String) -> String {
        if let workspace = workspaces[deviceID] { return workspace.deviceName }
        return pairedDevices.first { $0.id.uuidString == deviceID }?.name ?? deviceID
    }

    // MARK: Workspaces

    /// The open workspace of a device, or a new one on a `RemoteEngineConnection` to the paired
    /// device (docs/remote.md › One connection per device); nil for a device that is not paired.
    func workspace(for deviceID: String) -> DeviceWorkspace? {
        if let workspace = workspaces[deviceID] { return workspace }
        guard let device = pairedDevices.first(where: { $0.id.uuidString == deviceID }) else { return nil }
        let connection = RemoteEngineConnection(device: device, local: localDeviceInfo, pairedDevices: engine.pairedDevices,
                                                browser: engine.deviceBrowser, log: engine.log)
        let workspace = DeviceWorkspace(deviceID: deviceID, connection: connection, remote: connection, isLocal: false)
        workspaces[deviceID] = workspace
        observe(workspace)
        return workspace
    }

    /// This Mac's DeviceInfo, sent in `hello`.
    var localDeviceInfo: DeviceInfo {
        localWorkspace.deviceInfo ?? DeviceInfo(id: localDeviceID, name: localWorkspace.deviceName,
                                                appVersion: appVersion.version, build: appVersion.build)
    }

    /// A successful Add Device attempt: its connection becomes the device's connection, and a
    /// connection the app already had to that device is closed with 1000 (docs/remote.md ›
    /// Adding a device). The windows showing the device go on with the new workspace.
    func adopt(_ connection: RemoteEngineConnection) {
        let deviceID = connection.device.id.uuidString
        workspaces[deviceID]?.close()
        if !pairedDevices.contains(where: { $0.id == connection.device.id }) {
            pairedDevices.append(connection.device)
        }
        let workspace = DeviceWorkspace(deviceID: deviceID, connection: connection, remote: connection, isLocal: false)
        workspaces[deviceID] = workspace
        observe(workspace)
    }

    /// Closes a remote workspace and its connection as soon as no main window and no chat window
    /// shows its device.
    func releaseWorkspaceIfUnused(_ deviceID: String) {
        guard deviceID != localDeviceID, let workspace = workspaces[deviceID] else { return }
        let shown = windows.values.contains { $0.deviceID == deviceID } || chatWindows.contains { $0.deviceID == deviceID }
        guard !shown else { return }
        workspace.close()
        workspaces[deviceID] = nil
    }

    /// Stores the last active project of a device (docs/projects.md › Project selector).
    func rememberLastProject(_ projectID: String, deviceID: String) {
        guard lastProjectIDByDevice[deviceID] != projectID else { return }
        lastProjectIDByDevice[deviceID] = projectID
        if persistsWindowState {
            UserDefaults.standard.set(lastProjectIDByDevice, forKey: Self.lastProjectDefaultsKey)
        }
    }

    /// Whether the questions card, the symbol card, the color card, the sound card, the shortcut
    /// card or the font card of a chat is minimized for this question set, symbol request, color
    /// request, sound request, shortcut request or font request.
    func isQuestionsCardMinimized(chatID: String, setID: UUID) -> Bool {
        minimizedQuestionSets[chatID] == setID.uuidString
    }

    /// The minimize button and the collapsed bar of the questions, symbol, color, sound, shortcut and
    /// font cards.
    func setQuestionsCardMinimized(_ minimized: Bool, chatID: String, setID: UUID) {
        updateMinimizedQuestionSet(chatID, minimized ? setID.uuidString : nil)
    }

    /// Removes the entry of a chat whose card shows another question set, symbol request, color
    /// request, sound request, shortcut request or font request, or none.
    func forgetMinimizedQuestionSet(chatID: String, shownSetID: UUID?) {
        guard let stored = minimizedQuestionSets[chatID], stored != shownSetID?.uuidString else { return }
        updateMinimizedQuestionSet(chatID, nil)
    }

    private func updateMinimizedQuestionSet(_ chatID: String, _ setID: String?) {
        guard minimizedQuestionSets[chatID] != setID else { return }
        minimizedQuestionSets[chatID] = setID
        if persistsWindowState {
            UserDefaults.standard.set(minimizedQuestionSets, forKey: Self.minimizedQuestionSetsDefaultsKey)
        }
    }

    // MARK: Main windows

    /// Called when a main window's root appears for the first time: the launch has its first
    /// window. The window takes its state and registers it, or gets nil and closes at once: the
    /// main window SwiftUI opens at launch when the windows of a restart hold no main window. The
    /// remaining windows of a restart open only after that, so the launch window takes the first
    /// saved main window (docs/ui.md › Windows: the app opens exactly those windows).
    func mainWindowRootAppeared(requestID: UUID?, restoredJSON: String?) -> WindowState? {
        launchWindowsSettled = true
        var state: WindowState?
        if requestID != nil || !takeSuppressedLaunchWindow() {
            let newState = makeMainWindowState(requestID: requestID, restoredJSON: restoredJSON)
            registerMainWindow(newState)
            state = newState
        }
        openRestartWindows()
        return state
    }

    /// The state of a main window being created: a requested window, a window of a restart, a
    /// window restored by macOS, or a new window on This Mac with its default project.
    private func makeMainWindowState(requestID: UUID?, restoredJSON: String?) -> WindowState {
        if let requestID, let state = pendingMainWindows.removeValue(forKey: requestID) {
            return state
        }
        if !restartMainWindowStates.isEmpty, let state = WindowState.restored(fromJSON: restartMainWindowStates.removeFirst()) {
            return validated(state)
        }
        if restoresWindows, let restoredJSON, let state = WindowState.restored(fromJSON: restoredJSON), windows[state.id] == nil {
            return validated(state)
        }
        let state = WindowState(deviceID: localDeviceID)
        state.needsDefaultProject = true
        return state
    }

    /// The launch check of docs/ui.md › Windows, once the app has finished launching: when no
    /// window of the scenes is open and none was restored, the app opens the main window that
    /// SwiftUI should have opened. A restart for an update opens exactly its saved windows.
    func ensureLaunchWindow() {
        defer { launchWindowsSettled = true }
        guard !launchWindowsSettled, !isRestartLaunch else { return }
        let hasSceneWindow = NSApp.windows.contains { window in
            window.isVisible && window.sheetParent == nil && !(window is NSPanel) && window.styleMask.contains(.titled)
        }
        guard !hasSceneWindow else { return }
        engine.log.warn(.ui, "no window was open after launch; opening a main window")
        openNewMainWindow()
    }

    /// True once, for the main window SwiftUI opens at launch, when the windows of a restart hold
    /// no main window (docs/ui.md › Windows: the app opens exactly those windows).
    private func takeSuppressedLaunchWindow() -> Bool {
        guard suppressesLaunchWindow else { return false }
        suppressesLaunchWindow = false
        return true
    }

    /// A restored window whose device is no longer paired shows This Mac.
    private func validated(_ state: WindowState) -> WindowState {
        if state.deviceID != localDeviceID, !pairedDevices.contains(where: { $0.id.uuidString == state.deviceID }) {
            state.deviceID = localDeviceID
            state.projectID = nil
        }
        state.needsDefaultProject = state.projectID == nil
        return state
    }

    func registerMainWindow(_ state: WindowState) {
        state.app = self
        windows[state.id] = state
        keyWindowOrder.removeAll { $0 == state.id }
        keyWindowOrder.insert(state.id, at: 0)
        if workspace(for: state.deviceID) == nil {
            state.switchDevice(to: localDeviceID)
        }
        if let workspace = workspaces[state.deviceID] {
            state.reconcileProject(with: workspace)
        }
    }

    func unregisterMainWindow(_ id: UUID) {
        guard let state = windows.removeValue(forKey: id) else { return }
        keyWindowOrder.removeAll { $0 == id }
        releaseWorkspaceIfUnused(state.deviceID)
    }

    /// A window chose another device: its workspace opens, the previous one closes when unused.
    func windowDidChangeDevice(_ state: WindowState, from oldDeviceID: String) {
        if workspace(for: state.deviceID) == nil {
            state.deviceID = localDeviceID
        }
        releaseWorkspaceIfUnused(oldDeviceID)
    }

    /// The main windows, most recently key first.
    var mainWindowsByKeyOrder: [WindowState] {
        keyWindowOrder.compactMap { windows[$0] }
    }

    /// File ▸ New Window (⌘N): the new window copies the device, `projectID` and section of the
    /// most recently key main window (docs/projects.md › Project selector).
    func openNewMainWindow() {
        let state: WindowState
        if let model = mainWindowsByKeyOrder.first {
            state = WindowState(deviceID: model.deviceID)
            state.section = model.section
            if let projectID = model.projectID {
                state.projectID = projectID
                state.lastProjectByDevice[model.deviceID] = projectID
            } else {
                state.needsDefaultProject = true
            }
        } else {
            state = WindowState(deviceID: localDeviceID)
            state.needsDefaultProject = true
        }
        openMainWindow(state)
    }

    /// Opens a main window with a prepared state.
    func openMainWindow(_ state: WindowState) {
        let requestID = UUID()
        pendingMainWindows[requestID] = state
        windowOpener?(.main(requestID: requestID))
    }

    /// Closes a main window after the unsaved changes check of its editors (File ▸ Close Window).
    func closeMainWindow(_ state: WindowState) async {
        guard await UnsavedChangesPrompt.confirm(state.unsavedEditors(), in: state) else { return }
        windowRegistry.window(forMain: state.id)?.close()
    }

    // MARK: Other windows

    func registerChatWindow(_ value: ChatWindowValue) {
        chatWindows.insert(value)
        _ = workspace(for: value.deviceID)
    }

    func unregisterChatWindow(_ value: ChatWindowValue) {
        guard chatWindows.remove(value) != nil else { return }
        releaseWorkspaceIfUnused(value.deviceID)
    }

    /// Opens a chat in its own window, or brings its window to front (docs/ui.md › Windows).
    func openChatWindow(_ value: ChatWindowValue) {
        windowOpener?(.chat(value))
    }

    /// Closes the chat windows of a device that show one of `chatIDs` (nil: every chat window of
    /// the device).
    func closeChatWindows(deviceID: String, chatIDs: Set<String>?) {
        for value in chatWindows where value.deviceID == deviceID && (chatIDs?.contains(value.chatID) ?? true) {
            windowRegistry.window(forChat: value)?.close()
        }
    }

    func openImageViewer(_ value: ImageViewerValue) {
        windowOpener?(.image(value))
    }

    func openAbout() {
        windowOpener?(.about)
    }

    /// Opens the Settings window, or brings it to front, on a tab.
    func openSettings(tab: SettingsTab? = nil) {
        if let tab {
            settingsTab = tab
        }
        openSettingsAction?()
    }

    /// Keeps the window actions of the SwiftUI environment, so the model can open windows itself
    /// (`ui.open`, restart windows, debug navigation).
    func captureWindowActions(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        windowOpener = Self.windowOpener(openWindow)
        openSettingsAction = openSettings
    }

    /// The `openWindow` action of the menu commands, which exist from launch on, before any
    /// window: the app can open a main window even when SwiftUI opened none.
    func captureCommandsOpenWindow(_ openWindow: OpenWindowAction) {
        if windowOpener == nil {
            windowOpener = Self.windowOpener(openWindow)
        }
    }

    private static func windowOpener(_ openWindow: OpenWindowAction) -> @MainActor (SceneWindow) -> Void {
        { window in
            switch window {
            case .main(let requestID): openWindow(id: "main", value: requestID)
            case .chat(let value): openWindow(id: "chat", value: value)
            case .image(let value): openWindow(id: "image", value: value)
            case .about: openWindow(id: "about")
            }
        }
    }

    /// Opens the remaining windows of a restart for an update, front to back, once
    /// (docs/ui.md › Windows).
    private func openRestartWindows() {
        guard !restartWindowsOpened else { return }
        restartWindowsOpened = true
        while !restartMainWindowStates.isEmpty {
            guard let state = WindowState.restored(fromJSON: restartMainWindowStates.removeFirst()) else { continue }
            openMainWindow(validated(state))
        }
        for value in restartChatWindows {
            openChatWindow(value)
        }
        restartChatWindows.removeAll()
    }

    // MARK: Events

    /// Routes the events of a workspace to the windows: `ui.open`, removed projects, deleted
    /// chats, tickets and bundles, and the waiting chats of the Dock badge.
    private func observe(_ workspace: DeviceWorkspace) {
        workspace.planUsageStored = { [weak self] in
            self?.sharePlanUsage()
        }
        let events = workspace.events()
        tasks.append(Task { [weak self, weak workspace] in
            for await event in events {
                guard let self, let workspace else { return }
                self.handle(event, from: workspace)
            }
        })
    }

    /// docs/remote.md › Plan usage sharing, steps 2 and 3: the newest plan usage of the open
    /// workspaces, values whose reset time has passed left out, is reported to every connected
    /// workspace whose value is absent or older. A failed call is ignored.
    func sharePlanUsage() {
        let now = Date()
        let values = workspaces.values.compactMap(\.planUsage).filter { !$0.hasExpired(at: now) }
        guard let newest = values.max(by: { $0.received < $1.received }) else { return }
        for workspace in workspaces.values where workspace.isConnected && workspace.hasSnapshot {
            if let value = workspace.planUsage, value.received >= newest.received { continue }
            Task {
                _ = try? await workspace.call(ClaudeReportPlanUsage.self, .init(usage: newest))
            }
        }
    }

    private func handle(_ event: WorkspaceEvent, from workspace: DeviceWorkspace) {
        let deviceID = workspace.deviceID
        if !event.removedChatIDs.isEmpty {
            closeChatWindows(deviceID: deviceID, chatIDs: Set(event.removedChatIDs))
        }
        switch event.event {
        case .uiOpen(let payload):
            // Handled only when its deviceID is absent or equals This Mac's (Brief §4.2).
            guard payload.deviceID == nil || payload.deviceID?.uppercased() == localDeviceID else { return }
            route(payload.target, from: workspace)
        case .projectRemoved(let payload):
            projectWasRemoved(payload.projectID, from: workspace)
        case .projectsChanged:
            for state in windows.values where state.deviceID == deviceID {
                state.reconcileProject(with: workspace)
            }
            updateWaitingChats()
        case .chatDeleted(let payload):
            closeChatWindows(deviceID: deviceID, chatIDs: [payload.chatID.uuidString])
            updateWaitingChats()
        case .chatUpdated:
            updateWaitingChats()
        case .chatNotification(let payload):
            chatNotifier.handle(payload, from: workspace)
        case .ticketDeleted(let payload):
            // The ticket may be selected in its project's list and in the lists of its ancestors
            // (docs/tickets.md › Tickets section).
            for state in windows.values where state.deviceID == deviceID {
                for key in state.projectStates.keys where key.deviceID == deviceID
                    && state.projectStates[key]?.selectedTicketIDs.contains(payload.ticketID) == true {
                    state.projectStates[key]?.selectedTicketIDs.remove(payload.ticketID)
                }
            }
        case .bundleDeleted(let payload):
            for state in windows.values where state.deviceID == deviceID {
                state.updateViewState(of: payload.projectID) {
                    if $0.selectedBundleID == payload.bundleID { $0.selectedBundleID = nil }
                }
            }
        default:
            break
        }
    }

    /// docs/projects.md › Removing a project: a main window whose active project was removed
    /// activates the nearest remaining ancestor, else the default project, else the welcome view;
    /// the removed project's unsaved editors are discarded and its sheets close.
    private func projectWasRemoved(_ projectID: String, from workspace: DeviceWorkspace) {
        let key = ProjectKey(deviceID: workspace.deviceID, projectID: projectID)
        for state in windows.values where state.deviceID == workspace.deviceID {
            state.projectStates[key] = nil
            if state.sheet?.projectID == projectID {
                state.sheet = nil
            }
            guard state.projectID == projectID else { continue }
            if let ancestor = workspace.nearestRemainingAncestor(of: projectID) {
                state.activate(projectID: ancestor)
            } else {
                state.needsDefaultProject = true
                state.reconcileProject(with: workspace)
            }
        }
        updateWaitingChats()
    }

    /// docs/ui.md › Choosing the window, `ui.open` row: the key window when it is a main window
    /// showing the workspace's device; otherwise the most recently key main window showing that
    /// device; otherwise a new main window on that device. The window is ordered front and becomes
    /// key only when the app is already active.
    private func route(_ target: NavigationTarget, from workspace: DeviceWorkspace) {
        route(target, deviceID: workspace.deviceID, makesKey: false)
    }

    /// docs/ui.md › Choosing the window, chat notification row: the app is activated, and the
    /// window chosen as for `ui.open` is ordered front and made key.
    func openNotifiedChat(_ chatID: ChatID, deviceID: String) {
        guard workspace(for: deviceID) != nil else { return }
        NSApp.activate()
        route(.chat(chatID: chatID), deviceID: deviceID, makesKey: true)
    }

    /// The key main window showing the device, else the most recently key one, else a new main
    /// window on the device; `makesKey` makes the chosen window key even before the app is
    /// active.
    private func route(_ target: NavigationTarget, deviceID: String, makesKey: Bool) {
        let keyMain = windowRegistry.mainID(of: NSApp.keyWindow).flatMap { windows[$0] }
        let chosen = (keyMain?.deviceID == deviceID ? keyMain : nil)
            ?? mainWindowsByKeyOrder.first { $0.deviceID == deviceID }
        guard let chosen else {
            let state = WindowState(deviceID: deviceID)
            state.needsDefaultProject = true
            state.pendingTarget = target
            openMainWindow(state)
            return
        }
        if makesKey {
            windowRegistry.window(forMain: chosen.id)?.makeKeyAndOrderFront(nil)
        } else {
            bringToFront(chosen)
        }
        Task {
            await chosen.navigate(to: target)
        }
    }

    /// Orders a main window front; it becomes key only when the app is active.
    func bringToFront(_ state: WindowState) {
        guard let window = windowRegistry.window(forMain: state.id) else { return }
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    /// The Dock badge counts the chats waiting for permission or answers in every open workspace;
    /// a chat that starts waiting while the app is not active requests the user's attention once
    /// (docs/ui.md › Status bar).
    func updateWaitingChats() {
        var waiting = Set<String>()
        for workspace in workspaces.values {
            for meta in workspace.chats.values where meta.state == .waitingPermission || meta.state == .waitingAnswers {
                waiting.insert(workspace.deviceID + "/" + meta.id.uuidString)
            }
        }
        NSApp.dockTile.badgeLabel = waiting.isEmpty ? nil : String(waiting.count)
        if !NSApp.isActive {
            for _ in waiting.subtracting(waitingChatKeys) {
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
        waitingChatKeys = waiting
    }

    // MARK: Local-only services

    private func observeLocalServices() {
        let engine = engine
        tasks.append(Task { [weak self] in
            for await state in await engine.mcpServer.stateUpdates() {
                self?.mcpState = state
            }
        })
        tasks.append(Task { [weak self] in
            for await status in await engine.syncServer.statusUpdates() {
                self?.syncStatus = status
            }
        })
        let paired = engine.pairedDevices.deviceUpdates
        tasks.append(Task { [weak self] in
            for await devices in paired {
                self?.pairedDevicesChanged(devices)
            }
        })
        let discovered = engine.deviceBrowser.deviceUpdates
        tasks.append(Task { [weak self] in
            for await devices in discovered {
                self?.discoveredDevices = devices
            }
        })
    }

    /// A removed paired device: its windows switch to This Mac and its chat windows close
    /// (docs/ui.md › Devices, Remove…).
    private func pairedDevicesChanged(_ devices: [RemoteDevice]) {
        let remaining = Set(devices.map(\.id.uuidString))
        let removed = Set(pairedDevices.map(\.id.uuidString)).subtracting(remaining)
        pairedDevices = devices
        for deviceID in removed {
            closeChatWindows(deviceID: deviceID, chatIDs: nil)
            for state in windows.values where state.deviceID == deviceID {
                state.switchDevice(to: localDeviceID)
            }
            workspaces[deviceID]?.close()
            workspaces[deviceID] = nil
        }
    }

    /// Keeps `keyWindowOrder` current.
    private func observeKeyWindows() {
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                                queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow, let id = self.windowRegistry.mainID(of: window) else { return }
                self.keyWindowOrder.removeAll { $0 == id }
                self.keyWindowOrder.insert(id, at: 0)
                self.interceptCloseButton(of: window, mainID: id)
            }
        })
    }
}

extension WindowSheet {
    /// The project a sheet acts on, when it acts on one.
    var projectID: String? {
        switch self {
        case .newSubProject(let projectID), .newTicket(let projectID),
             .ticketPicker(let projectID, _, _), .newSkill(let projectID), .newDoc(let projectID, _),
             .renameDoc(let projectID, _), .newFile(let projectID, _, _), .renameFile(let projectID, _),
             .environment(let projectID, _):
            return projectID
        case .implementTicket(let id), .implementBundle(let id), .addLink(let id):
            return Identifiers.projectID(of: id)
        case .newMemory(let projectID):
            // nil for the global memories folder, which belongs to no project.
            return projectID
        case .newProject, .newProjectInFolder, .openProjectFolder, .addDevice, .feedback, .newSkillFile, .webPageDialog:
            return nil
        }
    }
}

/// One window of `windowsAtRestart`: the persisted `WindowState` of a main window, or the
/// `ChatWindowValue` of a chat window: `{"main": <persisted WindowState JSON text>}` or
/// `{"chat": {deviceID, chatID}}` (docs/ui.md › Windows).
struct RestartWindowRecord: Codable {
    var main: String?
    var chat: ChatWindowValue?
}

/// A window the model opens in one of the scenes of docs/ui.md › Windows.
enum SceneWindow: Hashable {
    /// A main window, whose root takes the state prepared for `requestID`.
    case main(requestID: UUID)
    case chat(ChatWindowValue)
    case image(ImageViewerValue)
    case about
}
