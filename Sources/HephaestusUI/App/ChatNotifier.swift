// OWNER: ui-shell — the macOS notifications of chats: the permission asked at launch, posting,
// replacing and removing them per chat, and their click (docs/ui.md › Status bar; docs/chats.md ›
// Notifications).
import AppKit
import HephaestusCore
import UserNotifications

/// Turns the `chat.notification` events of the open workspaces into notifications of this Mac,
/// with UserNotifications. A process started with `HEPHAESTUS_DATA_DIR` neither asks for the
/// permission nor posts (docs/architecture.md › Environment overrides, rule 9).
@MainActor
final class ChatNotifier: NSObject {
    weak var app: AppModel?
    /// Nil when the process does not post notifications.
    private let center: UNUserNotificationCenter?
    /// The chat views open in this app, by view model.
    private var openViews: [ObjectIdentifier: OpenChatView] = [:]
    private var observers: [NSObjectProtocol] = []

    private struct OpenChatView {
        weak var model: ChatViewModel?
        /// The notification identifier of the chat.
        var identifier: String
    }

    /// `enabled` false: the process neither asks nor posts. UserNotifications also needs the app
    /// bundle, which tests do not run from.
    init(enabled: Bool) {
        center = enabled && Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
        super.init()
        guard let center else { return }
        center.delegate = self
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                                queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                self?.windowBecameKey(window)
            }
        })
    }

    /// The identifier of a chat's notification: each chat has at most one on this Mac.
    static func identifier(deviceID: String, chatID: String) -> String {
        "\(deviceID)/\(chatID)"
    }

    /// `<project identifier> · <chat title>`.
    static func title(projectID: String, chatTitle: String) -> String {
        "\(projectID) · \(chatTitle)"
    }

    /// Whether this Mac posts the event under its settings: the kind's toggle is on, and the
    /// event's stage is `summary` while `AI-generated summary` is on, `immediate` while it is off.
    static func posts(_ payload: ChatNotificationEvent.Payload, settings: HostSettings) -> Bool {
        switch payload.kind {
        case .needsYou: guard settings.notifyNeedsYou else { return false }
        case .finished: guard settings.notifyFinished else { return false }
        }
        return payload.stage == (settings.notifyAISummary ? .summary : .immediate)
    }

    // MARK: Permission

    /// The options of the permission request: alerts, sounds and the Dock badge.
    nonisolated static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound, .badge]

    /// Whether the app asks for the permission: it has not asked yet, or its earlier request did
    /// not include badges.
    nonisolated static func requestsAuthorization(status: UNAuthorizationStatus, badgeSetting: UNNotificationSetting) -> Bool {
        status == .notDetermined || badgeSetting == .notSupported
    }

    /// Startup step 10: asks macOS for the permission to post notifications when it has not
    /// asked yet or when its earlier request did not include badges.
    func requestAuthorizationIfNeeded() {
        guard let center else { return }
        let log = app?.engine.log
        center.getNotificationSettings { settings in
            guard Self.requestsAuthorization(status: settings.authorizationStatus, badgeSetting: settings.badgeSetting) else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: Self.authorizationOptions) { _, error in
                if let error {
                    log?.warn(.ui, "notification permission request failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Posting

    /// A `chat.notification` event of an open workspace.
    func handle(_ payload: ChatNotificationEvent.Payload, from workspace: DeviceWorkspace) {
        guard let center, let app, let settings = app.localWorkspace.settings, Self.posts(payload, settings: settings) else { return }
        let chatID = payload.chatID.uuidString
        guard let meta = workspace.chats[chatID] else { return }
        let identifier = Self.identifier(deviceID: workspace.deviceID, chatID: chatID)
        if NSApp.isActive, let key = NSApp.keyWindow, shows(identifier, in: key) { return }
        let content = UNMutableNotificationContent()
        content.title = Self.title(projectID: meta.projectID, chatTitle: meta.title)
        content.body = payload.detail
        content.sound = .default
        content.userInfo = ["deviceID": workspace.deviceID, "chatID": chatID]
        let log = app.engine.log
        // The previous notification of the chat goes first, so the new one shows as a banner.
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                log.warn(.ui, "a chat notification could not be posted: \(error.localizedDescription)")
            }
        }
    }

    /// Whether a chat view of `window` shows the chat of `identifier`.
    private func shows(_ identifier: String, in window: NSWindow) -> Bool {
        openViews.values.contains { $0.identifier == identifier && $0.model?.windowReference.window === window }
    }

    // MARK: Removing

    /// A chat view opened a chat: its notification is removed.
    func chatViewOpened(_ model: ChatViewModel) {
        guard let chatID = model.chatID else { return }
        let identifier = Self.identifier(deviceID: model.workspace.deviceID, chatID: chatID)
        openViews = openViews.filter { $0.value.model != nil }
        openViews[ObjectIdentifier(model)] = OpenChatView(model: model, identifier: identifier)
        remove([identifier])
    }

    func chatViewClosed(_ model: ChatViewModel) {
        openViews[ObjectIdentifier(model)] = nil
    }

    /// A window became key: the notifications of the chats it shows are removed.
    private func windowBecameKey(_ window: NSWindow) {
        let identifiers = openViews.values.filter { $0.model?.windowReference.window === window }.map(\.identifier)
        remove(identifiers)
    }

    private func remove(_ identifiers: [String]) {
        guard let center, !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

extension ChatNotifier: UNUserNotificationCenterDelegate {
    /// Notifications show as banners also while the app is active; `handle` already left out a
    /// chat shown in the key window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A click brings the app to the front and navigates a main window to the chat.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let isOpen = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let deviceID = info["deviceID"] as? String
        let chatID = (info["chatID"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if isOpen, let deviceID, let chatID {
                    self.app?.openNotifiedChat(chatID, deviceID: deviceID)
                }
                completionHandler()
            }
        }
    }
}
