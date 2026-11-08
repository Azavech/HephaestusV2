// OWNER: ui-tickets — the Mentioned In tab of a ticket and of a bundle: the other chats of the device
// that mention it and the selected chat's view (docs/tickets.md › Mentioned In tab).
import HephaestusCore
import SwiftUI

/// The Mentioned In tab: the chats of every project of the device whose `mentionedIDs` holds the
/// ticket's or bundle's id, without the item's own chats, newest first, and the selected chat's
/// view under the list.
struct MentionedChatsView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let owner: LinkedChatsOwner
    /// The ticket's or bundle's `chats`, whose Chats tab rows are its own chats.
    let ownChatIDs: [ChatID]

    private var viewState: ProjectViewState {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)] ?? ProjectViewState()
    }

    /// The listed chats: every chat that mentions the item (docs/data-model.md › Mentioned ids),
    /// closed chats included, except the chats that its Chats tab lists whatever the filter, most
    /// recently updated first.
    static func listedChats(owner: LinkedChatsOwner, ownChatIDs: [ChatID], workspace: DeviceWorkspace) -> [ChatMeta] {
        let own = Set(LinkedChatsView.listedChats(ownChatIDs, workspace: workspace).map(\.id))
        return workspace.chats.values
            .filter { $0.mentionedIDs.contains(owner.id) && !own.contains($0.id) }
            .sorted { ($0.updated, $0.id.uuidString) > ($1.updated, $1.id.uuidString) }
    }

    /// Sets the chat shown by the tab (`mentionedInSelection`).
    static func select(_ chatID: String?, owner: LinkedChatsOwner, window: WindowState, projectID: String) {
        window.updateViewState(of: projectID) { $0.mentionedInSelection[owner.id] = chatID }
    }

    /// Opening the tab selects the most recently updated chat of the list.
    static func selectMostRecent(owner: LinkedChatsOwner, ownChatIDs: [ChatID], workspace: DeviceWorkspace, window: WindowState,
                                 projectID: String) {
        select(listedChats(owner: owner, ownChatIDs: ownChatIDs, workspace: workspace).first?.id.uuidString, owner: owner,
               window: window, projectID: projectID)
    }

    /// The chat shown under the list: the stored selection while it is listed, otherwise the most
    /// recently updated chat.
    static func selectedChatID(_ chats: [ChatMeta], stored: String?) -> String? {
        if let stored, chats.contains(where: { $0.id.uuidString == stored }) {
            return stored
        }
        return chats.first?.id.uuidString
    }

    var body: some View {
        let chats = Self.listedChats(owner: owner, ownChatIDs: ownChatIDs, workspace: workspace)
        if chats.isEmpty {
            emptyState
        } else {
            let selectedID = Self.selectedChatID(chats, stored: viewState.mentionedInSelection[owner.id])
            VSplitView {
                List(selection: Binding<String?>(
                    get: { selectedID },
                    set: { id in
                        guard let id else { return }
                        Self.select(id, owner: owner, window: window, projectID: projectID)
                    }
                )) {
                    ForEach(chats) { meta in
                        ChatsTabChatRow(meta: meta, window: window, workspace: workspace, projectID: projectID,
                                        showsAgentsDisclosure: false)
                            .tag(meta.id.uuidString)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 60, idealHeight: 120, maxHeight: 320)
                Group {
                    if let selectedID {
                        ChatView(chatID: selectedID, workspace: workspace)
                            .id(selectedID)
                    } else {
                        Color.clear
                    }
                }
                .frame(minHeight: 220, maxHeight: .infinity)
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No Mentions")
                .font(.title3.weight(.semibold))
            // docs/tickets.md › Mentioned In tab, › Bundles section (Mentioned In tab).
            Text(owner.kind == .ticket
                 ? "Chats that mention this ticket appear here."
                 : "Chats that mention this bundle appear here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
