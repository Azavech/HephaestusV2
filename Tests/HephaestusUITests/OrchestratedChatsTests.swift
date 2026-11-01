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
}
