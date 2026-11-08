import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Where chats appear, › Closing a chat and docs/ui.md › WindowState: the selection
/// of several chats in the Chats section, its context menu and Close.
@MainActor
@Suite("Chats section selection")
struct ChatsSelectionTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func chat(_ kind: ChatKind, title: String, ticketID: TicketID? = nil, closed: Bool = false, minutes: Double) -> ChatMeta {
        let date = created.addingTimeInterval(minutes * 60)
        return ChatMeta(id: UUID(), title: title, kind: kind, ticketID: ticketID, created: date, updated: date, closed: closed,
                        projectID: "DEMO")
    }

    private func workspace(_ chats: [ChatMeta]) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        for meta in chats {
            workspace.chats[meta.id.uuidString] = meta
        }
        return workspace
    }

    @Test("Chats come in list order: newest updated first, whatever their kind")
    func listOrder() {
        let oldProject = chat(.project, title: "Old project", minutes: 0)
        let newProject = chat(.project, title: "New project", minutes: 5)
        let ticket = chat(.ticket, title: "Ticket", ticketID: "DEMO-1", minutes: 9)
        let feedback = chat(.feedback, title: "Feedback", minutes: 7)
        let ordered = ChatsSectionView.inListOrder([feedback, ticket, oldProject, newProject])
        #expect(ordered.map(\.title) == ["Ticket", "Feedback", "New project", "Old project"])
    }

    @Test("A selection made in the list holds only the chats it lists")
    func listSelection() {
        let first = chat(.project, title: "First", minutes: 0)
        let second = chat(.project, title: "Second", minutes: 1)
        let hidden = chat(.project, title: "Hidden", closed: true, minutes: 2)
        let all = workspace([first, second, hidden])
        let listed = ChatsSectionView.listedChats(Array(all.chats.values), hidesClosed: true, workspace: all)
        #expect(Set(listed.map(\.title)) == ["First", "Second"])

        // ⌘-click after Close: the closed chats left the list, so they leave the selection.
        let ids: Set<String> = [first.id.uuidString, second.id.uuidString, hidden.id.uuidString]
        #expect(ChatsSectionView.listSelection(ids, listed: listed) == [first.id.uuidString, second.id.uuidString])
        #expect(ChatsSectionView.listSelection([hidden.id.uuidString], listed: listed).isEmpty)
    }

    @Test("The context menu acts on the listed chats of its rows, in list order")
    func menuChats() {
        let older = chat(.project, title: "Older", minutes: 0)
        let newer = chat(.project, title: "Newer", minutes: 1)
        let hidden = chat(.project, title: "Hidden", closed: true, minutes: 2)
        let listed = [newer, older]
        let ids: Set<String> = [older.id.uuidString, newer.id.uuidString, hidden.id.uuidString]
        #expect(ChatsSectionView.menuChats(ids, listed: listed).map(\.title) == ["Newer", "Older"])
        #expect(ChatsSectionView.menuChats([older.id.uuidString], listed: listed).map(\.title) == ["Older"])
        #expect(ChatsSectionView.menuChats([], listed: listed).isEmpty)
    }

    @Test("Close is enabled when one chat has closed false, and asks for one chat or for several")
    func close() {
        let open = chat(.project, title: "Plan the release", minutes: 0)
        let closed = chat(.project, title: "Old plan", closed: true, minutes: 1)
        let other = chat(.ticket, title: "Fix the login", ticketID: "DEMO-1", minutes: 2)
        #expect(ChatActions.canClose([open]))
        #expect(!ChatActions.canClose([closed]))
        #expect(ChatActions.canClose([closed, open]))
        #expect(!ChatActions.canClose([]))
        #expect(ChatActions.closeQuestion([open]) == "Close the chat “Plan the release”?")
        #expect(ChatActions.closeQuestion([open, closed, other]) == "Close 3 chats?")
    }

    @Test("The persisted WindowState keeps several selected chats; a state with one selected chat restores it")
    func persistence() throws {
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        window.updateViewState(of: "DEMO") { $0.selectedChatIDs = ["b", "a", "c"] }
        let json = try #require(window.persistedJSON)
        #expect(json.contains(#""selectedChatIDs":["a","b","c"]"#))
        let restored = try #require(WindowState.restored(fromJSON: json))
        #expect(restored.viewState.selectedChatIDs == ["a", "b", "c"])

        // A state persisted before `selectedChatIDs`, with the single `selectedChatID`.
        let legacy = json.replacingOccurrences(of: #""selectedChatIDs":["a","b","c"]"#, with: #""selectedChatID":"a""#)
        #expect(legacy != json)
        let fromLegacy = try #require(WindowState.restored(fromJSON: legacy))
        #expect(fromLegacy.viewState.selectedChatIDs == ["a"])
    }

    @Test("Several selected chats: every one is linked to the inspector chat in list order, the feedback item is the first")
    func linkedItemsAndFeedback() {
        let ticket = chat(.ticket, title: "Fix the login", ticketID: "DEMO-1", minutes: 9)
        let older = chat(.project, title: "Older plan", minutes: 0)
        let newer = chat(.project, title: "Newer plan", minutes: 1)
        let workspace = workspace([ticket, older, newer])
        var state = ProjectViewState()
        state.selectedChatIDs = [ticket.id.uuidString, older.id.uuidString, newer.id.uuidString]
        let items = LinkedItems.linked(state: state, section: .chats, tickets: [:], bundles: [:], chats: workspace.chats, webTabs: [])
        #expect(items.map(\.name) == ["Fix the login", "Newer plan", "Older plan"])

        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        window.section = .chats
        window.viewState = state
        #expect(FeedbackController.selectedItem(of: window, in: workspace, projectID: "DEMO") == "Fix the login")
    }
}
