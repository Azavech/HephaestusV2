import AppKit
import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Added resources, › Composer and docs/search.md › Adding a resource: what each
/// search result adds, the chips a composer shows and sends, the paperclip menu, and the search
/// panel that adds a result to the composer that opened it.
@MainActor
@Suite("Added resources")
struct AddedResourcesTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)
    let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    let tabID = UUID(uuidString: "9B2D6C1E-0F4A-4E8B-A1C2-3D4E5F607182")!

    init() {
        // A menu item's action goes through `NSApp.sendAction`, which needs the application.
        _ = NSApplication.shared
    }

    // MARK: Results, as `search.query` returns them (docs/engine-api.md › SearchResult)

    var project: SearchResult {
        SearchResult(id: "project:API", kind: .projects, projectID: "API", title: "Backend", subtitle: "API · /Users/example/Backend",
                     target: .project(projectID: "API"))
    }

    var ticket: SearchResult {
        SearchResult(id: "ticket:DEMO-2", kind: .tickets, projectID: "DEMO", title: "DEMO-2 Fix the login form",
                     subtitle: "Demo · To Do", target: .ticket(ticketID: "DEMO-2"))
    }

    var bundle: SearchResult {
        SearchResult(id: "bundle:DEMO-B1", kind: .bundles, projectID: "DEMO", title: "DEMO-B1 Login", subtitle: "Demo",
                     target: .bundle(bundleID: "DEMO-B1"))
    }

    func doc(in projectID: String = "DEMO") -> SearchResult {
        SearchResult(id: "doc:\(projectID):docs/chats.md", kind: .docs, projectID: projectID, title: "Chats", subtitle: "docs/chats.md",
                     target: .doc(projectID: projectID, path: "docs/chats.md"))
    }

    func code(in projectID: String = "DEMO", line: Int = 12) -> SearchResult {
        SearchResult(id: "code:\(projectID):Sources/App/main.swift:\(line)", kind: .code, projectID: projectID,
                     title: "Sources/App/main.swift:\(line)", subtitle: "Demo", snippet: "let app = App()",
                     target: .file(projectID: projectID, path: "Sources/App/main.swift", line: line))
    }

    var chat: SearchResult {
        SearchResult(id: "chat:\(chatID.uuidString)", kind: .chats, projectID: "DEMO", title: "Plan the release",
                     subtitle: "Demo · project", target: .chat(chatID: chatID))
    }

    var skill: SearchResult {
        SearchResult(id: "skill:release-notes", kind: .skills, title: "release-notes", subtitle: "Writes release notes.",
                     target: .skill(name: "release-notes"))
    }

    func webTab(title: String = "Example") -> SearchResult {
        SearchResult(id: "web:DEMO:\(tabID.uuidString)", kind: .web, projectID: "DEMO", title: title, subtitle: "https://example.com/",
                     target: .webTab(projectID: "DEMO", tabID: tabID))
    }

    func resource(_ result: SearchResult, chatProjectID: String = "DEMO") -> ChatLinkedItem? {
        AddedResources.resource(for: result, chatProjectID: chatProjectID)
    }

    func added(_ kind: ChatLinkedItemKind, _ name: String, _ text: String) -> ChatLinkedItem {
        ChatLinkedItem(kind: kind, name: name, text: text, added: true)
    }

    // MARK: What a result adds

    @Test("Each result kind adds its kind, short name and <item>, with added true")
    func eachResultKind() {
        #expect(resource(project) == added(.project, "API", "project API “Backend”"))
        #expect(resource(ticket) == added(.ticket, "DEMO-2", "ticket DEMO-2 “Fix the login form”"))
        #expect(resource(bundle) == added(.bundle, "DEMO-B1", "bundle DEMO-B1 “Login”"))
        #expect(resource(doc()) == added(.docsFile, "chats.md", "docs file docs/chats.md"))
        #expect(resource(code()) == added(.codeFile, "main.swift:12", "code file Sources/App/main.swift:12"))
        #expect(resource(chat) == added(.chat, "Plan the release", "chat “Plan the release” (\(chatID.uuidString))"))
        #expect(resource(skill) == added(.skill, "release-notes", "skill release-notes"))
        #expect(resource(webTab()) == added(.webTab, "Example", "web tab “Example” https://example.com/"))
        #expect(resource(webTab(title: "")) == added(.webTab, "https://example.com/", "web tab https://example.com/"))
        // No result has a section target.
        let section = SearchResult(id: "x", kind: .projects, title: "x", target: .section(projectID: "DEMO", section: .tickets))
        #expect(resource(section) == nil)
    }

    @Test("The chip symbols are those of the sidebar sections, and folder for a project")
    func chipSymbols() {
        let symbols = [project, ticket, bundle, doc(), code(), chat, skill, webTab()].map { resource($0)?.kind.symbol }
        #expect(symbols == ["folder", "checklist", "shippingbox", "doc.text", "chevron.left.forwardslash.chevron.right",
                            "bubble.left.and.bubble.right", "wand.and.stars", "globe"])
        // A message's bubble shows an added project with its symbol.
        let item = ChatItem.user(UserItem(id: "u", created: created, text: "Look", sender: "MacBook",
                                          linkedItems: [added(.project, "API", "project API “Backend”")]))
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil, today: created)
        let html = TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
        #expect(html.contains("<span class=\"linked-chip\" title=\"project API “Backend”\">"
                + "<span class=\"md-symbol-icon\" data-symbol=\"folder\"></span><span class=\"linked-name\">API</span></span>"))
    }

    @Test("A docs or code file of another project than the chat's names its project; the other kinds do not")
    func otherProject() {
        #expect(resource(code(in: "API"))?.text == "code file Sources/App/main.swift:12 in project API")
        #expect(resource(code(in: "API"))?.name == "main.swift:12")
        #expect(resource(doc(in: "API"))?.text == "docs file docs/chats.md in project API")
        // The chat's own project is not named.
        #expect(resource(code(in: "API"), chatProjectID: "API")?.text == "code file Sources/App/main.swift:12")
        #expect(resource(doc(in: "API"), chatProjectID: "API")?.text == "docs file docs/chats.md")
        // Ids, titles and URLs name the other items of another project.
        #expect(resource(ticket, chatProjectID: "API")?.text == "ticket DEMO-2 “Fix the login form”")
        #expect(resource(bundle, chatProjectID: "API")?.text == "bundle DEMO-B1 “Login”")
        #expect(resource(chat, chatProjectID: "API")?.text == "chat “Plan the release” (\(chatID.uuidString))")
        #expect(resource(webTab(), chatProjectID: "API")?.text == "web tab “Example” https://example.com/")
        #expect(resource(project, chatProjectID: "DEMO")?.text == "project API “Backend”")
    }

    // MARK: Chips

    /// The open items of a window whose Tickets section has DEMO-2 selected, or whose Code section
    /// shows `Sources/App/main.swift`.
    func linked(_ section: ProjectSection) -> [LinkedItem] {
        var state = ProjectViewState()
        state.selectedTicketIDs = ["DEMO-2"]
        state.selectedEditorPath = "Sources/App/main.swift"
        state.selectedDocPath = "docs/chats.md"
        return LinkedItems.linked(state: state, section: section,
                                  tickets: ["DEMO-2": Ticket(id: "DEMO-2", title: "Fix the login form", created: created)],
                                  bundles: [:], chats: [:], webTabs: [])
    }

    @Test("An open item and the resource added for the same item have the same <item>")
    func sameItemText() {
        #expect(linked(.tickets).map(\.text) == [resource(ticket)?.text])
        #expect(linked(.docs).map(\.text) == [resource(doc())?.text])
        // A code result is a line of the file: another <item> than the open file.
        #expect(linked(.code).map(\.text) == ["code file Sources/App/main.swift"])
        #expect(resource(code())?.text == "code file Sources/App/main.swift:12")
    }

    @Test("The composer never shows two chips with the same <item>")
    func deduplication() throws {
        let ticketResource = try #require(resource(ticket))
        let codeResource = try #require(resource(code()))
        let docResource = try #require(resource(doc()))

        // Adding a resource a resource chip already shows adds nothing; the order added is kept.
        var resources = AddedResources.adding(codeResource, to: [], linked: [])
        resources = AddedResources.adding(docResource, to: resources, linked: [])
        resources = AddedResources.adding(codeResource, to: resources, linked: [])
        #expect(resources == [codeResource, docResource])
        // Another line of the same file is another resource.
        let otherLine = try #require(resource(code(line: 40)))
        #expect(AddedResources.adding(otherLine, to: resources, linked: []) == [codeResource, docResource, otherLine])

        // Adding a resource a linked item chip already shows adds nothing.
        #expect(AddedResources.adding(ticketResource, to: resources, linked: linked(.tickets)) == resources)
        // The code line of the open file is added: its <item> differs.
        #expect(AddedResources.adding(codeResource, to: [], linked: linked(.code)) == [codeResource])

        // An item opened after it was added shows only the resource chip.
        #expect(AddedResources.shownLinkedItems(linked(.tickets), resources: [ticketResource]).isEmpty)
        #expect(AddedResources.shownLinkedItems(linked(.tickets), resources: [codeResource]).map(\.name) == ["DEMO-2"])
        #expect(AddedResources.shownLinkedItems(linked(.code), resources: [codeResource]).map(\.name) == ["main.swift"])
    }

    @Test("Send passes the linked items, then the added resources, in chip order")
    func sentOrder() throws {
        let codeResource = try #require(resource(code()))
        let ticketResource = try #require(resource(ticket))
        let sent = AddedResources.sent(linked: linked(.tickets), resources: [codeResource])
        #expect(sent == [ChatLinkedItem(kind: .ticket, name: "DEMO-2", text: "ticket DEMO-2 “Fix the login form”"), codeResource])
        #expect(sent.map(\.line) == ["Open in the app: ticket DEMO-2 “Fix the login form”",
                                     "Linked by the user: code file Sources/App/main.swift:12"])
        // The open ticket that is also an added resource is passed once, as the added resource.
        #expect(AddedResources.sent(linked: linked(.tickets), resources: [ticketResource, codeResource])
            == [ticketResource, codeResource])
    }

    // MARK: Paperclip menu

    @Test("The paperclip menu has Add Files… and Add Resource…, in this order")
    func attachMenu() {
        var chosen: [String] = []
        let menu = ComposerAttachMenu.menu(addFiles: { chosen.append("files") }, addResource: { chosen.append("resource") })
        #expect(menu.items.map(\.title) == ["Add Files…", "Add Resource…"])
        #expect(menu.items.map(\.isEnabled) == [true, true])
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 0)
        #expect(chosen == ["resource", "files"])
    }

    // MARK: Composer

    /// A connected connection that records the messages of `chats.send` and `chats.create`, and
    /// answers `chats.create` with a new chat; `failing` makes every call fail.
    final class SendConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ChatMessageInput] = []
        private var fails = false
        let createdChat: ChatMeta

        init(createdChat: ChatMeta) {
            self.createdChat = createdChat
        }

        var messages: [ChatMessageInput] { lock.withLock { recorded } }
        var failing: Bool {
            get { lock.withLock { fails } }
            set { lock.withLock { fails = newValue } }
        }

        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connected }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if failing { throw EngineError(.unavailable, "Offline.") }
            if let params = params as? ChatsSend.Params, let result = Empty() as? M.Result {
                lock.withLock { recorded.append(params.message) }
                return result
            }
            if let params = params as? ChatsCreate.Params, let message = params.message, let result = createdChat as? M.Result {
                lock.withLock { recorded.append(message) }
                return result
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    /// A workspace whose device is connected and whose CLI is available, with the chat `meta`.
    func workspace(_ connection: SendConnection, chat meta: ChatMeta) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.claudeStatus = ClaudeStatus(available: true, checking: false)
        workspace.chats[meta.id.uuidString] = meta
        return workspace
    }

    func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A picked result becomes a resource chip of the chat, shared by its views; × removes it")
    func addAndRemove() throws {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let workspace = workspace(SendConnection(createdChat: meta), chat: meta)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        let otherView = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        let focusRequests = model.composerFocusRequest

        model.addResource(code(in: "API"))
        model.addResource(ticket)
        model.addResource(code(in: "API"))
        let codeResource = added(.codeFile, "main.swift:12", "code file Sources/App/main.swift:12 in project API")
        let ticketResource = added(.ticket, "DEMO-2", "ticket DEMO-2 “Fix the login form”")
        #expect(model.composer.resources == [codeResource, ticketResource])
        // Every view of the chat shows them: they are in the chat's draft.
        #expect(otherView.composer.resources == [codeResource, ticketResource])
        #expect(workspace.drafts[chatID.uuidString]?.resources == [codeResource, ticketResource])
        // After each pick the composer has the keyboard focus.
        #expect(model.composerFocusRequest == focusRequests + 3)

        // Resources alone do not enable Send, and are no unsent text for the restart rules.
        #expect(!model.canSend)
        #expect(!ChatDrafts.hasUnsentDraftText(in: [workspace]))

        // A linked ticket that is already an added resource shows no linked item chip.
        model.linkedItems = linked(.tickets)
        #expect(model.shownLinkedItems.isEmpty)
        // Adding a resource that a linked item chip shows adds nothing.
        model.linkedItems = linked(.docs)
        model.addResource(doc())
        #expect(model.composer.resources == [codeResource, ticketResource])
        #expect(model.shownLinkedItems.map(\.name) == ["chats.md"])

        model.removeResource(codeResource)
        #expect(otherView.composer.resources == [ticketResource])
        model.removeResource(ticketResource)
        // An empty draft is not kept.
        #expect(workspace.drafts[chatID.uuidString] == nil)
    }

    @Test("Send passes the resources, clears the text and the attachments only, and every later message passes them again")
    func sendKeepsResources() async throws {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let connection = SendConnection(createdChat: meta)
        let workspace = workspace(connection, chat: meta)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        model.linkedItems = linked(.tickets)
        model.addResource(code())
        let codeResource = added(.codeFile, "main.swift:12", "code file Sources/App/main.swift:12")
        let openTicket = ChatLinkedItem(kind: .ticket, name: "DEMO-2", text: "ticket DEMO-2 “Fix the login form”")
        let upload = AttachmentUpload(name: "build.log", contentType: "text/plain", dataBase64: "bG9n")

        model.composer.text = "First"
        model.composer.attachments = [upload]
        #expect(model.canSend)
        model.send()
        // The text and the attachment chips are cleared at once; the resource chip stays.
        #expect(model.composer == ComposerDraft(resources: [codeResource]))
        try await wait { connection.messages.count == 1 }
        #expect(connection.messages.first == ChatMessageInput(text: "First", attachments: [upload],
                                                             linkedItems: [openTicket, codeResource]))

        // The next message passes the resource again, after the open items.
        model.composer.text = "Second"
        model.send()
        try await wait { connection.messages.count == 2 }
        #expect(connection.messages.last == ChatMessageInput(text: "Second", linkedItems: [openTicket, codeResource]))

        // After ×, the following message no longer passes it.
        model.removeResource(codeResource)
        model.composer.text = "Third"
        model.send()
        try await wait { connection.messages.count == 3 }
        #expect(connection.messages.last == ChatMessageInput(text: "Third", linkedItems: [openTicket]))
        #expect(workspace.drafts[chatID.uuidString] == nil)
    }

    @Test("A failed Send brings the text and the attachments back and keeps the resources")
    func failedSend() async throws {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let connection = SendConnection(createdChat: meta)
        connection.failing = true
        let workspace = workspace(connection, chat: meta)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        model.addResource(skill)
        model.composer.text = "Hello"
        model.send()
        #expect(model.composer.text.isEmpty)
        try await wait { model.composer.text == "Hello" }
        #expect(model.composer == ComposerDraft(text: "Hello", resources: [added(.skill, "release-notes", "skill release-notes")]))
    }

    @Test("The resources of a draft chat stay in its view and stay with the chat its first Send creates")
    func draftChat() async throws {
        let createdChat = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let connection = SendConnection(createdChat: createdChat)
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.claudeStatus = ClaudeStatus(available: true, checking: false)
        let draft = ChatViewModel(workspace: workspace, chatID: nil, draft: DraftChat(projectID: "DEMO", kind: .project))
        var createdIDs: [ChatID] = []
        draft.onCreated = { createdIDs.append($0.id) }

        draft.addResource(code(in: "API"))
        let codeResource = added(.codeFile, "main.swift:12", "code file Sources/App/main.swift:12 in project API")
        #expect(draft.draftComposer.resources == [codeResource])
        // Nothing is stored for a chat until the first Send.
        #expect(workspace.drafts.isEmpty)

        draft.composer.text = "Start"
        draft.send()
        try await wait { !createdIDs.isEmpty }
        #expect(createdIDs == [chatID])
        #expect(connection.messages == [ChatMessageInput(text: "Start", linkedItems: [codeResource])])
        // The view of the new chat reads the resources from the chat's draft.
        #expect(workspace.drafts[chatID.uuidString] == ComposerDraft(resources: [codeResource]))
        let chatView = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        #expect(chatView.composer.resources == [codeResource])
    }

    // MARK: Search panel (docs/search.md › Adding a resource)

    /// A window whose search panel records the targets it navigates to.
    @MainActor
    final class RecordingSearchWindow: SearchPanelWindow {
        var searchVisible = false {
            didSet {
                if !searchVisible { searchPick = nil }
            }
        }
        var search = SearchPanelState()
        var searchPick: SearchPick?
        var searchProjectID: String? = "DEMO"
        var navigated: [NavigationTarget] = []

        func searchNavigate(to target: NavigationTarget) {
            navigated.append(target)
        }
    }

    @Test("Add Resource… opens the panel of the composer's window; a result is added and closes the panel without navigating")
    func pickAddsInsteadOfNavigating() {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let workspace = workspace(SendConnection(createdChat: meta), chat: meta)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        let window = RecordingSearchWindow()
        let controller = SearchController(window: window, workspace: workspace)

        model.chooseResource(in: window)
        #expect(window.searchVisible)
        #expect(window.searchPick?.composer === model)

        controller.open(ticket)
        #expect(!window.searchVisible)
        #expect(window.searchPick == nil)
        #expect(window.navigated.isEmpty)
        #expect(model.composer.resources == [added(.ticket, "DEMO-2", "ticket DEMO-2 “Fix the login form”")])

        // The next opening of the panel navigates again.
        window.searchVisible = true
        controller.open(bundle)
        #expect(!window.searchVisible)
        #expect(window.navigated == [.bundle(bundleID: "DEMO-B1")])
        #expect(model.composer.resources.count == 1)
    }

    @Test("Closing the panel adds nothing and ends the pick, in a main window and in a chat window")
    func closingEndsThePick() {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let workspace = workspace(SendConnection(createdChat: meta), chat: meta)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)

        // A main window: Escape, a click outside and ⇧⌘F set `searchVisible` to false.
        let main = WindowState(deviceID: "device")
        main.projectID = "DEMO"
        #expect(main.searchProjectID == "DEMO")
        model.chooseResource(in: main)
        #expect(main.searchVisible && main.searchPick?.composer === model)
        main.toggleSearch()
        #expect(!main.searchVisible && main.searchPick == nil)
        // The next ⇧⌘F opens the panel with results that navigate.
        main.toggleSearch()
        #expect(main.searchVisible && main.searchPick == nil)
        #expect(model.composer.resources.isEmpty)

        // A chat window: `This project` is the chat's project.
        let chatWindow = ChatWindowSearch()
        chatWindow.searchProjectID = "DEMO"
        model.chooseResource(in: chatWindow)
        #expect(chatWindow.searchVisible && chatWindow.searchPick?.composer === model)
        #expect(SearchController(window: chatWindow, workspace: workspace).projectID == "DEMO")
        chatWindow.search.thisProject = false
        #expect(SearchController(window: chatWindow, workspace: workspace).projectID == nil)
        chatWindow.searchVisible = false
        #expect(chatWindow.searchPick == nil)
        // The window keeps the panel's state for its next opening.
        #expect(chatWindow.search.thisProject == false)
    }

    @Test("The panel closes when the view of the composer that opened it goes away")
    func composerViewGone() {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let workspace = workspace(SendConnection(createdChat: meta), chat: meta)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        let other = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        let window = RecordingSearchWindow()

        model.chooseResource(in: window)
        // Another chat view going away leaves the panel open.
        other.disappear()
        #expect(window.searchVisible)
        model.disappear()
        #expect(!window.searchVisible && window.searchPick == nil)

        // A panel opened again for navigation stays open when that view goes away once more.
        window.searchVisible = true
        model.disappear()
        #expect(window.searchVisible)
    }

    @Test("The added resources are not persisted with the window")
    func notPersisted() throws {
        let meta = ChatMeta(id: chatID, kind: .project, created: created, projectID: "DEMO")
        let workspace = workspace(SendConnection(createdChat: meta), chat: meta)
        let model = ChatViewModel(workspace: workspace, chatID: chatID.uuidString, draft: nil)
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        model.chooseResource(in: window)
        model.addResource(ticket)
        let persisted = try #require(window.persistedJSON)
        #expect(!persisted.contains("searchPick") && !persisted.contains("DEMO-2"))
        let full = String(decoding: try EngineJSON.encoder().encode(window), as: UTF8.self)
        #expect(!full.contains("searchPick") && !full.contains("DEMO-2"))
    }
}
