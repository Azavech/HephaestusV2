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

    private var store: TicketWindowStore {
        TicketWindowStore.store(for: window)
    }

    private var key: String {
        TicketWindowStore.key(workspace.deviceID, owner.id)
    }

    /// The listed chats: ids with chat metadata, most recently updated first. A chat id without
    /// metadata (another clone of the repository) is not listed.
    static func listedChats(_ chatIDs: [ChatID], workspace: DeviceWorkspace) -> [ChatMeta] {
        chatIDs.compactMap { workspace.chats[$0.uuidString] }.sorted { $0.updated > $1.updated }
    }

    /// Opening the tab selects the most recently updated chat.
    static func selectMostRecent(owner: LinkedChatsOwner, chatIDs: [ChatID], workspace: DeviceWorkspace, window: WindowState) {
        let store = TicketWindowStore.store(for: window)
        let key = TicketWindowStore.key(workspace.deviceID, owner.id)
        store.chatSelection[key] = listedChats(chatIDs, workspace: workspace).first?.id.uuidString
        store.draftChats.remove(key)
    }

    /// The chat shown under the list: the stored selection while it is listed or is a chat of this
    /// ticket or bundle whose link has not arrived yet, otherwise the most recently updated chat.
    private func selectedChatID(_ chats: [ChatMeta]) -> String? {
        if let stored = store.chatSelection[key] {
            if chats.contains(where: { $0.id.uuidString == stored }) {
                return stored
            }
            if let meta = workspace.chats[stored], linkedID(of: meta) == owner.id {
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

    private var showsDraft: Bool {
        store.draftChats.contains(key)
    }

    var body: some View {
        let chats = Self.listedChats(chatIDs, workspace: workspace)
        Group {
            if chats.isEmpty && !showsDraft {
                emptyState
            } else {
                VStack(spacing: 0) {
                    bar
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    Divider()
                    VSplitView {
                        list(chats)
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
                Task { await TicketActions.implementAll(bundleID: bundleID, workspace: workspace, window: window) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!availability.enabled || !window.isConnected)
            .help(availability.help ?? "")
        }
    }

    private var newChatButton: some View {
        Button("New Chat") {
            store.draftChats.insert(key)
        }
        .disabled(!window.isConnected)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No Chats")
                .font(.title3.weight(.semibold))
            // DOC-GAP: docs/tickets.md › Bundles section gives the bundle's Chats tab the ticket's
            // empty state "with Implement All in place of Implement"; its text is adapted the same
            // way.
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

    // MARK: List

    private func list(_ chats: [ChatMeta]) -> some View {
        let selectedID = showsDraft ? nil : selectedChatID(chats)
        return List(selection: Binding<String?>(
            get: { selectedID },
            set: { id in
                guard let id else { return }
                store.chatSelection[key] = id
                store.draftChats.remove(key)
            }
        )) {
            ForEach(chats) { meta in
                row(meta)
                    .tag(meta.id.uuidString)
                    .contextMenu {
                        Button("Open in New Window") {
                            window.app?.openChatWindow(ChatWindowValue(deviceID: workspace.deviceID, chatID: meta.id.uuidString))
                        }
                        Button("Rename…") {
                            renameText = meta.title
                            renamingID = meta.id.uuidString
                            renameFocused = true
                        }
                        .disabled(!window.isConnected)
                        Divider()
                        Button("Delete…") { delete(meta) }
                            .disabled(!window.isConnected)
                    }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ meta: ChatMeta) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.kindSymbol(meta.kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if renamingID == meta.id.uuidString {
                TextField("Title", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { rename(meta) }
                    .onExitCommand { renamingID = nil }
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
        }
    }

    // MARK: Selected chat

    @ViewBuilder
    private func selected(_ chats: [ChatMeta]) -> some View {
        if showsDraft {
            LinkedChatDraftView(window: window, workspace: workspace, projectID: projectID, owner: owner)
                .id(key)
        } else if let chatID = selectedChatID(chats) {
            ChatView(chatID: chatID, workspace: workspace)
                .id(chatID)
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

// MARK: - Draft chat

/// A draft chat of kind ticket or bundle: an empty chat whose composer has the focus; its first
/// Send calls `chats.create` with the kind, the ticket or bundle and the message, using the default
/// settings (docs/chats.md › Draft chats).
// DOC-GAP: `ChatView` (ui-chats) is declared for stored chats only and `ComposerView` has no
// ticket or bundle draft, so the Chats tabs show this draft until integration gives them the chat
// view's draft mode: the empty transcript text, the CLI status lines, the files and Send; the
// draft uses the default chat settings (no settings menus).
private struct LinkedChatDraftView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let owner: LinkedChatsOwner

    @State private var text = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var focusRequest = 1
    @State private var isSending = false

    private var status: ClaudeStatus? {
        workspace.claudeStatus
    }

    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && window.isConnected && status?.available == true && !isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(owner.kind == .ticket
                 ? "Ask Claude about \(owner.id), or click Implement."
                 : "Ask Claude about \(owner.id), or click Implement All.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            cliStatus
            composer
                .padding(10)
        }
    }

    @ViewBuilder
    private var cliStatus: some View {
        if let status, status.checking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the Claude CLI…")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
        } else if let status, !status.available {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if workspace.isLocal {
                    Text(status.error ?? "")
                    Spacer()
                    Button("Open Settings") {
                        window.app?.openSettings(tab: .general)
                    }
                } else {
                    Text("Claude CLI is not available on \(workspace.deviceName): \(status.error ?? "")")
                    Spacer()
                }
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            .padding(.horizontal, 10)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(attachments) { attachment in
                        PendingAttachmentChip(attachment: attachment) {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    Task {
                        let urls = await PendingAttachments.chooseFiles(in: TicketActions.nsWindow(window))
                        addFiles(urls)
                    }
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Attach Files")
                TicketTextEditor(
                    text: $text,
                    placeholder: window.isConnected ? "Message Claude…" : "Not connected to \(workspace.deviceName)",
                    minLines: 1, maxLines: 10,
                    focusRequest: focusRequest,
                    onReturn: { send() },
                    onEscape: nil,
                    onPaste: { pasteboard in
                        switch PendingAttachments.fromPasteboard(pasteboard) {
                        case .files(let items?):
                            attachments += items
                            return true
                        case .files(nil):
                            window.alert = PendingAttachments.folderAlert
                            return true
                        case .none:
                            return false
                        }
                    },
                    onDropFiles: { urls in addFiles(urls) }
                )
                .disabled(!window.isConnected)
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Send")
                .disabled(!canSend)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { addFiles(await DroppedFiles.urls(from: providers)) }
            return true
        }
    }

    private func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let items = PendingAttachments.fromFiles(urls) else {
            window.alert = PendingAttachments.folderAlert
            return
        }
        attachments += items
    }

    /// The first Send: `chats.create` with the message; the new chat replaces the draft and is
    /// selected.
    private func send() {
        guard canSend else { return }
        let message = text
        let files = attachments
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let uploads = try await PendingAttachments.uploads(files)
                let params = ChatsCreate.Params(
                    projectID: projectID, kind: owner.kind,
                    ticketID: owner.kind == .ticket ? owner.id : nil,
                    bundleID: owner.kind == .bundle ? owner.id : nil,
                    message: ChatMessageInput(text: message, attachments: uploads.isEmpty ? nil : uploads))
                let meta = try await workspace.call(ChatsCreate.self, params)
                let store = TicketWindowStore.store(for: window)
                let key = TicketWindowStore.key(workspace.deviceID, owner.id)
                store.chatSelection[key] = meta.id.uuidString
                store.draftChats.remove(key)
            } catch {
                window.alert = .failure("Send", error)
            }
        }
    }
}
