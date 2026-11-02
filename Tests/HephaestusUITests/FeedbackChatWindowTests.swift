import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/feedback.md › Feedback sheet, docs/ui.md › Choosing the window: after Send, a main window
/// shows the feedback chat; no chat window opens.
@MainActor
@Suite("Feedback chat window")
struct FeedbackChatWindowTests {
    private let thisMac = "this-mac"
    private let studio = "studio"

    @Test("Feedback captured from a main window: that main window, even when another was key more recently")
    func capturedMainWindow() {
        let recent = WindowState(deviceID: thisMac)
        let captured = WindowState(deviceID: thisMac)
        let chosen = FeedbackController.mainWindow(for: .main(captured), receivingDeviceID: thisMac,
                                                   mainWindowsByKeyOrder: [recent, captured])
        #expect(chosen?.id == captured.id)
    }

    @Test("Feedback captured from a remote main window: that main window")
    func capturedRemoteMainWindow() {
        let local = WindowState(deviceID: thisMac)
        let remote = WindowState(deviceID: studio)
        let chosen = FeedbackController.mainWindow(for: .main(remote), receivingDeviceID: studio,
                                                   mainWindowsByKeyOrder: [local, remote])
        #expect(chosen?.id == remote.id)
    }

    @Test("Feedback captured from a chat window: the most recently key main window showing the chat's device")
    func chatWindowTakesMostRecentlyKeyMainWindowOfItsDevice() {
        let local = WindowState(deviceID: thisMac)
        let remoteRecent = WindowState(deviceID: studio)
        let remoteOlder = WindowState(deviceID: studio)
        let source = FeedbackSource.chat(ChatWindowValue(deviceID: studio, chatID: UUID().uuidString))
        let chosen = FeedbackController.mainWindow(for: source, receivingDeviceID: studio,
                                                   mainWindowsByKeyOrder: [local, remoteRecent, remoteOlder])
        #expect(chosen?.id == remoteRecent.id)
    }

    @Test("Feedback captured from Settings, About or another window: the most recently key main window showing This Mac")
    func otherWindowTakesMostRecentlyKeyMainWindowOfThisMac() {
        let remote = WindowState(deviceID: studio)
        let localRecent = WindowState(deviceID: thisMac)
        let localOlder = WindowState(deviceID: thisMac)
        let chosen = FeedbackController.mainWindow(for: .other, receivingDeviceID: thisMac,
                                                   mainWindowsByKeyOrder: [remote, localRecent, localOlder])
        #expect(chosen?.id == localRecent.id)
    }

    @Test("No main window shows the receiving device: a new main window opens")
    func noMainWindowOfTheDevice() {
        let local = WindowState(deviceID: thisMac)
        let source = FeedbackSource.chat(ChatWindowValue(deviceID: studio, chatID: UUID().uuidString))
        #expect(FeedbackController.mainWindow(for: source, receivingDeviceID: studio, mainWindowsByKeyOrder: [local]) == nil)
        #expect(FeedbackController.mainWindow(for: .other, receivingDeviceID: thisMac, mainWindowsByKeyOrder: []) == nil)
    }

    @Test("A captured main window closed meanwhile: the most recently key main window showing the device")
    func closedCapturedMainWindow() {
        let closed = WindowState(deviceID: thisMac)
        let open = WindowState(deviceID: thisMac)
        let chosen = FeedbackController.mainWindow(for: .main(closed), receivingDeviceID: thisMac,
                                                   mainWindowsByKeyOrder: [open])
        #expect(chosen?.id == open.id)
    }

    @Test("Send from a main window: that window navigates to the chat and no window opens")
    func showChatNavigatesTheCapturedMainWindow() async throws {
        try await withAppModel { app, opened in
            let other = try #require(app.mainWindowRootAppeared(requestID: nil, restoredJSON: nil))
            let captured = WindowState(deviceID: app.localDeviceID)
            app.registerMainWindow(captured)
            #expect(app.mainWindowsByKeyOrder.map(\.id) == [captured.id, other.id])
            let meta = ChatMeta(id: UUID(), kind: .feedback, created: Date(), projectID: "DEMO")

            await app.feedbackController.showChat(meta, in: app.localWorkspace, source: .main(captured))

            #expect(opened.windows.isEmpty)
            #expect(app.localWorkspace.chats[meta.id.uuidString]?.projectID == "DEMO")
            let target = NavigationTarget.chat(chatID: meta.id)
            let navigated = captured.pendingTarget == target
                || captured.projectStates.values.contains { $0.selectedChatID == meta.id.uuidString }
            #expect(navigated)
            #expect(other.pendingTarget == nil)
        }
    }

    @Test("Send without a main window on the receiving device: a new main window opens on it with the chat target")
    func showChatOpensANewMainWindow() async throws {
        try await withAppModel { app, opened in
            let meta = ChatMeta(id: UUID(), kind: .feedback, created: Date(), projectID: "DEMO")

            await app.feedbackController.showChat(meta, in: app.localWorkspace, source: .other)

            #expect(opened.windows.count == 1)
            guard case .main(let requestID) = try #require(opened.windows.first) else {
                Issue.record("The opened window is not a main window: \(opened.windows)")
                return
            }
            let state = try #require(app.mainWindowRootAppeared(requestID: requestID, restoredJSON: nil))
            #expect(state.deviceID == app.localDeviceID)
            #expect(state.pendingTarget == .chat(chatID: meta.id))
        }
    }
}

/// The windows an `AppModel` asked SwiftUI to open, in order.
@MainActor
private final class OpenedWindows {
    var windows: [SceneWindow] = []
}

/// Creates an `AppModel` on an engine of a temporary data directory, which is never started,
/// records the windows it opens, and runs `check`. `HEPHAESTUS_DATA_DIR` is set, so the model
/// neither reads nor writes `UserDefaults`.
@MainActor
private func withAppModel(_ check: (AppModel, OpenedWindows) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = folder.appendingPathComponent("Data", isDirectory: true)
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: NoClaudeLauncher()))
    let connection = await LocalEngineConnection(engine: engine)
    let app = AppModel(environment: LaunchEnvironment(dataDirectory: data), engine: engine,
                       appVersion: AppVersion(version: "0.0.0", build: 0), connection: connection, restartWindows: nil)
    let opened = OpenedWindows()
    app.windowOpener = { opened.windows.append($0) }
    do {
        try await check(app, opened)
    } catch {
        connection.close()
        await engine.shutdown()
        throw error
    }
    connection.close()
    await engine.shutdown()
}

/// A launcher that starts nothing: the engine is never started, so no Claude process runs.
private struct NoClaudeLauncher: ClaudeProcessLauncher {}
