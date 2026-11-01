import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Linked items and docs/ui.md › Inspector: the items of the shown section, their
/// chips and lines, the unlinked items and the message text Send gives.
@MainActor
@Suite("Inspector linked items")
struct LinkedItemsTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)
    let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    let tabID = UUID(uuidString: "9B2D6C1E-0F4A-4E8B-A1C2-3D4E5F607182")!

    var tickets: [String: Ticket] {
        [
            "DEMO-2": Ticket(id: "DEMO-2", title: "Fix the login form", created: created),
            "DEMO-10": Ticket(id: "DEMO-10", title: "Remember the last account", created: created),
        ]
    }

    var bundles: [String: TicketBundle] {
        ["DEMO-B1": TicketBundle(id: "DEMO-B1", title: "Login", created: created)]
    }

    var chats: [String: ChatMeta] {
        [chatID.uuidString: ChatMeta(id: chatID, title: "Plan the release", kind: .project, created: created)]
    }

    var webTabs: [WebTab] {
        [WebTab(id: tabID, title: "Example", url: "https://example.com/")]
    }

    func linked(_ state: ProjectViewState, _ section: ProjectSection, webTabs: [WebTab]? = nil) -> [LinkedItem] {
        LinkedItems.linked(state: state, section: section, tickets: tickets, bundles: bundles, chats: chats,
                           webTabs: webTabs ?? self.webTabs)
    }

    /// A view state with one selection in every section.
    var everySelection: ProjectViewState {
        var state = ProjectViewState()
        state.selectedTicketIDs = ["DEMO-10", "DEMO-2"]
        state.selectedBundleID = "DEMO-B1"
        state.selectedChatID = chatID.uuidString
        state.selectedEditorPath = "Sources/App/Main.swift"
        state.selectedDocPath = "docs/chats.md"
        state.selectedWebTabID = tabID.uuidString
        state.selectedSkillName = "release-notes"
        return state
    }

    @Test func ticketsInNumberOrder() {
        let items = linked(everySelection, .tickets)
        #expect(items.map(\.name) == ["DEMO-2", "DEMO-10"])
        #expect(items.map(\.line) == [
            "Open in the app: ticket DEMO-2 “Fix the login form”",
            "Open in the app: ticket DEMO-10 “Remember the last account”",
        ])
        #expect(items.map { $0.ref.section.symbol } == ["checklist", "checklist"])
    }

    @Test func onlyTheShownSectionIsLinked() {
        let state = everySelection
        #expect(linked(state, .bundles).map(\.line) == ["Open in the app: bundle DEMO-B1 “Login”"])
        #expect(linked(state, .chats).map(\.line) == ["Open in the app: chat “Plan the release” (\(chatID.uuidString))"])
        #expect(linked(state, .code).map(\.line) == ["Open in the app: code file Sources/App/Main.swift"])
        #expect(linked(state, .docs).map(\.line) == ["Open in the app: docs file docs/chats.md"])
        #expect(linked(state, .web).map(\.line) == ["Open in the app: web tab “Example” https://example.com/"])
        #expect(linked(state, .skills).map(\.line) == ["Open in the app: skill release-notes"])
    }

    @Test func shortNames() {
        let state = everySelection
        #expect(linked(state, .bundles).map(\.name) == ["DEMO-B1"])
        #expect(linked(state, .chats).map(\.name) == ["Plan the release"])
        #expect(linked(state, .code).map(\.name) == ["Main.swift"])
        #expect(linked(state, .docs).map(\.name) == ["chats.md"])
        #expect(linked(state, .web).map(\.name) == ["Example"])
        #expect(linked(state, .skills).map(\.name) == ["release-notes"])
    }

    @Test func untitledWebTabIsNamedByItsURL() {
        let items = linked(everySelection, .web, webTabs: [WebTab(id: tabID, url: "https://example.com/")])
        #expect(items.map(\.name) == ["https://example.com/"])
        #expect(items.map(\.line) == ["Open in the app: web tab https://example.com/"])
    }

    @Test func itemsTheWorkspaceDoesNotHoldAreNotLinked() {
        var state = ProjectViewState()
        state.selectedTicketIDs = ["DEMO-2", "DEMO-99"]
        #expect(linked(state, .tickets).map(\.name) == ["DEMO-2"])
        state.selectedWebTabID = UUID().uuidString
        #expect(linked(state, .web).isEmpty)
    }

    @Test func unlinkedItemStaysUnlinkedWhileOpen() {
        var state = everySelection
        state.unlinkedItems = ["ticket:DEMO-2"]
        state.forgetClosedUnlinkedItems(in: .tickets)
        #expect(state.unlinkedItems == ["ticket:DEMO-2"])
        #expect(linked(state, .tickets).map(\.name) == ["DEMO-10"])
    }

    @Test func closedItemIsLinkedAgainWhenOpened() {
        var state = everySelection
        state.unlinkedItems = ["ticket:DEMO-2"]
        state.selectedTicketIDs = ["DEMO-10"]
        state.forgetClosedUnlinkedItems(in: .tickets)
        #expect(state.unlinkedItems.isEmpty)
        state.selectedTicketIDs = ["DEMO-2"]
        #expect(linked(state, .tickets).map(\.name) == ["DEMO-2"])
    }

    @Test func messageTextStartsWithTheLines() {
        let items = linked(everySelection, .tickets)
        #expect(LinkedItems.messageText("Can these two be done in one bundle?", linked: items) == """
            Open in the app: ticket DEMO-2 “Fix the login form”
            Open in the app: ticket DEMO-10 “Remember the last account”

            Can these two be done in one bundle?
            """)
        #expect(LinkedItems.messageText("", linked: items) == """
            Open in the app: ticket DEMO-2 “Fix the login form”
            Open in the app: ticket DEMO-10 “Remember the last account”
            """)
        #expect(LinkedItems.messageText("Hello", linked: []) == "Hello")
    }

    @Test func unlinkedItemsAreNotPersisted() throws {
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        window.updateViewState { $0.unlinkedItems = ["doc:docs/chats.md"] }
        let persisted = try #require(window.persistedJSON)
        #expect(!persisted.contains("unlinkedItems"))
        let full = String(decoding: try EngineJSON.encoder().encode(window), as: UTF8.self)
        #expect(full.contains("doc:docs/chats.md"))
    }
}
