import Foundation
import HephaestusCore
import Testing
import UserNotifications
@testable import HephaestusUI

/// docs/ui.md › Status bar, › Notifications: which events this Mac posts, the title, the
/// identifier per chat, the permission request and the Settings tab.
@Suite("Chat notifications")
@MainActor
struct ChatNotifierTests {
    func payload(_ kind: ChatNotificationEvent.Payload.Kind, _ stage: ChatNotificationEvent.Payload.Stage) -> ChatNotificationEvent.Payload {
        ChatNotificationEvent.Payload(chatID: UUID(), projectID: "HEPH", kind: kind, stage: stage, detail: "Done")
    }

    @Test("With the defaults, both kinds are posted at the summary stage only")
    func defaults() {
        let settings = HostSettings()
        for kind in ChatNotificationEvent.Payload.Kind.allCases {
            #expect(ChatNotifier.posts(payload(kind, .summary), settings: settings))
            #expect(!ChatNotifier.posts(payload(kind, .immediate), settings: settings))
        }
    }

    @Test("Each toggle turns its kind off; AI-generated summary off posts at the immediate stage")
    func toggles() {
        let noNeedsYou = HostSettings(notifyNeedsYou: false)
        #expect(!ChatNotifier.posts(payload(.needsYou, .summary), settings: noNeedsYou))
        #expect(ChatNotifier.posts(payload(.finished, .summary), settings: noNeedsYou))
        let noFinished = HostSettings(notifyFinished: false)
        #expect(!ChatNotifier.posts(payload(.finished, .summary), settings: noFinished))
        #expect(ChatNotifier.posts(payload(.needsYou, .summary), settings: noFinished))
        let noSummary = HostSettings(notifyAISummary: false)
        #expect(ChatNotifier.posts(payload(.finished, .immediate), settings: noSummary))
        #expect(!ChatNotifier.posts(payload(.finished, .summary), settings: noSummary))
    }

    @Test("Title `<project identifier> · <chat title>` and one identifier per chat of a device")
    func titleAndIdentifier() {
        #expect(ChatNotifier.title(projectID: "HEPH", chatTitle: "Status history for tickets") == "HEPH · Status history for tickets")
        #expect(ChatNotifier.identifier(deviceID: "D1", chatID: "C1") == "D1/C1")
    }

    @Test("The permission request includes alerts, sounds and badges")
    func authorizationOptions() {
        #expect(ChatNotifier.authorizationOptions == [.alert, .sound, .badge])
    }

    @Test("The app asks when it has not asked yet or when its earlier request had no badges")
    func requestsAuthorization() {
        #expect(ChatNotifier.requestsAuthorization(status: .notDetermined, badgeSetting: .notSupported))
        #expect(ChatNotifier.requestsAuthorization(status: .authorized, badgeSetting: .notSupported))
        #expect(!ChatNotifier.requestsAuthorization(status: .authorized, badgeSetting: .enabled))
        #expect(!ChatNotifier.requestsAuthorization(status: .authorized, badgeSetting: .disabled))
        #expect(ChatNotifier.requestsAuthorization(status: .denied, badgeSetting: .notSupported))
        #expect(!ChatNotifier.requestsAuthorization(status: .denied, badgeSetting: .disabled))
    }

    @Test("The Notifications tab comes after Devices, with bell.badge")
    func settingsTab() {
        let tabs = SettingsTab.allCases
        let devices = try? #require(tabs.firstIndex(of: .devices))
        #expect(devices.map { tabs[$0 + 1] } == .notifications)
        #expect(SettingsTab.notifications.title == "Notifications")
        #expect(SettingsTab.notifications.symbol == "bell.badge")
    }
}
