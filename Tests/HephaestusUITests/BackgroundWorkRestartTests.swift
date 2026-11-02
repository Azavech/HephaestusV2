import AppKit
import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/updater.md › Restart rules, docs/ui.md › Unsaved changes and quitting and › Status bar:
/// a chat whose Claude process has background work running is a working chat, so the app is not
/// idle, the automatic restart waits, the quit and restart alerts count it, and the status bar
/// counts it as running (docs/chats.md › Background work).
@MainActor
@Suite("Background work and the restart")
struct BackgroundWorkRestartTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)
    static let readyStatus = UpdaterStatus(state: .ready, version: "0.5.0", build: 61)

    static func chat(_ state: ChatState, backgroundWork: Bool, projectID: ProjectID = "DEMO") -> ChatMeta {
        ChatMeta(id: UUID(), kind: .project, created: created, projectID: projectID, state: state, backgroundWork: backgroundWork)
    }

    /// The automatic restart decision for an update `ready` with `autoUpdate` true and Install not
    /// chosen, with the app's current idleness.
    static func automaticRestart(_ app: AppModel) -> UpdateController.AutomaticRestart {
        UpdateController.automaticRestart(updaterRunning: true, autoUpdate: true, installChosen: false, restartChecksRunning: false,
                                          restartInProgress: false, quittingPosted: false, status: readyStatus, blockedBuild: nil,
                                          idle: app.updateController.isAppIdle)
    }

    @Test("isAppIdle is false while a chat's Claude process has background work, even when the chat is idle, and true once it ended")
    func idleWaitsForBackgroundWork() async throws {
        try await withAppModel { app in
            let id = UUID()
            @MainActor func set(_ state: ChatState, _ backgroundWork: Bool) {
                var meta = Self.chat(state, backgroundWork: backgroundWork)
                meta.id = id
                app.localWorkspace.chats[id.uuidString] = meta
            }
            set(.idle, false)
            #expect(app.updateController.isAppIdle)
            // The turn ended while a background command runs.
            set(.idle, true)
            #expect(!app.updateController.isAppIdle)
            // The command ended: the CLI starts the turn that reports it.
            set(.running, false)
            #expect(!app.updateController.isAppIdle)
            // That turn ended and nothing is unsaved.
            set(.idle, false)
            #expect(app.updateController.isAppIdle)
            // A chat waiting for answers counts only while its background work runs.
            set(.waitingAnswers, true)
            #expect(!app.updateController.isAppIdle)
            set(.waitingAnswers, false)
            #expect(app.updateController.isAppIdle)
        }
    }

    @Test("An update ready with autoUpdate true waits while background work runs and restarts once it and its turn have ended")
    func automaticRestartWaitsForBackgroundWork() async throws {
        try await withAppModel { app in
            var meta = Self.chat(.idle, backgroundWork: true)
            app.localWorkspace.chats[meta.id.uuidString] = meta
            #expect(Self.automaticRestart(app) == .waitsForIdle)
            meta.state = .running
            meta.backgroundWork = false
            app.localWorkspace.chats[meta.id.uuidString] = meta
            #expect(Self.automaticRestart(app) == .waitsForIdle)
            meta.state = .idle
            app.localWorkspace.chats[meta.id.uuidString] = meta
            #expect(Self.automaticRestart(app) == .startsNow)
            // Without autoUpdate, or with Install chosen, there is no automatic restart.
            #expect(UpdateController.automaticRestart(updaterRunning: true, autoUpdate: false, installChosen: false,
                                                      restartChecksRunning: false, restartInProgress: false, quittingPosted: false,
                                                      status: Self.readyStatus, blockedBuild: nil, idle: true) == .notApplicable)
            #expect(UpdateController.automaticRestart(updaterRunning: true, autoUpdate: true, installChosen: true,
                                                      restartChecksRunning: false, restartInProgress: false, quittingPosted: false,
                                                      status: Self.readyStatus, blockedBuild: nil, idle: true) == .notApplicable)
            #expect(UpdateController.automaticRestart(updaterRunning: true, autoUpdate: true, installChosen: false,
                                                      restartChecksRunning: false, restartInProgress: false, quittingPosted: false,
                                                      status: Self.readyStatus, blockedBuild: 61, idle: true) == .notApplicable)
        }
    }

    @Test("The quit and restart alerts count a chat with background work as running")
    func alertsCountBackgroundWork() async throws {
        try await withAppModel { app in
            for meta in [Self.chat(.idle, backgroundWork: true), Self.chat(.running, backgroundWork: false),
                         Self.chat(.waitingAnswers, backgroundWork: true), Self.chat(.waitingAnswers, backgroundWork: false),
                         Self.chat(.idle, backgroundWork: false)] {
                app.localWorkspace.chats[meta.id.uuidString] = meta
            }
            #expect(app.workingChatCount == 3)
            #expect(AppModel.runningWorkMessage(chats: app.workingChatCount, runs: 0) == "3 chats on This Mac will be stopped.")
        }
    }

    @Test("The status bar counts an idle chat with background work as running, with the label Running in background")
    func statusBarCountsBackgroundWork() {
        let background = Self.chat(.idle, backgroundWork: true)
        #expect(StatusBarChats.isRunning(background))
        #expect(!StatusBarChats.isWaiting(background))
        #expect(StatusBarChats.label(background) == "Running in background")
        #expect(StatusBarChats.markState(background) == .running)
        let running = Self.chat(.running, backgroundWork: true)
        #expect(StatusBarChats.isRunning(running))
        #expect(StatusBarChats.label(running) == "Running")
        let waiting = Self.chat(.waitingAnswers, backgroundWork: true)
        #expect(!StatusBarChats.isRunning(waiting))
        #expect(StatusBarChats.isWaiting(waiting))
        #expect(StatusBarChats.label(waiting) == "Waiting for answers")
        #expect(!StatusBarChats.isRunning(Self.chat(.idle, backgroundWork: false)))
    }

    @Test("Removing a project with a chat whose background work runs says that its running chats are stopped")
    func removalCountsBackgroundWork() {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let project = ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo")
        let meta = Self.chat(.idle, backgroundWork: true)
        workspace.chats[meta.id.uuidString] = meta
        #expect(ProjectFlows.removalMessage(project: project, descendants: [], workspace: workspace, removedIDs: ["DEMO"])
            == "The folder and its files stay on disk: /Users/example/Demo. Running chats and runs of these projects are stopped.")
        workspace.chats[meta.id.uuidString] = Self.chat(.idle, backgroundWork: false)
        #expect(ProjectFlows.removalMessage(project: project, descendants: [], workspace: workspace, removedIDs: ["DEMO"])
            == "The folder and its files stay on disk: /Users/example/Demo.")
    }
}

/// Creates an `AppModel` on an engine of a temporary data directory, which is never started, and
/// runs `check`. `HEPHAESTUS_DATA_DIR` is set, so the model neither reads nor writes
/// `UserDefaults`. `isAppIdle` reads the application's windows, so the application is created.
@MainActor
private func withAppModel(_ check: @MainActor (AppModel) throws -> Void) async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = folder.appendingPathComponent("Data", isDirectory: true)
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: NoClaudeLauncher()))
    let connection = await LocalEngineConnection(engine: engine)
    let app = AppModel(environment: LaunchEnvironment(dataDirectory: data), engine: engine,
                       appVersion: AppVersion(version: "0.0.0", build: 0), connection: connection, restartWindows: nil)
    do {
        try check(app)
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
