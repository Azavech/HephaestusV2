// OWNER: ui-shell — the app-level empty states: the welcome view, the reconnect view, the loading
// and failure states and the not-found text (docs/ui.md › Empty states).
import AppKit
import HephaestusCore
import SwiftUI

/// A spinner and a line, for example `Loading Studio…`.
struct LoadingStateView: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// `<project name> could not be loaded.`, the error's message and Try Again.
struct ProjectLoadFailedView: View {
    let projectName: String
    let error: EngineError
    let tryAgain: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("\(projectName) could not be loaded.")
                .font(.headline)
            Text(error.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Try Again", action: tryAgain)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The detail area of a section whose navigation target does not exist:
/// `<Kind> <id> was not found.` (docs/ui.md › Resolving a target). Section views show it while
/// their selection names an item that does not exist once the project is loaded.
struct NotFoundView: View {
    /// `Ticket`, `Bundle`, `Chat`, `Doc`, `File`, `Skill` or `Web tab`.
    let kind: String
    /// The target's id, path or name.
    let id: String

    var body: some View {
        Text("\(kind) \(id) was not found.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The welcome view of a device without projects (docs/ui.md › Welcome view).
struct WelcomeView: View {
    let window: WindowState
    let workspace: DeviceWorkspace

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to HephaestusV2")
                .font(.title)
            Text(line)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("New Project…") {
                    window.sheet = .newProject
                }
                .buttonStyle(.borderedProminent)
                Button("Open Project…") {
                    ProjectFlows.openProject(window: window, workspace: workspace)
                }
            }
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var line: String {
        if workspace.isLocal {
            return "Create a project or open a folder that contains .hephaestus/project.yml."
        }
        let name = workspace.deviceName
        return "\(name) has no projects yet. Create one or open a folder on \(name)."
    }
}

/// The reconnect view of a window whose remote device is not connected (docs/ui.md › Reconnect
/// view). `window` is nil in a chat window, which has no Show This Mac.
struct ReconnectView: View {
    let workspace: DeviceWorkspace
    let window: WindowState?

    var body: some View {
        let device = DeviceStatePresentation(workspace: workspace)
        let name = workspace.deviceName
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            DeviceStateLabel(presentation: device)
            switch reconnectState {
            case .connecting:
                titleWithSpinner("Connecting to \(name)…")
                buttons(reconnect: false, pairing: false)
            case .reconnectingWhileConnecting:
                titleWithSpinner("Reconnecting to \(name)…")
                if let message = workspace.lastFailureMessage {
                    detail(message)
                }
                buttons(reconnect: false, pairing: false)
            case .waiting(let message, let nextAttempt):
                Text("\(name) is not connected")
                    .font(.title2)
                detail(message)
                if let nextAttempt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(nextAttempt.timeIntervalSince(context.date).rounded(.up)))
                        detail("Retrying in \(seconds) s.")
                    }
                }
                buttons(reconnect: true, pairing: false)
            case .offline(let message):
                Text("\(name) is offline")
                    .font(.title2)
                detail(message)
                buttons(reconnect: true, pairing: false)
            case .needsPairing(let message):
                Text("\(name) needs its pairing code")
                    .font(.title2)
                detail(message)
                buttons(reconnect: false, pairing: true)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private enum ReconnectState {
        case connecting
        case reconnectingWhileConnecting
        case waiting(message: String, nextAttempt: Date?)
        case offline(message: String)
        case needsPairing(message: String)
    }

    /// The rows of the reconnect view's table.
    private var reconnectState: ReconnectState {
        switch workspace.phase {
        case .waiting(let message, let nextAttempt)?:
            return .waiting(message: message, nextAttempt: nextAttempt)
        case .needsPairing(let message)?:
            return .needsPairing(message: message)
        case .sameDevice(let message)?, .replaced(let message)?:
            return .offline(message: message)
        case .closed?:
            return .offline(message: LocalEngineConnection.closedReason)
        case .connecting?, .helloSent?, .authSent?, .connected?, nil:
            return workspace.hasConnected ? .reconnectingWhileConnecting : .connecting
        }
    }

    private func titleWithSpinner(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.title2)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func buttons(reconnect: Bool, pairing: Bool) -> some View {
        HStack(spacing: 12) {
            if reconnect {
                Button("Reconnect Now") {
                    workspace.reconnectNow()
                }
            }
            // Main windows only: a chat window has no Add Device sheet (docs/ui.md › Reconnect view).
            if pairing, let window {
                Button("Enter Pairing Code…") {
                    window.sheet = .addDevice(deviceID: workspace.deviceID)
                }
            }
            if let window, let app = window.app {
                Button("Show This Mac") {
                    window.switchDevice(to: app.localDeviceID)
                }
            }
        }
        .padding(.top, 6)
    }
}
