import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/ui.md › Windows: a restart for an update opens exactly the windows saved in
/// `windowsAtRestart`, the main window SwiftUI opens at launch included.
@MainActor
@Suite("Restart windows")
struct RestartWindowsTests {
    @Test("The launch window takes the first saved main window; only the others are opened")
    func launchWindowTakesFirstMainWindow() async throws {
        try await withAppModel { engine in
            let mainA = WindowState(deviceID: engine.deviceID)
            let mainB = WindowState(deviceID: engine.deviceID)
            mainB.section = .tickets
            let chatC = ChatWindowValue(deviceID: engine.deviceID, chatID: UUID().uuidString)
            let jsonA: String = try #require(mainA.persistedJSON)
            let jsonB: String = try #require(mainB.persistedJSON)
            return [RestartWindowRecord(main: jsonA), RestartWindowRecord(main: jsonB), RestartWindowRecord(chat: chatC)]
        } check: { app, records, opened in
            let launch = try #require(app.mainWindowRootAppeared(requestID: nil, restoredJSON: nil))
            #expect(launch.id == WindowState.restored(fromJSON: try #require(records[0].main))?.id)
            #expect(Array(app.windows.keys) == [launch.id])

            #expect(opened.windows.count == 2)
            guard case .main(let requestID) = try #require(opened.windows.first) else {
                Issue.record("The first opened window is not a main window: \(opened.windows)")
                return
            }
            #expect(opened.windows.last == .chat(try #require(records[2].chat)))

            // SwiftUI opens the requested window: its root takes B's state.
            let opening = try #require(app.mainWindowRootAppeared(requestID: requestID, restoredJSON: nil))
            #expect(opening.id == WindowState.restored(fromJSON: try #require(records[1].main))?.id)
            #expect(opening.section == .tickets)
            #expect(opened.windows.count == 2)
        }
    }

    @Test("Saved windows without a main window close the launch window and open the chat windows")
    func launchWindowSuppressedWithoutMainWindow() async throws {
        try await withAppModel { engine in
            [RestartWindowRecord(chat: ChatWindowValue(deviceID: engine.deviceID, chatID: UUID().uuidString)),
             RestartWindowRecord(chat: ChatWindowValue(deviceID: engine.deviceID, chatID: UUID().uuidString))]
        } check: { app, records, opened in
            #expect(app.mainWindowRootAppeared(requestID: nil, restoredJSON: nil) == nil)
            #expect(app.windows.isEmpty)
            #expect(opened.windows == records.compactMap(\.chat).map { SceneWindow.chat($0) })
        }
    }
}

/// The windows an `AppModel` asked SwiftUI to open, in order.
@MainActor
private final class OpenedWindows {
    var windows: [SceneWindow] = []
}

/// Creates an `AppModel` on an engine of a temporary data directory, which is never started, with
/// the restart windows `records` returns, records the windows it opens, and runs `check`.
/// `HEPHAESTUS_DATA_DIR` is set, so the model neither reads nor writes `UserDefaults`.
@MainActor
private func withAppModel(_ records: (Engine) throws -> [RestartWindowRecord],
                          check: (AppModel, [RestartWindowRecord], OpenedWindows) throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = folder.appendingPathComponent("Data", isDirectory: true)
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: NoClaudeLauncher()))
    let connection = await LocalEngineConnection(engine: engine)
    let saved = try records(engine)
    let app = AppModel(environment: LaunchEnvironment(dataDirectory: data), engine: engine,
                       appVersion: AppVersion(version: "0.0.0", build: 0), connection: connection, restartWindows: saved)
    let opened = OpenedWindows()
    app.windowOpener = { opened.windows.append($0) }
    do {
        try check(app, saved, opened)
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
