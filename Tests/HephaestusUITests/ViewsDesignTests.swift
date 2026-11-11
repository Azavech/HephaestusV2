import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/views.md › Design with Claude: the view the Views section shows is a linked item of the
/// inspector's chat, its messages carry it, and `Create Preview` has the inspector's chat send its
/// request with the linked items.
@MainActor
@Suite("Design views with Claude")
struct ViewsDesignTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)
    let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    let counter = ProjectView(name: "CounterView", path: "Sources/App/Counter.swift", line: 3, kind: .swiftUI)
    let row = ProjectView(name: "SettingsView.Row", path: "Sources/App/Settings View:1.swift", line: 9, kind: .swiftUI)

    /// A view state whose Views section selected `view`, with a ticket selected in Tickets.
    func state(selecting view: ProjectView?) -> ProjectViewState {
        var state = ProjectViewState()
        state.selectedTicketIDs = ["DEMO-2"]
        let views = ViewsSectionState(appearance: .light)
        views.selection = view.map(ViewSelection.init)
        state.viewsState = views
        return state
    }

    func linked(_ state: ProjectViewState, _ section: ProjectSection?) -> [LinkedItem] {
        LinkedItems.linked(state: state, section: section, tickets: ["DEMO-2": Ticket(id: "DEMO-2", title: "Fix the login form", created: created)],
                           bundles: [:], chats: [:], webTabs: [])
    }

    @Test("The Views section links the view shown, by its name and the path of its file; another section does not")
    func linkedView() {
        let state = state(selecting: counter)
        let items = linked(state, .views)
        #expect(items.map(\.name) == ["CounterView"])
        #expect(items.map(\.line) == ["Open in the app: view CounterView in Sources/App/Counter.swift"])
        #expect(items.map(\.chatLinkedItem) == [ChatLinkedItem(kind: .view, name: "CounterView", text: "view CounterView in Sources/App/Counter.swift")])
        #expect(ChatLinkedItemKind.view.symbol == "rectangle.3.group")
        #expect(linked(state, .tickets).map(\.ref.kind) == [.ticket])
        #expect(linked(state, .dashboard).isEmpty)
        #expect(linked(state, nil).isEmpty)
        // No view selected: nothing linked.
        #expect(linked(self.state(selecting: nil), .views).isEmpty)
        // A nested view, in a path with a colon.
        #expect(linked(self.state(selecting: row), .views).map(\.line) == ["Open in the app: view SettingsView.Row in Sources/App/Settings View:1.swift"])
    }

    @Test("× unlinks the view while it stays selected; another view, then the first one again, are linked")
    func unlinkView() {
        var state = state(selecting: counter)
        let ref = LinkedItemRef.view(path: counter.path, name: counter.name)
        state.unlinkedItems.insert(ref.key)
        #expect(linked(state, .views).isEmpty)
        state.forgetClosedUnlinkedItems(in: .views)
        #expect(linked(state, .views).isEmpty)
        state.viewsState?.selection = ViewSelection(row)
        state.forgetClosedUnlinkedItems(in: .views)
        #expect(linked(state, .views).map(\.name) == ["SettingsView.Row"])
        state.viewsState?.selection = ViewSelection(counter)
        #expect(linked(state, .views).map(\.name) == ["CounterView"])
    }

    @Test("A message sent while the view is linked carries it")
    func messageCarriesView() async throws {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let connection = AddedResourcesTests.SendConnection(createdChat: meta)
        let workspace = AddedResourcesTests().workspace(connection, chat: meta)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        model.linkedItems = linked(state(selecting: counter), .views)
        model.composer.text = "Make the count bold"
        model.send()
        try await AddedResourcesTests().wait { connection.messages.count == 1 }
        #expect(connection.messages == [ChatMessageInput(text: "Make the count bold", linkedItems: [
            ChatLinkedItem(kind: .view, name: "CounterView", text: "view CounterView in Sources/App/Counter.swift"),
        ])])
    }

    @Test("Create Preview: its message, the inspector shown with the request, and the chat sends it with the linked items, leaving the composer as it was")
    func createPreview() async throws {
        #expect(ViewsSectionState.createPreviewMessage(counter) == "Write a #Preview of CounterView into Sources/App/Counter.swift.")

        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        window.inspectorVisible = false
        window.sendFromInspector(ViewsSectionState.createPreviewMessage(counter))
        #expect(window.inspectorVisible)
        #expect(window.inspectorMessage?.projectID == "DEMO")
        #expect(window.inspectorMessage?.text == "Write a #Preview of CounterView into Sources/App/Counter.swift.")

        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let connection = AddedResourcesTests.SendConnection(createdChat: meta)
        let workspace = AddedResourcesTests().workspace(connection, chat: meta)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        model.linkedItems = linked(state(selecting: counter), .views)
        model.composer.text = "Unsent text"
        model.send(text: "Write a #Preview of CounterView into Sources/App/Counter.swift.")
        try await AddedResourcesTests().wait { connection.messages.count == 1 }
        #expect(connection.messages == [ChatMessageInput(text: "Write a #Preview of CounterView into Sources/App/Counter.swift.", linkedItems: [
            ChatLinkedItem(kind: .view, name: "CounterView", text: "view CounterView in Sources/App/Counter.swift"),
        ])])
        #expect(model.composer.text == "Unsent text")
    }

    @Test("Create Preview from a draft creates the project chat with the request")
    func createPreviewFromDraft() async throws {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let connection = AddedResourcesTests.SendConnection(createdChat: meta)
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.claudeStatus = ClaudeStatus(available: true, checking: false)
        let draft = ChatViewModel(workspace: workspace, chatID: nil, draft: DraftChat(projectID: "DEMO", kind: .project))
        var createdIDs: [ChatID] = []
        draft.onCreated = { createdIDs.append($0.id) }
        draft.linkedItems = linked(state(selecting: counter), .views)
        draft.send(text: "Write a #Preview of CounterView into Sources/App/Counter.swift.")
        try await AddedResourcesTests().wait { !createdIDs.isEmpty }
        #expect(createdIDs == [chatID])
        #expect(connection.messages.map(\.text) == ["Write a #Preview of CounterView into Sources/App/Counter.swift."])
        #expect(connection.messages.first?.linkedItems?.map(\.kind) == [.view])
    }

    @Test("Create Preview sends nothing while the CLI is unavailable")
    func createPreviewNeedsCLI() async throws {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let connection = AddedResourcesTests.SendConnection(createdChat: meta)
        let workspace = AddedResourcesTests().workspace(connection, chat: meta)
        workspace.claudeStatus = ClaudeStatus(available: false, error: "Not found.", checking: false)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        model.send(text: "Write a #Preview of CounterView into Sources/App/Counter.swift.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(connection.messages.isEmpty)
    }
}
