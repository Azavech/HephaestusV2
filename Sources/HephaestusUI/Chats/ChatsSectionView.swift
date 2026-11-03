// OWNER: ui-chats — the Chats section (docs/chats.md › Where chats appear).
import AppKit
import HephaestusCore
import SwiftUI

/// The chats of the active project grouped by kind, and the selected chat's view, or `<n> Chats
/// Selected` with Close while several are selected (`ProjectViewState.selectedChatIDs`).
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

    /// The groups in the order Project, Ticket, Bundle, Feedback, each newest `updated` first,
    /// without the closed chats while the filter hides them; a group with no chat left is not
    /// shown (docs/chats.md › Where chats appear).
    private var groups: [(kind: ChatKind, chats: [ChatMeta])] {
        Self.groups(workspace.chats(of: projectID), hidesClosed: ChatListFilter.hidesClosedChats(in: window, projectID: projectID),
                    workspace: workspace)
    }

    static func groups(_ all: [ChatMeta], hidesClosed: Bool, workspace: DeviceWorkspace) -> [(kind: ChatKind, chats: [ChatMeta])] {
        let chats = hidesClosed ? all.filter { !workspace.isClosed($0) } : all
        return ChatKind.allCases.compactMap { kind in
            let members = chats.filter { $0.kind == kind }.sorted { $0.updated > $1.updated }
            return members.isEmpty ? nil : (kind, members)
        }
    }

    /// Chats in the order of the list: by kind in the order Project, Ticket, Bundle, Feedback, each
    /// newest `updated` first.
    static func inListOrder(_ chats: [ChatMeta]) -> [ChatMeta] {
        chats.sorted { a, b in
            let kindA = ChatKind.allCases.firstIndex(of: a.kind) ?? 0
            let kindB = ChatKind.allCases.firstIndex(of: b.kind) ?? 0
            if kindA != kindB { return kindA < kindB }
            if a.updated != b.updated { return a.updated > b.updated }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// A selection made in the list holds only the chats it lists (docs/chats.md › Where chats
    /// appear).
    static func listSelection(_ ids: Set<String>, listed: [ChatMeta]) -> Set<String> {
        ids.intersection(listed.map(\.id.uuidString))
    }

    /// The chats a context menu acts on: the listed chats among the menu's ids, in list order.
    static func menuChats(_ ids: Set<String>, listed: [ChatMeta]) -> [ChatMeta] {
        inListOrder(listed.filter { ids.contains($0.id.uuidString) })
    }

    private var selection: Set<String> {
        window.projectStates[ProjectKey(deviceID: workspace.deviceID, projectID: projectID)]?.selectedChatIDs ?? []
    }

    /// The selection the list shows: none while a draft is shown.
    private var listedSelection: Set<String> {
        draft == nil ? selection : []
    }

    private var listedChats: [ChatMeta] {
        groups.flatMap(\.chats)
    }

    var body: some View {
        Group {
            if workspace.chats(of: projectID).isEmpty, draft == nil, selection.isEmpty {
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
                if case .chatDeleted(let payload) = event.event, selection.contains(payload.chatID.uuidString) {
                    // A deleted chat leaves the selection (docs/chats.md › Where chats appear).
                    window.updateViewState(of: projectID) { $0.selectedChatIDs.remove(payload.chatID.uuidString) }
                }
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                ClosedChatsFilterButton(window: window, projectID: projectID)
                newChatButton
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if groups.isEmpty {
                // Every chat is closed and hidden by the filter (docs/chats.md › Where chats appear).
                VStack(spacing: 12) {
                    Text(ChatListFilter.noOpenChats)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    newChatButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chatList
            }
        }
        // The background of the Ticket list and the Bundles section (docs/chats.md › Where chats appear).
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var chatList: some View {
        // Click, ⌘-click and ⇧-click; ⌘A selects every listed chat (docs/chats.md › Where chats
        // appear).
        List(selection: Binding(get: { listedSelection }, set: select)) {
            ForEach(groups, id: \.kind) { group in
                // Titled with the kind's name, as the kind chip (docs/chats.md › Where chats appear).
                Section(ChatFormat.kindTitle(group.kind)) {
                    ForEach(group.chats) { meta in
                        row(meta)
                            .tag(meta.id.uuidString)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            // Delete… of a single selected chat; a selected chat whose row the filter hides is not
            // deleted from the list.
            guard press.modifiers.subtracting(.command).isEmpty, renamingChatID == nil, selection.count == 1,
                  let chatID = selection.first, let meta = listedChats.first(where: { $0.id.uuidString == chatID })
            else { return .ignored }
            ChatActions.confirmDelete(meta, workspace: workspace, window: windowReference.window, app: app)
            return .handled
        }
    }

    /// The context menu of the selected rows; right-clicking a row that is not selected selects it
    /// first. With several chats, Close is the only enabled item (docs/chats.md › Where chats
    /// appear).
    @ViewBuilder
    private func contextMenu(_ ids: Set<String>) -> some View {
        let chats = Self.menuChats(ids, listed: listedChats)
        if !chats.isEmpty {
            let _ = selectClickedRow(ids)
            let single = chats.count == 1 ? chats.first : nil
            Button("Open in New Window") {
                if let single {
                    app.openChatWindow(ChatWindowValue(deviceID: workspace.deviceID, chatID: single.id.uuidString))
                }
            }
            .disabled(single == nil)
            Button("Rename…") {
                if let single { startRename(single) }
            }
            .disabled(single == nil)
            Button("Close") {
                ChatActions.confirmClose(chats, workspace: workspace, window: windowReference.window, app: app)
            }
            .disabled(!ChatActions.canClose(chats))
            Button("Delete…") {
                if let single {
                    ChatActions.confirmDelete(single, workspace: workspace, window: windowReference.window, app: app)
                }
            }
            .disabled(single == nil)
        }
    }

    /// Selects the right-clicked row when it is not selected, once the menu opens.
    private func selectClickedRow(_ ids: Set<String>) {
        guard !ids.isSubset(of: listedSelection) else { return }
        DispatchQueue.main.async {
            select(ids)
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

    /// A selection made in the list; an empty one keeps the current selection, so that the area
    /// beside the list stays.
    private func select(_ ids: Set<String>) {
        let ids = Self.listSelection(ids, listed: listedChats)
        guard !ids.isEmpty else { return }
        draft = nil
        window.updateViewState(of: projectID) { $0.selectedChatIDs = ids }
    }

    /// Rename… of a row edits its title in place, as the chat view's title: Return renames, Escape
    /// and leaving the field cancel (docs/chats.md › Where chats appear, › Chat view).
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
                window.updateViewState(of: projectID) { $0.selectedChatIDs = [meta.id.uuidString] }
                self.draft = nil
            }
        } else if selection.count > 1 {
            severalSelected
        } else if let chatID = selection.first {
            // A chat whose metadata is not known yet (just created, or named by a navigation) is
            // loaded with `chats.get`, which shows the not-found text when it does not exist.
            if UUID(uuidString: chatID) != nil {
                ChatView(chatID: chatID, workspace: workspace)
            } else {
                NotFoundView(kind: "Chat", id: chatID)
            }
        } else {
            // Empty while no chat is selected (docs/chats.md › Where chats appear).
            Color(nsColor: .windowBackgroundColor)
        }
    }

    /// `<n> Chats Selected` and Close, which closes the selected chats (docs/chats.md › Where chats
    /// appear).
    private var severalSelected: some View {
        let chats = Self.inListOrder(selection.compactMap { workspace.chats[$0] })
        return VStack(spacing: 12) {
            Text("\(selection.count) Chats Selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Close") {
                ChatActions.confirmClose(chats, workspace: workspace, window: windowReference.window, app: app)
            }
            .disabled(!ChatActions.canClose(chats))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
