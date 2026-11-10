import AppKit
import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/tickets.md › Ticket list: Add to Bundle ▸ of the context menu, which adds the selected
/// tickets that are not done to an open bundle of their project.
@MainActor
@Suite("Add to Bundle")
struct AddToBundleTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    /// A connection that records the params of `bundles.update`, answers it with the bundle and
    /// refuses every other call.
    final class RecordingConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [BundlesUpdate.Params] = []

        var updates: [BundlesUpdate.Params] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? BundlesUpdate.Params {
                lock.withLock { recorded.append(params) }
                let bundle = TicketBundle(id: params.bundleID, title: "Bundle", created: Date(timeIntervalSince1970: 1_800_000_000),
                                          ticketIDs: params.ticketIDs ?? [])
                if let result = bundle as? M.Result { return result }
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    init() {
        // A menu item's action goes through `NSApp.sendAction`, which needs the application.
        _ = NSApplication.shared
    }

    private func ticket(_ id: String, _ status: TicketStatus = .todo) -> Ticket {
        Ticket(id: id, title: id, status: status, created: created)
    }

    private func bundle(_ id: String, _ title: String, _ status: BundleStatus = .todo, _ ticketIDs: [String] = []) -> TicketBundle {
        TicketBundle(id: id, title: title, status: status, created: created, ticketIDs: ticketIDs)
    }

    /// DEMO with its sub project MUS; WEB is another top-level project. DEMO-3 and MUS-2 are done.
    /// DEMO has the done bundle DEMO-B1 and the open bundles DEMO-B2, DEMO-B3 and DEMO-B10, MUS the
    /// open bundle MUS-B1 and the done bundle MUS-B2, and WEB only a done bundle.
    private func workspace(_ connection: any EngineConnection = OfflineConnection()) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.projects = [
            ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo", subprojectIDs: ["MUS"]),
            ProjectSummary(id: "MUS", name: "Music", rootPath: "/Users/example/Demo/music", parentID: "DEMO"),
            ProjectSummary(id: "WEB", name: "Website", rootPath: "/Users/example/Web"),
        ]
        let tickets = [
            ticket("DEMO-1"), ticket("DEMO-2", .inProgress), ticket("DEMO-3", .done), ticket("DEMO-9"), ticket("DEMO-10", .review),
            ticket("MUS-1"), ticket("MUS-2", .done), ticket("MUS-3"),
            ticket("WEB-1"),
        ]
        for ticket in tickets {
            workspace.tickets[ticket.projectID ?? "", default: [:]][ticket.id] = ticket
        }
        let bundles = [
            bundle("DEMO-B1", "Released", .done, ["DEMO-3"]),
            bundle("DEMO-B2", "Ticket list fixes", .todo, ["DEMO-1"]),
            bundle("DEMO-B3", "Sync", .inProgress, ["DEMO-10", "DEMO-1", "DEMO-2"]),
            bundle("DEMO-B10", "Later"),
            bundle("MUS-B1", "Player", .inProgress, ["MUS-1"]),
            bundle("MUS-B2", "Old player", .done, ["MUS-2"]),
            bundle("WEB-B1", "Launch", .done),
        ]
        for bundle in bundles {
            workspace.bundles[bundle.projectID ?? "", default: [:]][bundle.id] = bundle
        }
        return workspace
    }

    /// A window that shows the ticket list of `projectID`.
    private func window(projectID: String = "DEMO") -> WindowState {
        let window = WindowState(deviceID: "device")
        window.projectID = projectID
        window.section = .tickets
        return window
    }

    /// Add to Bundle for a selection of the ticket list of `projectID`.
    private func addToBundle(_ ids: Set<String>, projectID: String = "DEMO", in workspace: DeviceWorkspace) -> AddToBundleMenu {
        let projects = TicketListProjects(projectID: projectID, workspace: workspace)
        return TicketListProjects.addToBundle(ids, tickets: projects.tickets(in: workspace), bundles: workspace.bundles)
    }

    /// The context menu that a right-click on the selected rows of the ticket list builds.
    private func contextMenu(_ ids: Set<String>, window: WindowState, workspace: DeviceWorkspace) throws -> NSMenu {
        let view = TicketListView(window: window, workspace: workspace, projectID: window.projectID ?? "")
        let table = ItemTable<Ticket>(rows: [], columns: [], selection: ids, onSelectionChange: { _ in }, menu: { view.menu(for: $0) })
        return try #require(ItemTable<Ticket>.Coordinator(table).menu(forSelection: ids))
    }

    /// The submenu of Add to Bundle in that context menu.
    private func bundlesMenu(_ ids: Set<String>, window: WindowState, workspace: DeviceWorkspace) throws -> NSMenu {
        try #require(try contextMenu(ids, window: window, workspace: workspace).item(withTitle: "Add to Bundle")?.submenu)
    }

    // MARK: The submenu

    @Test("The submenu lists the open bundles of the selected tickets' project, newest first, as <ID> · <title>, and no done bundle")
    func openBundles() {
        let menu = addToBundle(["DEMO-9"], in: workspace())
        #expect(menu.isEnabled)
        // By bundle number: DEMO-B10 is newer than DEMO-B3. DEMO-B1 is done.
        #expect(menu.items.map(\.bundleID) == ["DEMO-B10", "DEMO-B3", "DEMO-B2"])
        #expect(menu.items.map(\.title) == ["DEMO-B10 · Later", "DEMO-B3 · Sync", "DEMO-B2 · Ticket list fixes"])
        #expect(menu.items.allSatisfy { $0.isEnabled && !$0.isChecked })
    }

    @Test("A bundle that lists every ticket to add is checked and disabled; one that lists only some of them stays enabled, without checkmark")
    func checkedBundles() {
        let workspace = workspace()
        // DEMO-B3 and DEMO-B2 list DEMO-1; DEMO-B10 lists nothing.
        let one = addToBundle(["DEMO-1"], in: workspace)
        #expect(one.items.map(\.isChecked) == [false, true, true])
        #expect(one.items.map(\.isEnabled) == [true, false, false])
        #expect(one.isEnabled)

        // DEMO-B3 lists both tickets, DEMO-B2 only DEMO-1.
        let two = addToBundle(["DEMO-1", "DEMO-2"], in: workspace)
        #expect(two.items.map(\.isChecked) == [false, true, false])
        #expect(two.items.map(\.isEnabled) == [true, false, true])
    }

    @Test("Done tickets in the selection are left out")
    func doneTickets() {
        let menu = addToBundle(["DEMO-3", "DEMO-1"], in: workspace())
        #expect(menu.ticketIDs == ["DEMO-1"])
        // DEMO-B3 and DEMO-B2 list DEMO-1, the only ticket to add: neither lists the done DEMO-3.
        #expect(menu.items.map(\.isChecked) == [false, true, true])
    }

    @Test("Add to Bundle is disabled, with nothing to list: no selection, tickets of several projects, every ticket done, no open bundle")
    func disabled() {
        let workspace = workspace()
        // DEMO-3 and MUS-2 are done; a done ticket of another project still mixes the projects.
        for ids: Set<String> in [[], ["DEMO-1", "MUS-3"], ["DEMO-1", "MUS-2"], ["DEMO-3"], ["DEMO-3", "MUS-2"]] {
            let menu = addToBundle(ids, in: workspace)
            #expect(!menu.isEnabled, "\(ids.sorted())")
            #expect(menu.items.isEmpty, "\(ids.sorted())")
        }
        // WEB has only a done bundle, then no bundle at all.
        #expect(!addToBundle(["WEB-1"], projectID: "WEB", in: workspace).isEnabled)
        workspace.bundles["WEB"] = [:]
        #expect(!addToBundle(["WEB-1"], projectID: "WEB", in: workspace).isEnabled)
        workspace.bundles["WEB"] = nil
        #expect(!addToBundle(["WEB-1"], projectID: "WEB", in: workspace).isEnabled)
    }

    @Test("A sub project's tickets in a parent's list get the sub project's open bundles")
    func subProject() {
        let workspace = workspace()
        let menu = addToBundle(["MUS-3"], in: workspace)
        #expect(menu.isEnabled)
        #expect(menu.items.map(\.title) == ["MUS-B1 · Player"])
        #expect(menu.items.map(\.isChecked) == [false])
        // MUS-B1 already lists MUS-1.
        #expect(addToBundle(["MUS-1"], in: workspace).items.map(\.isChecked) == [true])
    }

    @Test("A choice sends the bundle's tickets, then the tickets to add that it does not list yet, in ascending ticket number")
    func appendedTicketIDs() throws {
        let workspace = workspace()
        let menu = addToBundle(["DEMO-10", "DEMO-9", "DEMO-2", "DEMO-3"], in: workspace)
        #expect(menu.ticketIDs == ["DEMO-2", "DEMO-9", "DEMO-10"])

        // DEMO-B3 keeps its order DEMO-10, DEMO-1, DEMO-2 and gains DEMO-9.
        let sync = try #require(workspace.bundles["DEMO"]?["DEMO-B3"])
        #expect(AddToBundleMenu.ticketIDs(adding: menu.ticketIDs, to: sync) == ["DEMO-10", "DEMO-1", "DEMO-2", "DEMO-9"])
        // By number, not by text: DEMO-9 before DEMO-10, whatever the order they are given in.
        let later = try #require(workspace.bundles["DEMO"]?["DEMO-B10"])
        #expect(AddToBundleMenu.ticketIDs(adding: ["DEMO-10", "DEMO-9", "DEMO-2"], to: later) == ["DEMO-2", "DEMO-9", "DEMO-10"])
        // Nothing to add leaves the list as it is.
        #expect(AddToBundleMenu.ticketIDs(adding: ["DEMO-1", "DEMO-2"], to: sync) == sync.ticketIDs)
    }

    // MARK: The context menu

    @Test("A checked action of a table's context menu shows a checkmark")
    func checkedMenuItem() throws {
        let table = ItemTable<Ticket>(rows: [], columns: [], selection: [], onSelectionChange: { _ in }, menu: { _ in [
            .action("Plain") {},
            .action("Checked", enabled: false, checked: true) {},
        ] })
        let menu = try #require(ItemTable<Ticket>.Coordinator(table).menu(forSelection: ["DEMO-1"]))
        #expect(menu.items.map(\.state) == [.off, .on])
        #expect(menu.items.map(\.isEnabled) == [true, false])
    }

    @Test("Add to Bundle follows Create Bundle from Selection… in the ticket list's context menu and marks the bundles that list every ticket to add")
    func contextMenuItem() throws {
        let workspace = workspace()
        let window = window()
        let menu = try contextMenu(["DEMO-1"], window: window, workspace: workspace)
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
            == ["Implement", "Set Status", "Create Bundle from Selection…", "Add to Bundle", "-", "Copy ID", "-", "Delete…"])
        let item = try #require(menu.item(withTitle: "Add to Bundle"))
        #expect(item.isEnabled)
        let bundles = try #require(item.submenu).items
        #expect(bundles.map(\.title) == ["DEMO-B10 · Later", "DEMO-B3 · Sync", "DEMO-B2 · Ticket list fixes"])
        #expect(bundles.map(\.state) == [.off, .on, .on])
        #expect(bundles.map(\.isEnabled) == [true, false, false])

        // Disabled, it has no bundle to open a submenu with.
        for ids: Set<String> in [["DEMO-3"], ["DEMO-1", "MUS-3"]] {
            let disabled = try #require(try contextMenu(ids, window: window, workspace: workspace).item(withTitle: "Add to Bundle"))
            #expect(!disabled.isEnabled, "\(ids.sorted())")
            #expect(disabled.submenu?.items.isEmpty == true, "\(ids.sorted())")
        }
    }

    @Test("Choosing a bundle calls bundles.update with its tickets, then the tickets to add, and changes neither the section nor the selection")
    func choice() async throws {
        let connection = RecordingConnection()
        let workspace = workspace(connection)
        let window = window()
        // DEMO-3 is done; DEMO-B3 already lists DEMO-2.
        let selection: Set<String> = ["DEMO-10", "DEMO-9", "DEMO-2", "DEMO-3"]
        window.updateViewState(of: "DEMO") { $0.selectedTicketIDs = selection }

        var bundles = try bundlesMenu(selection, window: window, workspace: workspace)
        bundles.performActionForItem(at: bundles.indexOfItem(withTitle: "DEMO-B3 · Sync"))
        #expect(await eventually { connection.updates.count == 1 })
        bundles = try bundlesMenu(selection, window: window, workspace: workspace)
        bundles.performActionForItem(at: bundles.indexOfItem(withTitle: "DEMO-B10 · Later"))
        #expect(await eventually { connection.updates.count == 2 })
        #expect(connection.updates == [
            BundlesUpdate.Params(bundleID: "DEMO-B3", ticketIDs: ["DEMO-10", "DEMO-1", "DEMO-2", "DEMO-9"]),
            BundlesUpdate.Params(bundleID: "DEMO-B10", ticketIDs: ["DEMO-2", "DEMO-9", "DEMO-10"]),
        ])

        #expect(window.projectID == "DEMO" && window.section == .tickets)
        #expect(window.viewState.selectedTicketIDs == selection)
        #expect(window.sheet == nil)
        #expect(window.alert == nil)
    }

    @Test("A sub project's ticket in the parent's list goes into the sub project's bundle")
    func subProjectChoice() async throws {
        let connection = RecordingConnection()
        let workspace = workspace(connection)
        let window = window()
        let bundles = try bundlesMenu(["MUS-3"], window: window, workspace: workspace)
        #expect(bundles.items.map(\.title) == ["MUS-B1 · Player"])
        bundles.performActionForItem(at: 0)
        #expect(await eventually { !connection.updates.isEmpty })
        #expect(connection.updates == [BundlesUpdate.Params(bundleID: "MUS-B1", ticketIDs: ["MUS-1", "MUS-3"])])
        #expect(window.projectID == "DEMO" && window.section == .tickets)
    }

    @Test("A failure shows the alert Add to Bundle failed")
    func failure() async {
        // The offline connection refuses bundles.update.
        let workspace = workspace()
        let window = window()
        await TicketActions.addToBundle("DEMO-B10", ticketIDs: ["DEMO-1"], workspace: workspace, window: window)
        #expect(window.alert?.title == "Add to Bundle failed")
        #expect(window.alert?.message == "Offline.")
        #expect(window.section == .tickets)
    }

    @Test("A choice adds to the bundle as it is then: nothing left to add calls nothing, and a bundle that no longer exists fails")
    func bundleChangedMeanwhile() async {
        let connection = RecordingConnection()
        let workspace = workspace(connection)
        let window = window()
        // Another window added DEMO-9 while the menu was open: the bundle's new tickets are kept.
        workspace.bundles["DEMO"]?["DEMO-B10"]?.ticketIDs = ["DEMO-9"]
        await TicketActions.addToBundle("DEMO-B10", ticketIDs: ["DEMO-1", "DEMO-9"], workspace: workspace, window: window)
        #expect(connection.updates == [BundlesUpdate.Params(bundleID: "DEMO-B10", ticketIDs: ["DEMO-9", "DEMO-1"])])

        // The bundle got every ticket to add meanwhile.
        await TicketActions.addToBundle("DEMO-B2", ticketIDs: ["DEMO-1"], workspace: workspace, window: window)
        #expect(connection.updates.count == 1)
        #expect(window.alert == nil)

        // The bundle was deleted meanwhile.
        workspace.bundles["DEMO"]?["DEMO-B3"] = nil
        await TicketActions.addToBundle("DEMO-B3", ticketIDs: ["DEMO-9"], workspace: workspace, window: window)
        #expect(connection.updates.count == 1)
        #expect(window.alert?.title == "Add to Bundle failed")
        #expect(window.alert?.message == "Bundle DEMO-B3 not found.")
    }

    @Test("With an engine, a choice appends the tickets that are not done to the bundle of their project, which then shows its checkmark")
    func engine() async throws {
        try await withEngineApp { app, root in
            let workspace = app.localWorkspace
            #expect(await eventually { workspace.hasSnapshot })
            for (identifier, path, parent) in [("DEMO", "demo", nil), ("MUS", "demo/music", "DEMO")] as [(String, String, String?)] {
                _ = try await workspace.call(ProjectsCreate.self, ProjectsCreate.Params(
                    rootPath: root.appendingPathComponent(path).path, name: identifier, identifier: identifier, parentID: parent,
                    createDirectory: true))
            }
            func create(_ projectID: String, _ title: String) async throws -> String {
                try await workspace.call(TicketsCreate.self, TicketsCreate.Params(projectID: projectID, title: title, description: "Problem")).id
            }
            let first = try await create("DEMO", "First")
            let second = try await create("DEMO", "Second")
            let done = try await create("DEMO", "Done")
            _ = try await workspace.call(TicketsSetStatus.self, TicketsSetStatus.Params(ticketID: done, status: TicketStatus.done.rawValue))
            let fixes = try await workspace.call(BundlesCreate.self, BundlesCreate.Params(projectID: "DEMO", title: "Fixes", ticketIDs: [second])).id
            let listed = try await create("MUS", "Listed")
            let other = try await create("MUS", "Other")
            let player = try await workspace.call(BundlesCreate.self, BundlesCreate.Params(projectID: "MUS", title: "Player", ticketIDs: [listed])).id

            // A main window on DEMO loads the project and its descendants.
            #expect(await eventually { workspace.project("MUS")?.parentID == "DEMO" })
            let window = WindowState(deviceID: app.localDeviceID)
            app.registerMainWindow(window)
            window.activate(projectID: "DEMO")
            window.section = .tickets
            workspace.ensureProjectLoaded("DEMO")
            workspace.ensureDescendantsLoaded(of: "DEMO")
            #expect(await eventually {
                workspace.loadedProjectIDs.isSuperset(of: ["DEMO", "MUS"]) && workspace.tickets["DEMO"]?[done]?.status == .done
                    && workspace.bundles["DEMO"]?[fixes] != nil && workspace.tickets["MUS"]?[other] != nil
                    && workspace.bundles["MUS"]?[player] != nil
            })
            let selection: Set<String> = [first, second, done]
            window.updateViewState(of: "DEMO") { $0.selectedTicketIDs = selection }

            // The bundle lists the second ticket only: enabled, without checkmark.
            let bundles = try bundlesMenu(selection, window: window, workspace: workspace)
            #expect(bundles.items.map(\.title) == ["\(fixes) · Fixes"])
            #expect(bundles.items.map(\.state) == [.off])
            bundles.performActionForItem(at: 0)

            // The first ticket goes to the end and the done one is left out; the live update reaches the workspace.
            #expect(await eventually { workspace.bundles["DEMO"]?[fixes]?.ticketIDs == [second, first] })
            #expect(workspace.bundles["DEMO"]?[fixes]?.status == .todo)
            #expect(window.projectID == "DEMO" && window.section == .tickets)
            #expect(window.viewState.selectedTicketIDs == selection)
            #expect(window.alert == nil)

            // The bundle now lists every ticket to add.
            let again = try bundlesMenu(selection, window: window, workspace: workspace)
            #expect(again.items.map(\.state) == [.on])
            #expect(again.items.map(\.isEnabled) == [false])

            // A sub project's ticket in DEMO's list goes into the sub project's bundle.
            let subProject = try bundlesMenu([other], window: window, workspace: workspace)
            #expect(subProject.items.map(\.title) == ["\(player) · Player"])
            subProject.performActionForItem(at: 0)
            #expect(await eventually { workspace.bundles["MUS"]?[player]?.ticketIDs == [listed, other] })
            #expect(window.projectID == "DEMO" && window.section == .tickets)
            #expect(window.alert == nil)

            // Tickets of the project and of its sub project together, then a project without open bundle.
            #expect(try contextMenu([first, other], window: window, workspace: workspace).item(withTitle: "Add to Bundle")?.isEnabled == false)
            _ = try await workspace.call(BundlesSetStatus.self, BundlesSetStatus.Params(bundleID: fixes, status: BundleStatus.done.rawValue))
            #expect(await eventually { workspace.bundles["DEMO"]?[fixes]?.status == .done })
            #expect(try contextMenu([first], window: window, workspace: workspace).item(withTitle: "Add to Bundle")?.isEnabled == false)
        }
    }
}

/// Waits until a condition holds; the bound only ends a test that fails.
@MainActor
private func eventually(seconds: Int = 60, _ condition: () -> Bool) async -> Bool {
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
