// OWNER: ui-tickets — the Chats tab of a ticket and of a bundle: Implement or Implement All, New Chat,
// the list of linked chats and the selected chat's view (docs/tickets.md › Ticket chats and
// Implement, › Bundles section, › Implement All).
import AppKit
import HephaestusCore
import SwiftUI

/// The ticket or bundle a Chats tab belongs to.
enum LinkedChatsOwner: Hashable {
    case ticket(String)
    case bundle(String)

    var id: String {
        switch self {
        case .ticket(let id), .bundle(let id): return id
        }
    }

    var kind: ChatKind {
        switch self {
        case .ticket: return .ticket
        case .bundle: return .bundle
        }
    }
}

/// The Chats tab: a bar with Implement (or Implement All) and New Chat, the chats listed in the
/// ticket's or bundle's `chats` newest first, and the selected chat's view or a draft under it.
struct LinkedChatsView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let owner: LinkedChatsOwner
    let chatIDs: [ChatID]

    @State private var renamingID: String?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    /// The identity of the draft chat view: each New Chat shows a new draft.
    @State private var draftIdentity = UUID()

    private var viewState: ProjectViewState {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)] ?? ProjectViewState()
    }

    /// Selects a chat of this tab, or shows its draft when `chatID` is nil.
    private func select(_ chatID: String?, draft: Bool) {
        Self.select(chatID, draft: draft, owner: owner, window: window, projectID: projectID)
    }

    /// Sets the chat of a Chats tab (`chatsTabSelection`) and whether it shows a draft
    /// (`chatsTabDrafts`); the tab shows the chat's view, not one of its workflows or agents.
    static func select(_ chatID: String?, draft: Bool, owner: LinkedChatsOwner, window: WindowState, projectID: String) {
        window.updateViewState(of: projectID) { state in
            state.chatsTabAgentSelection[owner.id] = nil
            if let chatID {
                state.chatsTabSelection[owner.id] = chatID
            } else if !draft {
                state.chatsTabSelection[owner.id] = nil
            }
            if draft {
                state.chatsTabDrafts.insert(owner.id)
            } else {
                state.chatsTabDrafts.remove(owner.id)
            }
        }
    }

    /// A row of the list: a chat, indented when the chat of a row above it orchestrates it: a
    /// ticket chat under its bundle chat, a CI chat under the chat that started it.
    struct Row: Identifiable, Hashable {
        var meta: ChatMeta
        var nested: Bool
        var id: String { meta.id.uuidString }
    }

    /// The listed rows: the chats of `chatIDs` that have metadata, most recently updated first,
    /// each followed by the chats it orchestrates, oldest first: the ticket chats of a bundle chat
    /// and the CI chats of a ticket or bundle chat, whether or not their ids are in `chatIDs`
    /// (docs/tickets.md › Ticket chats and Implement, › Bundles section). A chat id without
    /// metadata (another clone of the repository) is not listed. With `hidesClosed`, closed chats
    /// are left out, except a chat that orchestrates an open chat (docs/tickets.md › Implement
    /// All).
    static func listedRows(_ chatIDs: [ChatID], workspace: DeviceWorkspace, hidesClosed: Bool = false) -> [Row] {
        let linked = chatIDs.compactMap { workspace.chats[$0.uuidString] }
        let listed = Set(linked.map(\.id))
        var children: [ChatID: [ChatMeta]] = [:]
        for meta in workspace.chats.values {
            if let orchestrator = meta.orchestratorChatID, orchestrator != meta.id, listed.contains(orchestrator) {
                children[orchestrator, default: []].append(meta)
            }
        }
        let nestedIDs = Set(children.values.flatMap { $0.map(\.id) })
        let chats = linked.filter { !nestedIDs.contains($0.id) }.sorted { $0.updated > $1.updated }
        return chats.flatMap { meta -> [Row] in
            let nested = (children[meta.id] ?? [])
                .filter { !hidesClosed || !workspace.isClosed($0) }
                .sorted { $0.created < $1.created }
            guard !hidesClosed || !workspace.isClosed(meta) || !nested.isEmpty else { return [] }
            return [Row(meta: meta, nested: false)] + nested.map { Row(meta: $0, nested: true) }
        }
    }

    /// The listed chats, in the order of `listedRows`.
    static func listedChats(_ chatIDs: [ChatID], workspace: DeviceWorkspace, hidesClosed: Bool = false) -> [ChatMeta] {
        listedRows(chatIDs, workspace: workspace, hidesClosed: hidesClosed).map(\.meta)
    }

    /// Opening the tab selects the most recently updated chat of the list.
    static func selectMostRecent(owner: LinkedChatsOwner, chatIDs: [ChatID], workspace: DeviceWorkspace, window: WindowState,
                                 projectID: String) {
        let hidesClosed = ChatListFilter.hidesClosedChats(in: window, projectID: projectID)
        select(listedChats(chatIDs, workspace: workspace, hidesClosed: hidesClosed).first?.id.uuidString, draft: false, owner: owner,
               window: window, projectID: projectID)
    }

    /// The chat shown under the list: the stored selection while it is listed or is a chat of this
    /// ticket or bundle whose link has not arrived yet, otherwise the most recently updated chat.
    private func selectedChatID(_ chats: [ChatMeta]) -> String? {
        if let stored = viewState.chatsTabSelection[owner.id] {
            if chats.contains(where: { $0.id.uuidString == stored }) {
                return stored
            }
            if let meta = workspace.chats[stored], linkedID(of: meta) == owner.id || isOrchestrated(meta) {
                return stored
            }
        }
        return chats.first?.id.uuidString
    }

    private func linkedID(of meta: ChatMeta) -> String? {
        switch owner {
        case .ticket: return meta.ticketID
        case .bundle: return meta.bundleID
        }
    }

    /// A chat orchestrated by a chat of this tab, a ticket chat or a CI chat, whose row has not
    /// arrived yet.
    private func isOrchestrated(_ meta: ChatMeta) -> Bool {
        guard let orchestrator = meta.orchestratorChatID else { return false }
        return chatIDs.contains(orchestrator)
    }

    private var showsDraft: Bool {
        viewState.chatsTabDrafts.contains(owner.id)
    }

    /// The workflow or agent of the selected chat shown in place of its view (docs/tickets.md ›
    /// Ticket chats and Implement).
    private func selectedAgent(_ chats: [ChatMeta]) -> ChatAgentSelection? {
        guard !showsDraft, let selection = viewState.chatsTabAgentSelection[owner.id],
              selection.chatID == selectedChatID(chats) else { return nil }
        return selection
    }

    /// Shows a workflow or an agent of a chat of this tab in place of the chat view.
    private func selectAgent(_ selection: ChatAgentSelection) {
        window.updateViewState(of: projectID) { state in
            state.chatsTabSelection[owner.id] = selection.chatID
            state.chatsTabAgentSelection[owner.id] = selection
            state.chatsTabDrafts.remove(owner.id)
        }
    }

    /// The rows of the list: each listed chat followed by the rows of its workflows and agents,
    /// indented with it when it is an orchestrated ticket chat.
    private func listRows(_ rows: [Row]) -> [(row: ChatListRow, nested: Bool)] {
        rows.flatMap { listed in
            [(ChatListRow.chat(listed.meta), listed.nested)] + agentRows(listed.meta).map { (ChatListRow.agent($0), listed.nested) }
        }
    }

    /// The rows of a chat's workflows and agents: the running ones, and the ended ones while the
    /// chat is unfolded (docs/chats.md › Where chats appear).
    private func agentRows(_ meta: ChatMeta) -> [ChatAgentRow] {
        let chatID = meta.id.uuidString
        return ChatAgentRows.rows(workspace.agents[chatID], expanded: ChatAgentRows.isExpanded(chatID, window: window, projectID: projectID))
    }

    var body: some View {
        let chats = Self.listedRows(chatIDs, workspace: workspace,
                                    hidesClosed: ChatListFilter.hidesClosedChats(in: window, projectID: projectID))
        Group {
            if Self.listedRows(chatIDs, workspace: workspace).isEmpty && !showsDraft {
                emptyState
            } else {
                VStack(spacing: 0) {
                    bar
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    Divider()
                    VSplitView {
                        // One pane whatever its content, so that the chat view under it is kept.
                        ZStack {
                            if chats.isEmpty {
                                noOpenChats
                            } else {
                                list(chats)
                            }
                        }
                        .frame(minHeight: 60, idealHeight: 120, maxHeight: 320)
                        selected(chats)
                            .frame(minHeight: 220, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 8) {
            implementButton
            newChatButton
            Spacer()
            ClosedChatsFilterButton(window: window, projectID: projectID)
        }
    }

    @ViewBuilder
    private var implementButton: some View {
        switch owner {
        case .ticket(let ticketID):
            let ticket = workspace.tickets[projectID]?[ticketID]
            let availability = ticket.map { TicketActions.implementAvailability(of: $0, workspace: workspace) } ?? (enabled: false, help: nil)
            Button("Implement") {
                Task { await TicketActions.implement(ticketID: ticketID, workspace: workspace, window: window) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!availability.enabled || !window.isConnected)
            .help(availability.help ?? "")
        case .bundle(let bundleID):
            let bundle = workspace.bundles[projectID]?[bundleID]
            let availability = bundle.map { TicketActions.implementAllAvailability(of: $0, workspace: workspace, projectID: projectID) } ?? (enabled: false, help: nil)
            Button("Implement All") {
                TicketActions.implementAll(bundleID: bundleID, window: window)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!availability.enabled || !window.isConnected)
            .help(availability.help ?? "")
        }
    }

    private var newChatButton: some View {
        Button("New Chat") {
            draftIdentity = UUID()
            select(nil, draft: true)
        }
        .disabled(!window.isConnected)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No Chats")
                .font(.title3.weight(.semibold))
            // docs/tickets.md › Ticket chats and Implement, › Bundles section (Chats tab).
            Text(owner.kind == .ticket
                 ? "Implement lets Claude implement this ticket. New Chat opens a conversation about it."
                 : "Implement All lets Claude implement this bundle. New Chat opens a conversation about it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 8) {
                implementButton
                newChatButton
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The list area while the filter hides every chat of the ticket or bundle (docs/tickets.md ›
    /// Ticket chats and Implement).
    private var noOpenChats: some View {
        VStack(spacing: 10) {
            Text(ChatListFilter.noOpenChats)
                .font(.title3)
                .foregroundStyle(.secondary)
            newChatButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private func list(_ rows: [Row]) -> some View {
        let chats = rows.map(\.meta)
        let selectedID = showsDraft ? nil : (selectedAgent(chats)?.tag ?? selectedChatID(chats))
        return List(selection: Binding<String?>(
            get: { selectedID },
            set: { id in
                guard let id else { return }
                if let agent = ChatAgentSelection(tag: id) {
                    selectAgent(agent)
                } else {
                    select(id, draft: false)
                }
            }
        )) {
            // Each chat followed by its workflows and agents (docs/chats.md › Where chats appear),
            // one row per element.
            ForEach(listRows(rows), id: \.row.id) { entry in
                switch entry.row {
                case .chat(let meta):
                    row(meta)
                        .padding(.leading, entry.nested ? 22 : 0)
                        .contextMenu {
                            Button("Open in New Window") {
                                window.app?.openChatWindow(ChatWindowValue(deviceID: workspace.deviceID, chatID: meta.id.uuidString))
                            }
                            Button("Rename…") {
                                renameText = meta.title
                                renamingID = meta.id.uuidString
                                DispatchQueue.main.async { renameFocused = true }
                            }
                            .disabled(!window.isConnected)
                            Button("Close") { close(meta) }
                                .disabled(!window.isConnected || !ChatActions.canClose([meta]))
                            Divider()
                            Button("Delete…") { delete(meta) }
                                .disabled(!window.isConnected)
                        }
                        .tag(entry.row.id)
                case .agent(let agentRow):
                    ChatAgentRowView(row: agentRow)
                        .padding(.leading, entry.nested ? 22 : 0)
                        .chatAgentRowMenu(agentRow, workspace: workspace, window: window)
                        .tag(entry.row.id)
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ meta: ChatMeta) -> some View {
        HStack(spacing: 8) {
            if ChatAgentRows.hasEndedRows(workspace.agents[meta.id.uuidString]) {
                ChatAgentsDisclosure(chatID: meta.id.uuidString, window: window, projectID: projectID)
            }
            Image(systemName: Self.kindSymbol(meta.kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if renamingID == meta.id.uuidString {
                TextField("Title", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { rename(meta) }
                    .onExitCommand { renamingID = nil }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { renamingID = nil }
                    }
            } else {
                Text(meta.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            ChatStateMark(state: meta.state)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(TicketFormat.relative(meta.updated, now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The kind icons of the list.
    static func kindSymbol(_ kind: ChatKind) -> String {
        switch kind {
        case .project: return "bubble.left.and.bubble.right"
        case .ticket: return "checklist"
        case .bundle: return "shippingbox"
        case .feedback: return "ladybug"
        case .ci: return "checkmark.seal"
        }
    }

    // MARK: Selected chat

    @ViewBuilder
    private func selected(_ rows: [Row]) -> some View {
        let chats = rows.map(\.meta)
        if showsDraft {
            ChatDraftView(projectID: projectID, kind: owner.kind,
                          ticketID: owner.kind == .ticket ? owner.id : nil,
                          bundleID: owner.kind == .bundle ? owner.id : nil,
                          workspace: workspace) { chatID in
                // The new chat replaces the draft and is selected.
                select(chatID.uuidString, draft: false)
            }
            .id(draftIdentity)
        } else if let agent = selectedAgent(chats) {
            ChatAgentDetailView(selection: agent, workspace: workspace, window: window, select: selectAgent)
        } else if let chatID = selectedChatID(chats) {
            ChatView(chatID: chatID, workspace: workspace)
                .id(chatID)
                .task(id: chatID) {
                    // A chat shown without a stored selection becomes the selection, so that its
                    // view stays when the filter hides it (docs/tickets.md › Ticket chats and
                    // Implement).
                    if viewState.chatsTabSelection[owner.id] == nil {
                        select(chatID, draft: false)
                    }
                }
        } else {
            Color.clear
        }
    }

    // MARK: Actions

    private func rename(_ meta: ChatMeta) {
        let title = renameText
        renamingID = nil
        guard title.trimmingCharacters(in: .whitespacesAndNewlines) != meta.title else { return }
        Task {
            do {
                _ = try await workspace.call(ChatsRename.self, ChatsRename.Params(chatID: meta.id, title: title))
            } catch {
                window.alert = .failure("Rename", error)
            }
        }
    }

    /// Close: `Close the chat “<title>”?`, then `chats.close` (docs/chats.md › Closing a chat).
    private func close(_ meta: ChatMeta) {
        guard let app = window.app else { return }
        ChatActions.confirmClose([meta], workspace: workspace, window: TicketActions.nsWindow(window), app: app)
    }

    /// Delete…: `Delete the chat “<title>”?` with `Its transcript and attachments are moved to the
    /// Trash.` (docs/chats.md › Chat view), then `chats.delete`.
    private func delete(_ meta: ChatMeta) {
        Task {
            guard await TicketActions.confirm("Delete the chat “\(meta.title)”?",
                                              message: "Its transcript and attachments are moved to the Trash.",
                                              button: "Delete", in: window)
            else { return }
            do {
                _ = try await workspace.call(ChatsDelete.self, ChatsDelete.Params(chatID: meta.id))
            } catch {
                window.alert = .failure("Delete", error)
            }
        }
    }
}
