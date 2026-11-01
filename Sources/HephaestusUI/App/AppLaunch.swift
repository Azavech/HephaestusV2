// OWNER: ui-shell — startup steps 1 to 8 of docs/architecture.md › Startup, with the exits of
// docs/architecture.md › Environment overrides (64) and › Device data directory (75).
import AppKit
import Darwin
import Foundation
import HephaestusCore
import UpdaterCore

extension AppModel {
    /// Creates the app's model at launch, before any window opens, in the order of
    /// docs/architecture.md › Startup:
    ///
    /// 1. parses the environment (an invalid value: a message on standard error and exit 64);
    /// 2. creates the engine, which takes the data directory lock (in use: a message on standard
    ///    error, an alert unless `HEPHAESTUS_WINDOW_SCREEN` is set, and exit 75), opens engine.log
    ///    and loads the device files;
    /// 3. starts the engine (projects, file watching, Bonjour browsing, the MCP server, the sync
    ///    server, the Claude CLI background tasks);
    /// 4. creates the local workspace on a `LocalEngineConnection` and installs the `MCPDebugUI`
    ///    implementation when debug tools are enabled.
    ///
    /// The engine work runs off the main thread while the main thread waits: no window exists yet,
    /// and the first window opens with the local workspace in place. The engine, its start and the
    /// local connection never need the main actor. Step 9 (the Updater) runs once the app has
    /// finished launching.
    public static func launch() -> AppModel {
        if let shared { return shared }

        let environment: LaunchEnvironment
        do {
            environment = try LaunchEnvironment.parse(ProcessInfo.processInfo.environment)
        } catch let error as LaunchEnvironmentError {
            exitWithMessage(error.message, status: LaunchEnvironment.invalidExitStatus)
        } catch {
            exitWithMessage("HephaestusV2: \(error)", status: LaunchEnvironment.invalidExitStatus)
        }

        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = AppVersion(infoPlist: info)
            ?? AppVersion(version: info["CFBundleShortVersionString"] as? String ?? "", build: 0)
        let configuration = EngineConfiguration.app(environment: environment, appVersion: appVersion.version,
                                                    build: appVersion.build)

        let engine: Engine
        do {
            engine = try waitFor { try await Engine(configuration: configuration) }
        } catch StorageError.dataDirectoryInUse(let path) {
            let message = DataDirectoryLock.inUseMessage(path: path)
            writeToStandardError(message)
            if environment.windowScreen == nil {
                showLaunchAlert(message)
            }
            exit(DataDirectoryLock.inUseExitStatus)
        } catch {
            // DOC-GAP: docs/architecture.md › Startup defines exits 64 and 75 only; a data directory
            // that cannot be created, locked or loaded for another reason writes its error to
            // standard error and exits with 74 (EX_IOERR).
            exitWithMessage("HephaestusV2: \(errorMessage(error))", status: 74)
        }
        waitFor { await engine.start() }
        let connection = waitFor { await LocalEngineConnection(engine: engine) }

        WindowPlacement.disablesRestoration = !environment.restoresWindowState
        if let screen = environment.windowScreen {
            WindowPlacement.install(screen, log: engine.log)
        }
        let model = AppModel(environment: environment, engine: engine, appVersion: appVersion, connection: connection,
                             restartWindows: takeWindowsAtRestart(environment))
        if environment.debugTools {
            let debugUI = AppDebugUI(app: model)
            model.debugUI = debugUI
            waitFor { await engine.mcpServer.installDebugUI(debugUI) }
        }
        shared = model
        return model
    }

    /// Reads and deletes `windowsAtRestart`; nil when the key is absent or the process neither
    /// reads nor writes window state (docs/ui.md › Windows).
    private static func takeWindowsAtRestart(_ environment: LaunchEnvironment) -> [RestartWindowRecord]? {
        guard environment.restoresWindowState,
              let data = UserDefaults.standard.data(forKey: windowsAtRestartDefaultsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: windowsAtRestartDefaultsKey)
        return (try? JSONDecoder().decode([RestartWindowRecord].self, from: data)) ?? []
    }

    private static func writeToStandardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func exitWithMessage(_ message: String, status: Int32) -> Never {
        writeToStandardError(message)
        exit(status)
    }

    /// The data directory alert, which has no window: the text and an OK button.
    private static func showLaunchAlert(_ message: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Runs async work to completion while the calling thread waits; used only at launch, before the
/// first window, for work that never needs the main actor.
private func waitFor<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = LaunchResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            box.result = .success(try await operation())
        } catch {
            box.result = .failure(error)
        }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

private func waitFor<T>(_ operation: @escaping @Sendable () async -> T) -> T {
    let box = LaunchResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.result = .success(await operation())
        done.signal()
    }
    done.wait()
    return try! box.result!.get()
}

/// The result of `waitFor`, written by the detached task before it signals.
private final class LaunchResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
