// OWNER: ui-tickets — the Implement sheet of Implement and Implement All (docs/tickets.md ›
// Implement sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// Implement or Implement All: the composer's Model, Effort, Context and Permissions menus over the
/// settings of the chat to start, opened on the project's `chatDefaults`, else the host's
/// `defaultChatSettings`; Start creates the chat with them.
struct ImplementSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    /// The ticket that Implement starts, or the bundle that Implement All starts.
    let owner: LinkedChatsOwner
    @Environment(\.dismiss) private var dismiss

    /// The settings chosen in the sheet; nil until a menu changes them.
    @State private var chosen: ChatSettings?
    @State private var isStarting = false
    /// The error of the last Start.
    @State private var failure: String?

    static let bundleNote = "The ticket chats that the bundle chat starts take its settings."

    private var projectID: String {
        Identifiers.projectID(of: owner.id) ?? ""
    }

    private var settings: ChatSettings {
        chosen ?? workspace.defaultChatSettings(of: projectID)
    }

    private var title: String {
        switch owner {
        case .ticket(let ticketID): return "Implement \(ticketID)"
        case .bundle(let bundleID): return "Implement All \(bundleID)"
        }
    }

    private var subtitle: String? {
        switch owner {
        case .ticket(let ticketID): return workspace.tickets[projectID]?[ticketID]?.title
        case .bundle(let bundleID): return workspace.bundles[projectID]?[bundleID]?.title
        }
    }

    private var canStart: Bool {
        !isStarting && window.isConnected && workspace.claudeStatus?.available == true
    }

    var body: some View {
        let menus = ChatSettingsMenus(settings: settings, models: workspace.models) { chosen = $0 }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(subtitle)
                }
            }
            HStack(spacing: 8) {
                ChatModelMenuButton(menus: menus)
                    .fixedSize()
                ChatEffortMenuButton(menus: menus)
                    .fixedSize()
                ChatContextMenuButton(menus: menus)
                    .fixedSize()
                ChatPermissionsMenuButton(menus: menus)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            if case .bundle = owner {
                Text(Self.bundleNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                ValidationMessage(text: failure)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    start()
                } label: {
                    if isStarting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Start")
                        }
                    } else {
                        Text("Start")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 440)
        .disabled(isStarting)
    }

    /// Start: the chat is created with the chosen settings; the sheet closes on success and keeps
    /// the choice with the error on failure.
    private func start() {
        guard canStart else { return }
        isStarting = true
        failure = nil
        let settings = settings
        Task {
            do {
                try await TicketActions.start(owner, settings: settings, workspace: workspace, window: window)
                dismiss()
            } catch {
                failure = errorMessage(error)
                isStarting = false
            }
        }
    }
}
