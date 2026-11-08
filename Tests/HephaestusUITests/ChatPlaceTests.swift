import AppKit
import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/chats.md › Where chats appear and docs/ui.md › Resolving a target: the chats the Chats
/// section lists, and where a `chat` target shows a chat.
@MainActor
@Suite("Where chats are listed")
struct ChatPlaceTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func chat(_ kind: ChatKind, ticketID: TicketID? = nil, bundleID: BundleID? = nil, orchestrator: ChatID? = nil,
                      minutes: Double) -> ChatMeta {
        let date = created.addingTimeInterval(minutes * 60)
        return ChatMeta(id: UUID(), kind: kind, ticketID: ticketID, bundleID: bundleID, orchestratorChatID: orchestrator,
                        created: date, updated: date, projectID: "DEMO")
    }

    /// DEMO holds the ticket DEMO-1 and the bundle DEMO-B1; DEMO-2 and DEMO-B2 were deleted.
    private func workspace(_ chats: [ChatMeta], loaded: Bool = true) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        for meta in chats {
            workspace.chats[meta.id.uuidString] = meta
        }
        if loaded {
            workspace.tickets["DEMO"] = ["DEMO-1": Ticket(id: "DEMO-1", title: "Kept", created: created)]
            workspace.bundles["DEMO"] = ["DEMO-B1": TicketBundle(id: "DEMO-B1", title: "Kept", created: created, ticketIDs: ["DEMO-1"])]
        }
        return workspace
    }

    @Test("Each kind of chat is listed on its existing ticket or bundle, otherwise in the Chats section")
    func places() {
        let bundleChat = chat(.bundle, bundleID: "DEMO-B1", minutes: 0)
        let cases: [(ChatMeta, ChatListPlace)] = [
            (chat(.project, minutes: 0), .chatsSection),
            (chat(.feedback, minutes: 0), .chatsSection),
            (chat(.feedback, ticketID: "DEMO-1", minutes: 0), .chatsSection),
            (chat(.ticket, ticketID: "DEMO-1", minutes: 0), .ticket("DEMO-1")),
            (chat(.ticket, ticketID: "DEMO-1", orchestrator: bundleChat.id, minutes: 0), .ticket("DEMO-1")),
            (chat(.ticket, ticketID: "DEMO-2", minutes: 0), .chatsSection),
            (chat(.ticket, ticketID: "DEMO-2", orchestrator: bundleChat.id, minutes: 0), .chatsSection),
            (bundleChat, .bundle("DEMO-B1")),
            (chat(.bundle, bundleID: "DEMO-B2", minutes: 0), .chatsSection),
            (chat(.ci, ticketID: "DEMO-1", orchestrator: UUID(), minutes: 0), .ticket("DEMO-1")),
            (chat(.ci, ticketID: "DEMO-2", orchestrator: UUID(), minutes: 0), .chatsSection),
            (chat(.ci, bundleID: "DEMO-B1", orchestrator: bundleChat.id, minutes: 0), .bundle("DEMO-B1")),
            (chat(.ci, bundleID: "DEMO-B2", orchestrator: UUID(), minutes: 0), .chatsSection),
        ]
        let workspace = workspace(cases.map(\.0))
        for (meta, place) in cases {
            #expect(workspace.listedPlace(of: meta) == place, "\(meta.kind) \(meta.ticketID ?? meta.bundleID ?? "")")
        }

        // While the project's tickets and bundles are not loaded, a linked chat counts as on them.
        let loading = self.workspace(cases.map(\.0), loaded: false)
        #expect(loading.listedPlace(of: chat(.ticket, ticketID: "DEMO-2", minutes: 0)) == .ticket("DEMO-2"))
        #expect(loading.listedPlace(of: chat(.bundle, bundleID: "DEMO-B2", minutes: 0)) == .bundle("DEMO-B2"))
        #expect(loading.listedPlace(of: chat(.ci, bundleID: "DEMO-B2", minutes: 0)) == .bundle("DEMO-B2"))
        #expect(loading.listedPlace(of: chat(.feedback, ticketID: "DEMO-2", minutes: 0)) == .chatsSection)
    }

    @Test("The Chats section lists project chats, feedback chats and the chats of deleted tickets and bundles, newest first")
    func sectionList() {
        let project = chat(.project, minutes: 1)
        let feedback = chat(.feedback, ticketID: "DEMO-1", minutes: 6)
        let ticketChat = chat(.ticket, ticketID: "DEMO-1", minutes: 9)
        let bundleChat = chat(.bundle, bundleID: "DEMO-B1", minutes: 8)
        let ciChat = chat(.ci, ticketID: "DEMO-1", orchestrator: ticketChat.id, minutes: 10)
        let orchestrated = chat(.ticket, ticketID: "DEMO-1", orchestrator: bundleChat.id, minutes: 11)
        let deletedTicketChat = chat(.ticket, ticketID: "DEMO-2", minutes: 3)
        let deletedBundleChat = chat(.bundle, bundleID: "DEMO-B2", minutes: 4)
        let deletedBundleCI = chat(.ci, bundleID: "DEMO-B2", orchestrator: deletedBundleChat.id, minutes: 2)
        let all = [project, feedback, ticketChat, bundleChat, ciChat, orchestrated, deletedTicketChat, deletedBundleChat, deletedBundleCI]
        let workspace = workspace(all)
        #expect(ChatsSectionView.listedChats(all, hidesClosed: false, workspace: workspace).map(\.id)
            == [feedback.id, deletedBundleChat.id, deletedTicketChat.id, deletedBundleCI.id, project.id])

        // A project with ticket, bundle and CI chats only lists nothing: the section shows its empty
        // state.
        #expect(ChatsSectionView.listedChats([ticketChat, bundleChat, ciChat, orchestrated], hidesClosed: false,
                                             workspace: workspace).isEmpty)
    }

    @Test("A chat target resolves to where the chat is listed")
    func targetPlace() async {
        let project = chat(.project, minutes: 0)
        let feedback = chat(.feedback, ticketID: "DEMO-1", minutes: 0)
        let ticketChat = chat(.ticket, ticketID: "DEMO-1", minutes: 0)
        let bundleChat = chat(.bundle, bundleID: "DEMO-B1", minutes: 0)
        let ticketCI = chat(.ci, ticketID: "DEMO-1", orchestrator: ticketChat.id, minutes: 0)
        let bundleCI = chat(.ci, bundleID: "DEMO-B1", orchestrator: bundleChat.id, minutes: 0)
        let deleted = chat(.ticket, ticketID: "DEMO-2", minutes: 0)
        let workspace = workspace([project, feedback, ticketChat, bundleChat, ticketCI, bundleCI, deleted])
        func place(_ meta: ChatMeta) async -> ChatListPlace {
            await ChatNavigator.place(ofChat: meta.id.uuidString, in: workspace)
        }
        #expect(await place(project) == .chatsSection)
        #expect(await place(feedback) == .chatsSection)
        #expect(await place(ticketChat) == .ticket("DEMO-1"))
        #expect(await place(bundleChat) == .bundle("DEMO-B1"))
        #expect(await place(ticketCI) == .ticket("DEMO-1"))
        #expect(await place(bundleCI) == .bundle("DEMO-B1"))
        #expect(await place(deleted) == .chatsSection)
        #expect(await ChatNavigator.place(ofChat: UUID().uuidString, in: workspace) == .chatsSection)
    }

    @Test("Navigating to a chat selects its ticket's or bundle's Chats tab, or the Chats section")
    func navigation() async throws {
        try await withEngineApp { app, root in
            let workspace = app.localWorkspace
            #expect(await eventually { workspace.hasSnapshot })
            _ = try await workspace.call(ProjectsCreate.self, ProjectsCreate.Params(
                rootPath: root.appendingPathComponent("demo").path, name: "Demo", identifier: "DEMO", createDirectory: true))
            let kept = try await workspace.call(TicketsCreate.self, TicketsCreate.Params(projectID: "DEMO", title: "Kept", description: "Problem"))
            let gone = try await workspace.call(TicketsCreate.self, TicketsCreate.Params(projectID: "DEMO", title: "Gone", description: "Problem"))
            let bundle = try await workspace.call(BundlesCreate.self, BundlesCreate.Params(projectID: "DEMO", title: "Bundle", ticketIDs: [kept.id]))
            func create(_ kind: ChatKind, ticketID: TicketID? = nil, bundleID: BundleID? = nil) async throws -> ChatMeta {
                try await workspace.call(ChatsCreate.self, ChatsCreate.Params(projectID: "DEMO", kind: kind, ticketID: ticketID, bundleID: bundleID))
            }
            let projectChat = try await create(.project)
            let ticketChat = try await create(.ticket, ticketID: kept.id)
            let bundleChat = try await create(.bundle, bundleID: bundle.id)
            let goneChat = try await create(.ticket, ticketID: gone.id)
            #expect(await eventually {
                [projectChat, ticketChat, bundleChat, goneChat].allSatisfy { workspace.chats[$0.id.uuidString] != nil }
            })

            let window = WindowState(deviceID: app.localDeviceID)
            app.registerMainWindow(window)
            window.activate(projectID: "DEMO")
            window.section = .dashboard

            // The tickets are not loaded yet: the navigation waits for them.
            await window.navigate(to: .chat(chatID: ticketChat.id))
            #expect(window.section == .tickets)
            #expect(window.viewState.selectedTicketIDs == [kept.id])
            #expect(window.viewState.ticketTab == .chats)
            #expect(window.viewState.chatsTabSelection[kept.id] == ticketChat.id.uuidString)

            await window.navigate(to: .chat(chatID: bundleChat.id))
            #expect(window.section == .bundles)
            #expect(window.viewState.selectedBundleID == bundle.id)
            #expect(window.viewState.bundleTab == .chats)
            #expect(window.viewState.chatsTabSelection[bundle.id] == bundleChat.id.uuidString)

            await window.navigate(to: .chat(chatID: projectChat.id))
            #expect(window.section == .chats)
            #expect(window.viewState.selectedChatIDs == [projectChat.id.uuidString])

            // A CI chat of the ticket shows under its orchestrator in the ticket's Chats tab.
            let ciChat = ChatMeta(id: UUID(), kind: .ci, ticketID: kept.id, orchestratorChatID: ticketChat.id, created: Date(),
                                  projectID: "DEMO")
            workspace.chats[ciChat.id.uuidString] = ciChat
            window.section = .dashboard
            await window.navigate(to: .chat(chatID: ciChat.id))
            #expect(window.section == .tickets)
            #expect(window.viewState.chatsTabSelection[kept.id] == ciChat.id.uuidString)

            // Once its ticket is deleted, a ticket chat shows in the Chats section.
            workspace.tickets["DEMO"]?[gone.id] = nil
            await window.navigate(to: .chat(chatID: goneChat.id))
            #expect(window.section == .chats)
            #expect(window.viewState.selectedChatIDs == [goneChat.id.uuidString])
        }
    }
}

/// Waits until a condition holds, at most `seconds`.
@MainActor
private func eventually(seconds: Int = 5, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<(seconds * 100) {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// An app on an engine with its own temporary data directory, and a folder for its projects.
@MainActor
private func withEngineApp(_ check: (AppModel, URL) async throws -> Void) async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = folder.appendingPathComponent("Data", isDirectory: true)
    let projects = folder.appendingPathComponent("Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: SilentClaudeLauncher()))
    let connection = await LocalEngineConnection(engine: engine)
    let app = AppModel(environment: LaunchEnvironment(dataDirectory: data), engine: engine,
                       appVersion: AppVersion(version: "0.0.0", build: 0), connection: connection, restartWindows: nil)
    do {
        try await check(app, projects)
    } catch {
        connection.close()
        await engine.shutdown()
        throw error
    }
    connection.close()
    await engine.shutdown()
}

/// A launcher that starts nothing: no Claude process runs.
private struct SilentClaudeLauncher: ClaudeProcessLauncher {}
