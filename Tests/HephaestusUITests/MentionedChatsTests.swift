import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Mentioned In tab: the other chats of the device that mention a ticket or a
/// bundle.
@MainActor
@Suite("Mentioned In tab")
struct MentionedChatsTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func chat(_ kind: ChatKind, project: ProjectID = "DEMO", ticketID: TicketID? = nil, bundleID: BundleID? = nil,
                      orchestrator: ChatID? = nil, closed: Bool = false, mentions: [String] = [], minutes: Double) -> ChatMeta {
        let date = created.addingTimeInterval(minutes * 60)
        return ChatMeta(id: UUID(), kind: kind, ticketID: ticketID, bundleID: bundleID, orchestratorChatID: orchestrator, created: date,
                        updated: date, closed: closed, projectID: project, mentionedIDs: mentions)
    }

    private func workspace(_ chats: [ChatMeta]) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        for meta in chats {
            workspace.chats[meta.id.uuidString] = meta
        }
        return workspace
    }

    @Test("Chats of every project that mention the ticket are listed newest first, closed ones included, without the ticket's own chats")
    func ticketTab() {
        let planning = chat(.project, mentions: ["DEMO-1", "DEMO-2"], minutes: 0)
        let otherProject = chat(.project, project: "API", mentions: ["DEMO-1"], minutes: 20)
        let closed = chat(.feedback, closed: true, mentions: ["DEMO-1"], minutes: 10)
        let unrelated = chat(.project, mentions: ["DEMO-2", "DEMO-10"], minutes: 30)
        let own = chat(.ticket, ticketID: "DEMO-1", mentions: ["DEMO-1"], minutes: 40)
        let ownCI = chat(.ci, ticketID: "DEMO-1", orchestrator: own.id, mentions: ["DEMO-1"], minutes: 50)
        let workspace = workspace([planning, otherProject, closed, unrelated, own, ownCI])
        let listed = MentionedChatsView.listedChats(owner: .ticket("DEMO-1"), ownChatIDs: [own.id], workspace: workspace)
        #expect(listed.map(\.id) == [otherProject.id, closed.id, planning.id])
        #expect(MentionedChatsView.listedChats(owner: .ticket("DEMO-10"), ownChatIDs: [], workspace: workspace).map(\.id) == [unrelated.id])
    }

    @Test("A bundle's tab leaves out its bundle chats and the ticket chats and CI chats they orchestrate")
    func bundleTab() {
        let bundleChat = chat(.bundle, bundleID: "DEMO-B1", mentions: ["DEMO-B1"], minutes: 0)
        let ticketChat = chat(.ticket, ticketID: "DEMO-1", orchestrator: bundleChat.id, mentions: ["DEMO-B1"], minutes: 5)
        let planning = chat(.project, mentions: ["DEMO-B1"], minutes: 10)
        let workspace = workspace([bundleChat, ticketChat, planning])
        #expect(MentionedChatsView.listedChats(owner: .bundle("DEMO-B1"), ownChatIDs: [bundleChat.id], workspace: workspace).map(\.id)
            == [planning.id])
        // In the ticket's tab, the bundle chat that named the ticket is another chat.
        let mentioning = chat(.bundle, bundleID: "DEMO-B2", mentions: ["DEMO-1"], minutes: 20)
        workspace.chats[mentioning.id.uuidString] = mentioning
        #expect(MentionedChatsView.listedChats(owner: .ticket("DEMO-1"), ownChatIDs: [ticketChat.id], workspace: workspace).map(\.id)
            == [mentioning.id])
    }

    @Test("The list follows chat.updated and chat.deleted, and the selection falls back to the newest chat")
    func liveAndSelection() {
        let older = chat(.project, mentions: ["DEMO-1"], minutes: 0)
        var newer = chat(.project, minutes: 10)
        let workspace = workspace([older, newer])
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        MentionedChatsView.selectMostRecent(owner: .ticket("DEMO-1"), ownChatIDs: [], workspace: workspace, window: window,
                                            projectID: "DEMO")
        #expect(window.viewState.mentionedInSelection["DEMO-1"] == older.id.uuidString)

        newer.mentionedIDs = ["DEMO-1"]
        workspace.chats[newer.id.uuidString] = newer
        let listed = MentionedChatsView.listedChats(owner: .ticket("DEMO-1"), ownChatIDs: [], workspace: workspace)
        #expect(listed.map(\.id) == [newer.id, older.id])
        #expect(MentionedChatsView.selectedChatID(listed, stored: older.id.uuidString) == older.id.uuidString)

        workspace.chats[older.id.uuidString] = nil
        let remaining = MentionedChatsView.listedChats(owner: .ticket("DEMO-1"), ownChatIDs: [], workspace: workspace)
        #expect(MentionedChatsView.selectedChatID(remaining, stored: older.id.uuidString) == newer.id.uuidString)
        #expect(MentionedChatsView.selectedChatID([], stored: nil) == nil)
    }

    @Test("The tab values and the selection are encoded for debug_ui_state and not persisted")
    func windowState() throws {
        var state = ProjectViewState()
        state.ticketTab = .mentionedIn
        state.bundleTab = .mentionedIn
        state.mentionedInSelection = ["DEMO-1": "C0FFEE00-1234-4ABC-9DEF-0123456789AB"]
        let decoded = try JSONDecoder().decode(ProjectViewState.self, from: JSONEncoder().encode(state))
        #expect(decoded.ticketTab == .mentionedIn && decoded.bundleTab == .mentionedIn)
        #expect(decoded.mentionedInSelection == state.mentionedInSelection)
        let encoder = JSONEncoder()
        encoder.userInfo[WindowState.persistedOnlyKey] = true
        let persisted = try JSONDecoder().decode(ProjectViewState.self, from: encoder.encode(state))
        #expect(persisted.ticketTab == .details && persisted.mentionedInSelection.isEmpty)
    }
}
