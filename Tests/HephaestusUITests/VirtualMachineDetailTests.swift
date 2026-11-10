import AppKit
import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/virtual-machines.md › Detail, › Linked item and docs/ui.md › WindowState, › Resolving a
/// target: the window state of the detail of a virtual machine, its linked item, the navigation
/// to it and leaving it when the virtual machine is deleted. No test starts a virtual machine.
@MainActor
@Suite("Virtual machine detail")
struct VirtualMachineDetailTests {
    nonisolated static let vmID = UUID(uuidString: "7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C")!

    static func machine(_ id: UUID = vmID, name: String = "Menu checks") -> VirtualMachine {
        VirtualMachine(id: id, name: name, imageID: UUID(uuidString: "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F")!, version: "27.2.1",
                       build: "26B131", cores: 4, memoryGB: 8, created: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Showing the detail leaves the section unselected; selecting any section, the same one included, leaves it")
    func showAndLeave() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .tickets
        window.shownVirtualMachineID = Self.vmID
        #expect(window.shownSection == nil)
        #expect(window.section == .tickets)
        #expect(!window.isRowSelected(.tickets))
        window.section = .tickets
        #expect(window.shownVirtualMachineID == nil)
        #expect(window.shownSection == .tickets)
        window.shownVirtualMachineID = Self.vmID
        window.section = .costs
        #expect(window.shownVirtualMachineID == nil && window.shownSection == .costs)
    }

    @Test("The detail, the Global Memories view, the Internal Skills view and a sub project's Dashboard leave one another")
    func otherViews() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.projectID = "DEMO"
        window.showsGlobalMemories = true
        window.shownVirtualMachineID = Self.vmID
        #expect(!window.showsGlobalMemories && window.shownVirtualMachineID == Self.vmID)
        window.showsGlobalMemories = true
        #expect(window.showsGlobalMemories && window.shownVirtualMachineID == nil)

        window.showsInternalSkills = true
        window.shownVirtualMachineID = Self.vmID
        #expect(!window.showsInternalSkills && !window.showsGlobalMemories)
        window.showsInternalSkills = true
        #expect(window.shownVirtualMachineID == nil)

        window.showSubProject("SUB")
        window.shownVirtualMachineID = Self.vmID
        #expect(window.subProjectDashboardID == nil)
        window.showSubProject("SUB")
        #expect(window.subProjectDashboardID == "SUB" && window.shownVirtualMachineID == nil)

        // A switch of project keeps the detail; a switch of device leaves it.
        window.shownVirtualMachineID = Self.vmID
        window.projectID = "OTHER"
        #expect(window.shownVirtualMachineID == Self.vmID)
        window.deviceID = "remote"
        #expect(window.shownVirtualMachineID == nil)
    }

    @Test("The detail is encoded with the window's state and never persisted: a restored window shows its section")
    func coding() throws {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .docs
        window.shownVirtualMachineID = Self.vmID
        let json = String(decoding: try EngineJSON.encode(window), as: UTF8.self)
        #expect(json.contains(#""shownVirtualMachineID":"7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C""#))
        let decoded = try EngineJSON.decode(WindowState.self, from: Data(json.utf8))
        #expect(decoded.shownVirtualMachineID == Self.vmID && decoded.section == .docs && decoded.shownSection == nil)

        let persisted = try #require(window.persistedJSON)
        #expect(!persisted.contains("shownVirtualMachineID"))
        let restored = try #require(WindowState.restored(fromJSON: persisted))
        #expect(restored.shownVirtualMachineID == nil && restored.shownSection == .docs)
    }

