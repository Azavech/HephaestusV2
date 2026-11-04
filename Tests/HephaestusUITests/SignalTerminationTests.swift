import AppKit
import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/architecture.md › Shutdown: SIGTERM and SIGINT are handled like Quit without its
/// confirmation alerts, also while a window shows a sheet. SwiftUI presents a sheet again as long
/// as its state asks for it, so the termination clears that state before AppKit terminates.
@MainActor
@Suite("Termination by a signal")
struct SignalTerminationTests {
    @Test("Ending the sheets clears the sheet and the alert of every main window and sets sheetsEnded")
    func endSwiftUISheetsClearsWindowState() async throws {
        try await withAppModel { app in
            let implementing = WindowState(deviceID: app.localDeviceID)
            implementing.sheet = .implementTicket(ticketID: "DEMO-1")
            implementing.alert = WindowAlert(title: "New Tab failed", message: "No connection.")
            let creating = WindowState(deviceID: app.localDeviceID)
            creating.sheet = .newTicket(projectID: "DEMO")
            app.registerMainWindow(implementing)
            app.registerMainWindow(creating)
            #expect(!app.sheetsEnded)

            app.endSwiftUISheets()

            #expect(implementing.sheet == nil)
            #expect(implementing.alert == nil)
            #expect(creating.sheet == nil)
            #expect(app.sheetsEnded)
        }
    }
}

/// Creates an `AppModel` on an engine of a temporary data directory, which is never started, and
/// runs `check`. `HEPHAESTUS_DATA_DIR` is set, so the model neither reads nor writes
/// `UserDefaults`.
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
