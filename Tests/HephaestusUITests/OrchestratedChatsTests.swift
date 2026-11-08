import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Bundles section (Chats tab) and docs/chats.md › Orchestrated ticket chats.
@MainActor
@Suite("Orchestrated ticket chats")
struct OrchestratedChatsTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func chat(_ kind: ChatKind, ticketID: TicketID? = nil, bundleID: BundleID? = nil, orchestrator: ChatID? = nil,
                      minutes: Double) -> ChatMeta {
        let date = created.addingTimeInterval(minutes * 60)
        return ChatMeta(id: UUID(), kind: kind, ticketID: ticketID, bundleID: bundleID, orchestratorChatID: orchestrator,
                        created: date, updated: date)
    }

    @Test("The bundle's Chats tab lists each bundle chat followed by its ticket chats, oldest first; the ticket's tab lists them too")
    func nestedRows() {
        let older = chat(.bundle, bundleID: "DEMO-B1", minutes: 0)
        let orchestrator = chat(.bundle, bundleID: "DEMO-B1", minutes: 10)
        var first = chat(.ticket, ticketID: "DEMO-1", orchestrator: orchestrator.id, minutes: 11)
        first.updated = created.addingTimeInterval(3600)
        let second = chat(.ticket, ticketID: "DEMO-2", orchestrator: orchestrator.id, minutes: 20)
        let unrelated = chat(.ticket, ticketID: "DEMO-1", minutes: 30)
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        for meta in [older, orchestrator, first, second, unrelated] {
            workspace.chats[meta.id.uuidString] = meta
        }
        let rows = LinkedChatsView.listedRows([older.id, orchestrator.id], workspace: workspace)
        #expect(rows.map(\.meta.id) == [orchestrator.id, first.id, second.id, older.id])
        #expect(rows.map(\.nested) == [false, true, true, false])
        #expect(LinkedChatsView.listedChats([older.id, orchestrator.id], workspace: workspace).count == 4)
        let ticketRows = LinkedChatsView.listedRows([first.id, unrelated.id], workspace: workspace)
        #expect(ticketRows.map(\.meta.id) == [first.id, unrelated.id])
        #expect(ticketRows.allSatisfy { !$0.nested })
    }

    @Test("A CI chat is listed under its orchestrator in the ticket's and the bundle's Chats tabs, after the ticket chats; without its orchestrator it is listed alone")
    func ciChats() {
        let implement = chat(.ticket, ticketID: "DEMO-1", minutes: 0)
        let ticketCI = chat(.ci, ticketID: "DEMO-1", orchestrator: implement.id, minutes: 5)
        let other = chat(.ticket, ticketID: "DEMO-1", minutes: 10)
        let bundleChat = chat(.bundle, bundleID: "DEMO-B1", minutes: 20)
        let ticketChat = chat(.ticket, ticketID: "DEMO-2", orchestrator: bundleChat.id, minutes: 21)
        let bundleCI = chat(.ci, bundleID: "DEMO-B1", orchestrator: bundleChat.id, minutes: 30)
        let orphan = chat(.ci, ticketID: "DEMO-1", orchestrator: UUID(), minutes: 40)
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        for meta in [implement, ticketCI, other, bundleChat, ticketChat, bundleCI, orphan] {
            workspace.chats[meta.id.uuidString] = meta
        }
        // The ticket's chats hold the CI chat: it is nested under the implement chat, not listed twice.
        let ticketRows = LinkedChatsView.listedRows([implement.id, ticketCI.id, other.id, orphan.id], workspace: workspace)
        #expect(ticketRows.map(\.meta.id) == [orphan.id, other.id, implement.id, ticketCI.id])
        #expect(ticketRows.map(\.nested) == [false, false, false, true])
        #expect(LinkedChatsView.listedChats([implement.id, ticketCI.id, other.id, orphan.id], workspace: workspace).count == 4)
        // The bundle's chats hold the bundle chat and its CI chat; the ticket chats come in from their orchestrator.
        let bundleRows = LinkedChatsView.listedRows([bundleChat.id, bundleCI.id], workspace: workspace)
        #expect(bundleRows.map(\.meta.id) == [bundleChat.id, ticketChat.id, bundleCI.id])
        #expect(bundleRows.map(\.nested) == [false, true, true])
        #expect(LinkedChatsView.kindSymbol(.ci) == "checkmark.seal")
        #expect(ChatFormat.kindTitle(.ci) == "CI")
        #expect(ChatFormat.placeholder(kind: .ci, projectName: "Demo", ticketID: "DEMO-1", bundleID: nil) == nil)
    }
}