    @Test("The composer links the shown virtual machine, with display, its name and its line, and nothing else")
    func linkedItem() {
        var state = ProjectViewState()
        state.selectedTicketIDs = ["DEMO-1"]
        let ticket = Ticket(id: "DEMO-1", title: "T", created: Date())
        #expect(state.openItems(in: nil, virtualMachineID: Self.vmID).map(\.key) == ["virtualMachine:7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C"])
        func linked(_ machines: [VirtualMachine]) -> [LinkedItem] {
            LinkedItems.linked(state: state, section: nil, tickets: ["DEMO-1": ticket], bundles: [:], chats: [:], webTabs: [],
                               virtualMachineID: Self.vmID, virtualMachines: machines)
        }
        let items = linked([Self.machine(UUID(), name: "Other"), Self.machine()])
        #expect(items.map(\.name) == ["Menu checks"])
        #expect(items.map(\.text) == ["virtual machine “Menu checks” (7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C)"])
        #expect(items.map(\.line) == ["Open in the app: virtual machine “Menu checks” (7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C)"])
        #expect(items.first?.chatLinkedItem == ChatLinkedItem(kind: .virtualMachine, name: "Menu checks",
                                                              text: "virtual machine “Menu checks” (7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C)"))
        #expect(ChatLinkedItemKind.virtualMachine.symbol == "display")
        // A virtual machine that the workspace does not hold is not linked.
        #expect(linked([]).isEmpty)

        // × unlinks it while the detail shows; it is linked again the next time.
        state.unlinkedItems = ["virtualMachine:7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C"]
        #expect(linked([Self.machine()]).isEmpty)
        state.forgetClosedUnlinkedItems(in: nil, virtualMachineID: Self.vmID)
        #expect(state.unlinkedItems.count == 1)
        state.forgetClosedUnlinkedItems(in: .tickets)
        #expect(state.unlinkedItems.isEmpty)
        // Without the detail, the section's items are linked as before.
        #expect(LinkedItems.linked(state: state, section: .tickets, tickets: ["DEMO-1": ticket], bundles: [:], chats: [:],
                                   webTabs: []).map(\.name) == ["DEMO-1"])
    }

    @Test("A virtualMachine target shows the detail without changing the project or the section, and is ignored without its virtual machine")
    func navigation() async throws {
        try await withVMApp(machines: [Self.machine()]) { app, root in
            let workspace = app.localWorkspace
            #expect(await eventually { workspace.isConnected && workspace.hasSnapshot })
            let window = WindowState(deviceID: app.localDeviceID)
            app.registerMainWindow(window)

            // Without any project: the detail takes the welcome view's place. The workspace reads
            // the virtual machines for the navigation.
            #expect(workspace.projects.isEmpty && workspace.virtualMachines == nil)
            await window.navigate(to: .virtualMachine(vmID: Self.vmID))
            #expect(window.shownVirtualMachineID == Self.vmID && window.projectID == nil)
            #expect(workspace.virtualMachine(Self.vmID)?.state == .stopped)

            _ = try await workspace.call(ProjectsCreate.self, ProjectsCreate.Params(
                rootPath: root.appendingPathComponent("demo").path, name: "Demo", identifier: "DEMO", createDirectory: true))
            #expect(await eventually { workspace.project("DEMO") != nil })
            window.activate(projectID: "DEMO")
            window.section = .tickets
            #expect(window.shownVirtualMachineID == nil)
            window.showsGlobalMemories = true
            await window.navigate(to: .virtualMachine(vmID: Self.vmID))
            #expect(window.shownVirtualMachineID == Self.vmID && !window.showsGlobalMemories)
            #expect(window.projectID == "DEMO" && window.section == .tickets && window.shownSection == nil)

            // No virtual machine has this id: nothing changes.
            window.section = .docs
            await window.navigate(to: .virtualMachine(vmID: UUID()))
            #expect(window.shownVirtualMachineID == nil && window.shownSection == .docs)

            // Another target leaves the detail.
            await window.navigate(to: .virtualMachine(vmID: Self.vmID))
            await window.navigate(to: .section(projectID: "DEMO", section: .costs))
            #expect(window.shownVirtualMachineID == nil && window.shownSection == .costs)

            // The screen shows only on the Mac that runs the virtual machine.
            let remote = DeviceWorkspace(deviceID: "remote", connection: OfflineConnection(), isLocal: false)
            remote.virtualMachines = VMList(machines: [Self.machine()], runningCount: 0)
            await window.showVirtualMachine(Self.vmID, in: remote)
            #expect(window.shownVirtualMachineID == nil)
        }
    }

    @Test("Show brings the detail to the most recently key main window that shows This Mac; deleting the virtual machine leaves it")
    func showAndDelete() async throws {
        let other = UUID(uuidString: "2E9F4C18-6A3D-4B7E-9C5F-8D1A0B2C3E4F")!
        try await withVMApp(machines: [Self.machine(), Self.machine(other, name: "Kept")]) { app, _ in
            let workspace = app.localWorkspace
            #expect(await eventually { workspace.isConnected && workspace.hasSnapshot })
            let first = WindowState(deviceID: app.localDeviceID)
            let second = WindowState(deviceID: app.localDeviceID)
            let remote = WindowState(deviceID: "remote")
            app.registerMainWindow(first)
            app.registerMainWindow(second)
            #expect(app.mainWindowsByKeyOrder.first === second)
            first.section = .chats
            second.section = .docs
            remote.shownVirtualMachineID = Self.vmID

            app.showVirtualMachine(Self.vmID)
            #expect(await eventually { second.shownVirtualMachineID == Self.vmID })
            #expect(first.shownVirtualMachineID == nil)
            await first.navigate(to: .virtualMachine(vmID: Self.vmID))
            await workspace.loadVirtualMachines()
            #expect(workspace.virtualMachines?.machines.map(\.name).sorted() == ["Kept", "Menu checks"])

            // Deleting another virtual machine changes nothing.
            _ = try await workspace.call(VMsDelete.self, VMParams(vmID: other))
            #expect(await eventually { workspace.virtualMachines?.machines.count == 1 })
            #expect(first.shownVirtualMachineID == Self.vmID && second.shownVirtualMachineID == Self.vmID)

            // Deleting the shown one: every window goes back to its section.
            _ = try await workspace.call(VMsDelete.self, VMParams(vmID: Self.vmID))
            #expect(await eventually { first.shownVirtualMachineID == nil && second.shownVirtualMachineID == nil })
            #expect(first.shownSection == .chats && second.shownSection == .docs)
            #expect(workspace.virtualMachines == VMList())
            // A window of another device is not this Mac's.
            #expect(remote.shownVirtualMachineID == Self.vmID)
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

/// An app on a started engine whose temporary data directory holds the files of `machines`, which
/// the engine reads at launch, stopped, and a folder for its projects. The engine reaches no
/// image and starts no virtual machine.
@MainActor
private func withVMApp(machines: [VirtualMachine], _ check: (AppModel, URL) async throws -> Void) async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = folder.appendingPathComponent("Data", isDirectory: true)
    let projects = folder.appendingPathComponent("Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    for machine in machines {
        try VirtualMachineStore.write(machine, to: DataDirectory(url: data))
    }
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: SilentClaudeLauncher()))
    await engine.start()
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
