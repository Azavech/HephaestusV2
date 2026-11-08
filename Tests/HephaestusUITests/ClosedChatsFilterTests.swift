import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Where chats appear, docs/tickets.md › Ticket chats and Implement, › Implement
/// All and docs/ui.md › WindowState: the filter of the chat lists that hides closed chats.
@MainActor
@Suite("Closed chats filter")
struct ClosedChatsFilterTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func chat(_ kind: ChatKind, ticketID: TicketID? = nil, bundleID: BundleID? = nil, orchestrator: ChatID? = nil,
                      closed: Bool = false, minutes: Double) -> ChatMeta {
        let date = created.addingTimeInterval(minutes * 60)
        return ChatMeta(id: UUID(), kind: kind, ticketID: ticketID, bundleID: bundleID, orchestratorChatID: orchestrator,
                        created: date, updated: date, closed: closed, projectID: "DEMO")
    }

    private func workspace(_ chats: [ChatMeta], tickets: [Ticket] = []) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        for meta in chats {
            workspace.chats[meta.id.uuidString] = meta
        }
        workspace.tickets["DEMO"] = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
        return workspace
    }

    private func setStatus(_ status: TicketStatus, of ticketID: TicketID, in workspace: DeviceWorkspace) {
        workspace.tickets["DEMO"]?[ticketID]?.status = status
    }

    @Test("A chat is closed by close_chat or by its linked ticket's done status, and open again after Reopen or a status change")
    func closedState() {
        var closedByTool = chat(.project, closed: true, minutes: 0)
        let ticketChat = chat(.ticket, ticketID: "DEMO-1", minutes: 1)
        let feedbackChat = chat(.feedback, ticketID: "DEMO-1", minutes: 2)
        let unlinkedFeedback = chat(.feedback, minutes: 3)
        let bundleChat = chat(.bundle, bundleID: "DEMO-B1", minutes: 4)
        let otherTicketChat = chat(.ticket, ticketID: "DEMO-2", minutes: 5)
        let workspace = workspace([closedByTool, ticketChat, feedbackChat, unlinkedFeedback, bundleChat, otherTicketChat],
                                  tickets: [Ticket(id: "DEMO-1", title: "Done one", status: .done, created: created),
                                            Ticket(id: "DEMO-2", title: "In review", status: .review, created: created)])

        #expect(workspace.isClosed(closedByTool))
        #expect(workspace.isClosed(ticketChat))
        #expect(workspace.isClosed(feedbackChat))
        #expect(!workspace.isClosed(unlinkedFeedback))
        #expect(!workspace.isClosed(bundleChat))
        #expect(!workspace.isClosed(otherTicketChat))

        // Reopen sets `closed` to false (chat.updated).
        closedByTool.closed = false
        workspace.chats[closedByTool.id.uuidString] = closedByTool
        #expect(!workspace.isClosed(closedByTool))

        // The ticket set back to To Do or In Progress (ticket.updated) opens its chats again.
        setStatus(.todo, of: "DEMO-1", in: workspace)
        #expect(!workspace.isClosed(ticketChat))
        #expect(!workspace.isClosed(feedbackChat))
        setStatus(.done, of: "DEMO-1", in: workspace)
        #expect(workspace.isClosed(ticketChat))
        setStatus(.inProgress, of: "DEMO-1", in: workspace)
        #expect(!workspace.isClosed(ticketChat))
        #expect(!workspace.isClosed(feedbackChat))

        // A chat closed by close_chat stays closed whatever its ticket's status.
        var closedTicketChat = ticketChat
        closedTicketChat.closed = true
        #expect(workspace.isClosed(closedTicketChat))
    }

    @Test("The Chats section hides its closed chats while the filter is on")
    func sectionList() {
        let open = chat(.project, minutes: 0)
        let closed = chat(.project, closed: true, minutes: 1)
        let doneTicketChat = chat(.ticket, ticketID: "DEMO-1", minutes: 2)
        let closedFeedback = chat(.feedback, ticketID: "DEMO-1", minutes: 3)
        let closedOrphan = chat(.ticket, ticketID: "DEMO-9", closed: true, minutes: 4)
        let openOrphanCI = chat(.ci, bundleID: "DEMO-B9", orchestrator: UUID(), minutes: 5)
        let all = [open, closed, doneTicketChat, closedFeedback, closedOrphan, openOrphanCI]
        let workspace = workspace(all, tickets: [Ticket(id: "DEMO-1", title: "Done", status: .done, created: created)])
        workspace.bundles["DEMO"] = [:]

        // The ticket chat of DEMO-1 is on its ticket, never in the section; the others are listed,
        // newest first, the closed ones only while the filter is off.
        #expect(ChatsSectionView.listedChats(all, hidesClosed: true, workspace: workspace).map(\.id) == [openOrphanCI.id, open.id])
        #expect(ChatsSectionView.listedChats(all, hidesClosed: false, workspace: workspace).map(\.id)
            == [openOrphanCI.id, closedOrphan.id, closedFeedback.id, closed.id, open.id])

        // Every listed chat closed: the list shows `No open chats`.
        #expect(ChatsSectionView.listedChats([closed, doneTicketChat, closedFeedback], hidesClosed: true, workspace: workspace).isEmpty)
        #expect(ChatListFilter.noOpenChats == "No open chats")
    }

    @Test("A Chats tab hides closed chats; a closed bundle chat stays while one of its ticket chats is open")
    func tabRows() {
        let open = chat(.bundle, bundleID: "DEMO-B1", minutes: 0)
        let closedWithOpenChild = chat(.bundle, bundleID: "DEMO-B1", closed: true, minutes: 10)
        let openChild = chat(.ticket, ticketID: "DEMO-2", orchestrator: closedWithOpenChild.id, minutes: 11)
        let doneChild = chat(.ticket, ticketID: "DEMO-1", orchestrator: closedWithOpenChild.id, minutes: 12)
        let closedWithClosedChildren = chat(.bundle, bundleID: "DEMO-B1", closed: true, minutes: 20)
        let closedChild = chat(.ticket, ticketID: "DEMO-3", orchestrator: closedWithClosedChildren.id, closed: true, minutes: 21)
        let workspace = workspace([open, closedWithOpenChild, openChild, doneChild, closedWithClosedChildren, closedChild],
                                  tickets: [Ticket(id: "DEMO-1", title: "Done", status: .done, created: created),
                                            Ticket(id: "DEMO-2", title: "Open", status: .review, created: created),
                                            Ticket(id: "DEMO-3", title: "Open", status: .todo, created: created)])
        let bundleChats = [open.id, closedWithOpenChild.id, closedWithClosedChildren.id]

        let filtered = LinkedChatsView.listedRows(bundleChats, workspace: workspace, hidesClosed: true)
        #expect(filtered.map(\.meta.id) == [closedWithOpenChild.id, openChild.id, open.id])
        #expect(filtered.map(\.nested) == [false, true, false])

        let unfiltered = LinkedChatsView.listedRows(bundleChats, workspace: workspace, hidesClosed: false)
        #expect(unfiltered.map(\.meta.id)
            == [closedWithClosedChildren.id, closedChild.id, closedWithOpenChild.id, openChild.id, doneChild.id, open.id])

        // A ticket's tab whose chats are all closed lists nothing; the tab's count keeps every chat.
        let ticketChats = [doneChild.id, closedChild.id]
        #expect(LinkedChatsView.listedRows(ticketChats, workspace: workspace, hidesClosed: true).isEmpty)
        #expect(LinkedChatsView.listedChats(ticketChats, workspace: workspace).count == 2)

        // Setting the done ticket back to In Progress lists its chat again.
        setStatus(.inProgress, of: "DEMO-1", in: workspace)
        #expect(LinkedChatsView.listedRows(ticketChats, workspace: workspace, hidesClosed: true).map(\.meta.id) == [doneChild.id])
    }

    @Test("Opening a Chats tab selects the most recently updated chat that the filter lists")
    func selectMostRecentListed() {
        let older = chat(.ticket, ticketID: "DEMO-1", minutes: 0)
        let newerClosed = chat(.ticket, ticketID: "DEMO-1", closed: true, minutes: 10)
        let workspace = workspace([older, newerClosed])
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        LinkedChatsView.selectMostRecent(owner: .ticket("DEMO-1"), chatIDs: [older.id, newerClosed.id], workspace: workspace,
                                         window: window, projectID: "DEMO")
        #expect(window.viewState.chatsTabSelection["DEMO-1"] == older.id.uuidString)

        ChatListFilter.toggle(in: window, projectID: "DEMO")
        LinkedChatsView.selectMostRecent(owner: .ticket("DEMO-1"), chatIDs: [older.id, newerClosed.id], workspace: workspace,
                                         window: window, projectID: "DEMO")
        #expect(window.viewState.chatsTabSelection["DEMO-1"] == newerClosed.id.uuidString)
    }

    @Test("The filter button is filled with the Show Closed Chats tooltip while closed chats are hidden")
    func button() {
        #expect(ChatListFilter.symbol(hidesClosedChats: true) == "line.3.horizontal.decrease.circle.fill")
        #expect(ChatListFilter.symbol(hidesClosedChats: false) == "line.3.horizontal.decrease.circle")
        #expect(ChatListFilter.tooltip(hidesClosedChats: true) == "Show Closed Chats")
        #expect(ChatListFilter.tooltip(hidesClosedChats: false) == "Hide Closed Chats")
    }

    @Test("One filter state per window and project, on by default, shared by every chat list and toggled by the button")
    func sharedState() {
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        #expect(ProjectViewState().hidesClosedChats)
        #expect(ChatListFilter.hidesClosedChats(in: window, projectID: "DEMO"))

        ChatListFilter.toggle(in: window, projectID: "DEMO")
        #expect(!window.viewState.hidesClosedChats)
        #expect(!ChatListFilter.hidesClosedChats(in: window, projectID: "DEMO"))
        // Another project and another window keep their own state.
        #expect(ChatListFilter.hidesClosedChats(in: window, projectID: "OTHER"))
        let other = WindowState(deviceID: "device")
        #expect(ChatListFilter.hidesClosedChats(in: other, projectID: "DEMO"))

        ChatListFilter.toggle(in: window, projectID: "DEMO")
        #expect(ChatListFilter.hidesClosedChats(in: window, projectID: "DEMO"))
    }

    @Test("The persisted WindowState restores the filter of every project the window showed")
    func persistence() throws {
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        window.updateViewState(of: "DEMO") {
            $0.hidesClosedChats = false
            $0.selectedChatIDs = ["chat"]
        }
        window.updateViewState(of: "OTHER") {
            $0.hidesClosedChats = false
            $0.selectedChatIDs = ["other chat"]
        }
        window.updateViewState(of: "THIRD") { $0.selectedChatIDs = ["third chat"] }

        let json = try #require(window.persistedJSON)
        let restored = try #require(WindowState.restored(fromJSON: json))
        let demo = try #require(restored.projectStates[ProjectKey(deviceID: "device", projectID: "DEMO")])
        #expect(!demo.hidesClosedChats)
        #expect(demo.selectedChatIDs == ["chat"])
        // The other projects keep only the filter.
        let other = try #require(restored.projectStates[ProjectKey(deviceID: "device", projectID: "OTHER")])
        #expect(!other.hidesClosedChats)
        #expect(other.selectedChatIDs.isEmpty)
        let third = try #require(restored.projectStates[ProjectKey(deviceID: "device", projectID: "THIRD")])
        #expect(third.hidesClosedChats)
        #expect(!json.contains("other chat"))
        #expect(!json.contains("third chat"))

        // A persisted state written before the field existed restores the default.
        let fromLegacy = try #require(WindowState.restored(fromJSON: try legacyJSON(window)))
        #expect(fromLegacy.viewState.hidesClosedChats)
    }

    /// The persisted JSON of `window` without any `hidesClosedChats` key.
    private func legacyJSON(_ window: WindowState) throws -> String {
        let data = try #require(window.persistedJSON?.data(using: .utf8))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["projectStates"] as? [[String: Any]])
        object["projectStates"] = entries.map { entry -> [String: Any] in
            var entry = entry
            if var state = entry["state"] as? [String: Any] {
                state["hidesClosedChats"] = nil
                entry["state"] = state
            }
            return entry
        }
        let encoded = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: encoded, as: UTF8.self)
    }
}
