// OWNER: ui-chats — the Chats section (docs/chats.md › Where chats appear).
import AppKit
import HephaestusCore
import SwiftUI

/// The chats of the active project grouped by kind, and the selected chat's view (`ProjectViewState.selectedChatID`).
struct ChatsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    /// The draft project chat shown by New Chat; discarded when another chat is selected.
    @State private var draft: DraftChat?
    @State private var renamingChatID: String?
    @State private var renameText = ""
    @State private var windowReference = ChatWindowReference()
    @FocusState private var renameFocused: Bool
    @Environment(AppModel.self) private var app

    /// The groups in the order Project, Ticket, Bundle, Feedback, each newest `updated` first.
    private var groups: [(kind: ChatKind, chats: [ChatMeta])] {
        let chats = workspace.chats(of: projectID)
        return ChatKind.allCases.compactMap { kind in
            let members = chats.filter { $0.kind == kind }.sorted { $0.updated > $1.updated }
            return members.isEmpty ? nil : (kind, members)
        }
    }

    private var selectedChatID: String? {
        window.projectStates[ProjectKey(deviceID: workspace.deviceID, projectID: projectID)]?.selectedChatID
    }

    var body: some View {
        Group {
            if groups.isEmpty, draft == nil, selectedChatID == nil {
                VStack(spacing: 12) {
                    Text("No chats yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    newChatButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    list
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 420, maxHeight: .infinity)
                    detail
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(ChatWindowReader(reference: windowReference))
        .task(id: ObjectIdentifier(workspace)) {
            for await event in workspace.events() {
                if case .chatDeleted(let payload) = event.event, payload.chatID.uuidString == selectedChatID {
                    // DOC-GAP: docs/chats.md › Where chats appear names no fallback when the selected
                    // chat is deleted; the section clears its selection.
                    window.updateViewState(of: projectID) { $0.selectedChatID = nil }
                }
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                newChatButton
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            List(selection: Binding(get: { draft == nil ? selectedChatID : nil }, set: select)) {
                ForEach(groups, id: \.kind) { group in
                    Section(ChatFormat.kindTitle(group.kind)) {
                        ForEach(group.chats) { meta in
                            row(meta)
                                .tag(meta.id.uuidString)
                                .contextMenu {
                                    Button("Open in New Window") {
                                        app.openChatWindow(ChatWindowValue(deviceID: workspace.deviceID, chatID: meta.id.uuidString))
                                    }
                                    Button("Rename…") {
                                        startRename(meta)
                                    }
                                    Button("Delete…") {
                                        ChatActions.confirmDelete(meta, workspace: workspace, window: windowReference.window, app: app)
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onKeyPress(keys: [.delete], phases: .down) { press in
                guard press.modifiers.subtracting(.command).isEmpty, renamingChatID == nil,
                      let chatID = selectedChatID, let meta = workspace.chats[chatID] else { return .ignored }
                ChatActions.confirmDelete(meta, workspace: workspace, window: windowReference.window, app: app)
                return .handled
            }
        }
    }

    /// A row: the title, the linked ticket or bundle id, a state mark and the relative `updated`
    /// time.
    private func row(_ meta: ChatMeta) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if renamingChatID == meta.id.uuidString {
                    TextField("", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFocused)
                        .onSubmit {
                            renamingChatID = nil
                            ChatActions.rename(meta, to: renameText, workspace: workspace, window: windowReference.window, app: app)
                        }
                        .onExitCommand {
                            renamingChatID = nil
                        }
                        .onAppear {
                            renameFocused = true
                        }
                        .onChange(of: renameFocused) { _, focused in
                            if !focused { renamingChatID = nil }
                        }
                } else {
                    Text(meta.title)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let linked = meta.bundleID ?? meta.ticketID {
                        Text(linked)
                            .font(.system(.caption, design: .monospaced))
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(Self.relative(meta.updated, now: context.date))
                    }
                    .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            ChatStateMark(state: meta.state)
                .frame(width: 12)
        }
        .padding(.vertical, 2)
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    private var newChatButton: some View {
        Button {
            draft = DraftChat(projectID: projectID)
        } label: {
            Label("New Chat", systemImage: "plus.bubble")
        }
    }

    private func select(_ chatID: String?) {
        guard let chatID else { return }
        draft = nil
        window.updateViewState(of: projectID) { $0.selectedChatID = chatID }
    }

    private func startRename(_ meta: ChatMeta) {
        renameText = meta.title
        renamingChatID = meta.id.uuidString
        renameFocused = true
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let draft {
            ChatView(draft: draft, workspace: workspace) { meta in
                window.updateViewState(of: projectID) { $0.selectedChatID = meta.id.uuidString }
                self.draft = nil
            }
        } else if let chatID = selectedChatID {
            // A chat whose metadata is not known yet (just created, or named by a navigation) is
            // loaded with `chats.get`, which shows the not-found text when it does not exist.
            if UUID(uuidString: chatID) != nil {
                ChatView(chatID: chatID, workspace: workspace)
            } else {
                NotFoundView(kind: "Chat", id: chatID)
            }
        } else {
            // DOC-GAP: docs/chats.md › Where chats appear gives no content for the chat view while
            // no chat is selected; it stays empty.
            Color(nsColor: .windowBackgroundColor)
        }
    }
}
