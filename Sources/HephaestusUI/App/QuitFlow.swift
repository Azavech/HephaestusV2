// OWNER: ui-shell — quitting: the quit checks, the restart checks' seam and the shutdown
// (docs/ui.md › Unsaved changes and quitting; docs/architecture.md › Shutdown; docs/updater.md ›
// Restart rules).
import AppKit
import Foundation
import HephaestusCore

extension AppModel {
    /// `applicationShouldTerminate`: Quit (⌘Q) runs the quit checks, then the shutdown; SIGTERM,
    /// SIGINT and a restart for an update skip the confirmations.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateLater }
        if skipsQuitConfirmations {
            beginShutdown()
            return .terminateLater
        }
        guard !quitChecksPending else { return .terminateLater }
        quitChecksPending = true
        Task {
            let confirmed = await runQuitChecks(restartVersion: nil)
            quitChecksPending = false
            // A SIGTERM or SIGINT received during the checks ends their alerts and quits anyway.
            if confirmed || skipsQuitConfirmations {
                beginShutdown()
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    /// SIGTERM and SIGINT are handled like Quit without its confirmation alerts: every open sheet
    /// and modal alert is ended first (each counts as cancelled), since AppKit does not terminate
    /// while a window shows a sheet. A Quit whose checks are running goes on to the shutdown.
    func terminateWithoutConfirmation() {
        skipsQuitConfirmations = true
        endModalUI()
        guard !quitChecksPending else { return }
        requestTermination()
    }

    /// Ends the app-modal session and every sheet, the innermost first.
    private func endModalUI() {
        if NSApp.modalWindow != nil {
            NSApp.abortModal()
        }
        for _ in 0..<8 {
            let parents = NSApp.windows.filter { $0.attachedSheet != nil && $0.attachedSheet?.attachedSheet == nil }
            guard !parents.isEmpty else { return }
            for window in parents {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort)
                }
            }
        }
    }

    /// Calls `NSApp.terminate` from a run loop block. Called from a main-queue job (a signal
    /// source, a task), `terminate` would run AppKit's `terminateLater` loop inside that job, where
    /// the main queue, and so the main actor's shutdown task, can never run.
    private func requestTermination() {
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
    }

    /// The checks of quitting, in order: unsaved editors of every window, then running work, then
    /// the savers of changed ticket descriptions (at most 5 seconds). Returns false when the user
    /// cancels or a save fails. With `restartVersion` (for example `v0.5.0(61)`), the running work
    /// alert is the restart alert of docs/updater.md › Restart rules.
    func runQuitChecks(restartVersion: String?) async -> Bool {
        let frontWindow = frontmostAppWindow
        let editors = mainWindowsByKeyOrder.flatMap { $0.unsavedEditors() }
        guard await UnsavedChangesPrompt.confirm(editors, sheetOn: frontWindow) else { return false }

        let chats = localWorkspace.chats.values.filter { [.starting, .running, .waitingPermission].contains($0.state) }.count
        let runs = localWorkspace.runs.values.filter(\.isRunning).count
        if chats + runs > 0 {
            let alert = NSAlert()
            if let restartVersion {
                alert.messageText = "Restart to install \(restartVersion)?"
                alert.addButton(withTitle: "Restart")
            } else {
                alert.messageText = "Quit HephaestusV2?"
                alert.addButton(withTitle: "Quit")
            }
            alert.informativeText = Self.runningWorkMessage(chats: chats, runs: runs)
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            guard await AlertPresenter.present(alert, on: frontWindow) == .alertFirstButtonReturn else { return false }
        }
        return await runQuitSavers()
    }

    /// `<chats> and <runs> on This Mac will be stopped.`, a part whose count is 0 left out together
    /// with `and`.
    static func runningWorkMessage(chats: Int, runs: Int) -> String {
        var parts: [String] = []
        if chats > 0 { parts.append(chats == 1 ? "1 chat" : "\(chats) chats") }
        if runs > 0 { parts.append(runs == 1 ? "1 run" : "\(runs) runs") }
        return parts.joined(separator: " and ") + " on This Mac will be stopped."
    }

    /// Runs the quit savers and waits for them at most 5 seconds; a failure cancels the quit (the
    /// saver shows its error).
    private func runQuitSavers() async -> Bool {
        let savers = Array(quitSavers.values)
        guard !savers.isEmpty else { return true }
        return await withTaskGroup(of: Bool?.self) { group in
            for saver in savers {
                group.addTask { @MainActor in
                    do {
                        try await saver()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            var finished = 0
            for await result in group {
                switch result {
                case .some(false):
                    group.cancelAll()
                    return false
                case .some(true):
                    finished += 1
                    if finished == savers.count {
                        group.cancelAll()
                        return true
                    }
                case .none:
                    group.cancelAll()
                    return true
                }
            }
            return true
        }
    }

    /// docs/architecture.md › Shutdown: closes the remote connections, shuts the engine down (child
    /// processes, servers, Bonjour, file watching, engine.log, the lock), tells the Updater that the
    /// app quits, then lets AppKit terminate with status 0.
    // DOC-GAP: docs/architecture.md › Shutdown tells the Updater (step 4) between the servers
    // (step 3) and engine.log (step 5), but `Engine.shutdown()` runs steps 1 to 3 and 5 together;
    // `app.quitting` is posted right after it.
    func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let activate = NSApp.isActive
        Task {
            for workspace in workspaces.values where !workspace.isLocal {
                workspace.close()
            }
            await engine.shutdown()
            if !appQuittingPosted {
                updateController.appWillQuit(restart: false, activate: activate)
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// The restart sequence's first step (docs/updater.md › Restart for an update): writes the
    /// persisted `WindowState` of every main window and the `ChatWindowValue` of every chat window,
    /// front to back, to `windowsAtRestart`.
    func saveWindowsForRestart() {
        guard persistsWindowState else { return }
        let ordered = NSApp.windows.filter(\.isVisible).sorted { $0.orderedIndex < $1.orderedIndex }
        var records: [RestartWindowRecord] = []
        for window in ordered {
            switch windowRegistry.role(of: window) {
            case .main(let id):
                if let json = windows[id]?.persistedJSON {
                    records.append(RestartWindowRecord(main: json))
                }
            case .chat(let value):
                records.append(RestartWindowRecord(chat: value))
            default:
                break
            }
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.windowsAtRestartDefaultsKey)
        }
    }

    /// Terminates for a restart once the Updater answered `installing`: the checks already ran and
    /// `app.quitting` was posted with `restart` true, once per termination
    /// (docs/updater.md › Restart for an update).
    func terminateForRestart() {
        skipsQuitConfirmations = true
        appQuittingPosted = true
        requestTermination()
    }

    /// The window an app-level alert attaches to: the key window, else the frontmost visible one.
    var frontmostAppWindow: NSWindow? {
        if let key = NSApp.keyWindow { return key }
        return NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }.min { $0.orderedIndex < $1.orderedIndex }
    }
}
