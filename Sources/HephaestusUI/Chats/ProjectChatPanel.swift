// OWNER: ui-chats — the project chat panel of the inspector (docs/ui.md › Inspector; docs/chats.md › Where chats appear).
import AppKit
import HephaestusCore
import SwiftUI

/// The inspector: the picker of project chats, New Chat, Open in New Window and the selected chat's view or a draft (`ProjectViewState.inspectorChatID`, `inspectorShowsDraft`). It consumes `SectionCommand.focusInspectorComposer`.
struct ProjectChatPanel: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    @State private var draft: DraftChat?
    @State private var focusRequest = 0
    /// The chat the draft's first Send created, until its metadata arrives.
    @State private var createdChatID: String?
    @Environment(AppModel.self) private var app

    private var viewState: ProjectViewState {
        window.projectStates[ProjectKey(deviceID: workspace.deviceID, projectID: projectID)] ?? ProjectViewState()
    }

    /// The active project's chats of kind project, most recently updated first.
    private var projectChats: [ChatMeta] {
        workspace.chats(of: projectID).filter { $0.kind == .project }.sorted { $0.updated > $1.updated }
    }

    /// The shown chat: the selected one; without a selection, or when it was deleted, the most
    /// recently updated project chat; nil shows a draft.
    private var shownChatID: String? {
        let state = viewState
        if state.inspectorShowsDraft { return nil }
        if let chatID = state.inspectorChatID {
            if workspace.chats[chatID]?.kind == .project || chatID == createdChatID { return chatID }
        }
        return projectChats.first?.id.uuidString
    }

    var body: some View {
        let shown = shownChatID
        VStack(spacing: 0) {
            header(shown: shown)
            Divider()
            if let shown {
                ChatView(chatID: shown, workspace: workspace, showsHeader: false)
            } else if let draft, draft.projectID == projectID {
                ChatView(draft: draft, workspace: workspace, showsHeader: false, focusRequest: focusRequest,
                         focusesComposer: viewState.inspectorShowsDraft) { meta in
                    createdChatID = meta.id.uuidString
                    window.updateViewState(of: projectID) {
                        $0.inspectorChatID = meta.id.uuidString
                        $0.inspectorShowsDraft = false
                    }
                    self.draft = nil
                }
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: window.pendingSectionCommand, initial: true) { _, command in
            guard command == .focusInspectorComposer else { return }
            window.pendingSectionCommand = nil
            draft = DraftChat(projectID: projectID)
            focusRequest += 1
        }
        .onChange(of: "\(shown == nil) \(projectID)", initial: true) {
            if shownChatID == nil, draft?.projectID != projectID {
                draft = DraftChat(projectID: projectID)
            }
        }
        .onChange(of: workspace.chats[createdChatID ?? ""] != nil) { _, arrived in
            if arrived { createdChatID = nil }
        }
    }

    // MARK: Header

    private func header(shown: String?) -> some View {
        HStack(spacing: 8) {
            MenuButton(menu: { chatsMenu(shown: shown) }) {
                HStack(spacing: 5) {
                    if let shown, let meta = workspace.chats[shown] {
                        ChatStateMark(state: meta.state)
                            .frame(width: 12)
                        Text(meta.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text(ChatMeta.defaultTitle)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .accessibilityLabel("Project Chats")
            Spacer(minLength: 4)
            Button {
                window.newChat()
            } label: {
                Image(systemName: "plus.bubble")
            }
            .buttonStyle(.borderless)
            .help("New Chat")
            .accessibilityLabel("New Chat")
            Button {
                if let shown {
                    app.openChatWindow(ChatWindowValue(deviceID: workspace.deviceID, chatID: shown))
                }
            } label: {
                Image(systemName: "macwindow.badge.plus")
            }
            .buttonStyle(.borderless)
            .disabled(shown == nil)
            .help("Open in New Window")
            .accessibilityLabel("Open in New Window")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// The pop-up's menu: the project chats, each with its title and state indicator.
    private func chatsMenu(shown: String?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for meta in projectChats {
            let chatID = meta.id.uuidString
            let item = MenuItem(title: meta.title, checked: chatID == shown) {
                draft = nil
                window.updateViewState(of: projectID) {
                    $0.inspectorChatID = chatID
                    $0.inspectorShowsDraft = false
                }
            }
            item.image = Self.stateImage(meta.state)
            menu.addItem(item)
        }
        return menu
    }

    /// The state indicator of a menu item: none for idle, a spinner symbol for starting and
    /// running, an orange dot while waiting, a red dot for error.
    // DOC-GAP: docs/ui.md › Inspector shows the state indicator in a pop-up menu, where a spinner
    // cannot animate; the menu shows the `progress.indicator` symbol instead.
    static func stateImage(_ state: ChatState) -> NSImage? {
        let image: NSImage?
        switch state {
        case .idle:
            return nil
        case .starting, .running:
            image = NSImage(systemSymbolName: "progress.indicator", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil)
        case .waitingPermission, .waitingAnswers:
            image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange])))
        case .error:
            image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed])))
        }
        return image
    }
}
