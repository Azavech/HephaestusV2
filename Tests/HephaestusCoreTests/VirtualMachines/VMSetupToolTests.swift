import Foundation
import Testing
@testable import HephaestusCore

/// A screen of a setup virtual machine that records the actions the VM tools send it
/// (docs/virtual-machines.md › Screen of the setup virtual machine).
@MainActor
final class FakeGuestScreen: GuestScreen {
    enum Call: Equatable {
        case screenshot
        case click(x: Int, y: Int, button: String, count: Int)
        case drag(fromX: Int, fromY: Int, toX: Int, toY: Int)
        case scroll(x: Int, y: Int, deltaX: Int, deltaY: Int)
        case type(String)
        case key(String, [String])
        case close
    }

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private(set) var calls: [Call] = []
    /// True: the screen shows nothing yet, as while the guest starts up.
    var showsNothing = false

    func screenshot(name: String) async throws -> GuestScreenshot {
        calls.append(.screenshot)
        if showsNothing { throw GuestScreenError("The screen of “\(name)” shows nothing yet.") }
        return GuestScreenshot(png: Self.png, width: 2560, height: 1600)
    }

    func click(x: Int, y: Int, button: String, count: Int) async throws { calls.append(.click(x: x, y: y, button: button, count: count)) }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws { calls.append(.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY)) }
    func scroll(x: Int, y: Int, deltaX: Int, deltaY: Int) async throws { calls.append(.scroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY)) }
    func type(_ text: String) async throws { calls.append(.type(text)) }
    func key(_ key: String, modifiers: [String]) async throws { calls.append(.key(key, modifiers)) }
    func close() { calls.append(.close) }
}

/// Makes a `FakeGuestScreen` for each setup virtual machine.
final class FakeGuestScreens: GuestScreenProviding, @unchecked Sendable {
    @MainActor private(set) var screens: [FakeGuestScreen] = []

    @MainActor func screen(for machine: any GuestMachine) -> (any GuestScreen)? {
        let screen = FakeGuestScreen()
        screens.append(screen)
        return screen
    }
}

/// docs/virtual-machines.md › The setup virtual machine: the VM tools on the setup virtual machine of
/// an image, through its screen before its agent connects, with stand-ins for the machine, its agent
/// and its screen. No test starts a virtual machine.
@Suite("VM tools on a setup virtual machine")
struct VMSetupToolTests {
    typealias Chat = VMToolEngineTests.Chat

    /// A test engine with the project DEMO and an image in Needs setup whose setup runs, its agent
    /// not connected; `screens` gives the screens of the setup virtual machines.
    static func withSetup<T>(screens: FakeGuestScreens? = FakeGuestScreens(),
                             _ body: (Engine, LocalEngineConnection, VMSetupSession, FakeGuestMachine, VMImage, Chat) async throws -> T)
        async throws -> T {
        try await withVMEngine(guestScreens: screens, prepare: { data in
            let root = data.url.deletingLastPathComponent().appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try ProjectFileStore.write(Project(id: "DEMO", name: "Demo", created: ISODate.date(from: "2026-10-31T12:00:00Z")!),
                                       to: ProjectFolder(root: root))
            try DeviceFileStore.write(Registry(projects: [root.path]), to: data)
        }) { engine, connection, provisioner, _ in
            await engine.useVMToolTimings(VMToolEngineTests.timings())
            let image = try await addInstalledImage(connection)
            let session = try await engine.beginImageSetup(image.id)
            await MainActor.run { session.useShortWaits() }
            let machine = try #require(await MainActor.run { provisioner.machines.last })
            let chat = try await VMToolEngineTests.newChat(connection)
            return try await body(engine, connection, session, machine, image, chat)
        }
    }

    static func screenCalls(_ screens: FakeGuestScreens) async -> [FakeGuestScreen.Call] {
        await MainActor.run { screens.screens.flatMap(\.calls) }
    }

    @Test("vm_list lists the setup virtual machine last, with the image's id, Set Up macOS <version>, Started by You and setup true")
    func list() async throws {
        try await Self.withSetup { engine, _, _, _, image, chat in
            let list = try await VMToolEngineTests.list(engine, chat)
            #expect(list.map(\.id) == [image.id])
            let setup = try #require(list.last)
            #expect(setup.name == "Set Up macOS \(image.version)" && setup.imageID == image.id && setup.version == image.version)
            #expect(setup.startedBy == "You" && !setup.byClaude && setup.setup && setup.state == .running)
            #expect(setup.cores == 2 && setup.memoryGB == 4 && setup.runningTime == "0 min" && !setup.agentConnected)
        }
    }

    @Test("Before the agent connects, screenshots, clicks, drags, scrolls, keys and text go through the screen, without a wait")
    func throughTheScreen() async throws {
        let screens = FakeGuestScreens()
        try await Self.withSetup(screens: screens) { engine, _, _, machine, image, chat in
            let actor = chat.actor
            let shot = try await engine.call(VMToolsScreenshot.self, .init(chatID: chat.id, vmID: image.id), actor: actor)
            #expect(shot.width == 2560 && shot.height == 1600)
            #expect(try Data(contentsOf: URL(fileURLWithPath: shot.path)) == FakeGuestScreen.png)
            #expect(shot.path.hasSuffix(".png") && URL(fileURLWithPath: shot.path).lastPathComponent.hasPrefix("vm-\(image.id.uuidString)-"))
            _ = try await engine.call(VMToolsClick.self, .init(chatID: chat.id, vmID: image.id, x: 10, y: 20, count: 2), actor: actor)
            _ = try await engine.call(VMToolsDrag.self, .init(chatID: chat.id, vmID: image.id, fromX: 1, fromY: 2, toX: 3, toY: 4), actor: actor)
            _ = try await engine.call(VMToolsScroll.self, .init(chatID: chat.id, vmID: image.id, x: 5, y: 6, deltaY: 40), actor: actor)
            _ = try await engine.call(VMToolsType.self, .init(chatID: chat.id, vmID: image.id, text: "example\n"), actor: actor)
            _ = try await engine.call(VMToolsKey.self, .init(chatID: chat.id, vmID: image.id, key: "⇧⌘K"), actor: actor)
            #expect(await Self.screenCalls(screens) == [
                .screenshot, .click(x: 10, y: 20, button: "left", count: 2), .drag(fromX: 1, fromY: 2, toX: 3, toY: 4),
                .scroll(x: 5, y: 6, deltaX: 0, deltaY: 40), .type("example\n"), .key("k", ["shift", "command"]),
            ])
            // One screen for the setup, and nothing for the agent.
            #expect(await MainActor.run { screens.screens.count } == 1)
            #expect(await MainActor.run { machine.agentCalls }.isEmpty)
        }
    }

    @Test("Once the agent is connected, the actions go through the agent; the screen closes when the setup ends")
    func throughTheAgent() async throws {
        let screens = FakeGuestScreens()
        try await Self.withSetup(screens: screens) { engine, _, session, machine, image, chat in
            _ = try await engine.call(VMToolsClick.self, .init(chatID: chat.id, vmID: image.id, x: 1, y: 1), actor: chat.actor)
            await MainActor.run { machine.agentConnects(sip: .enabled) }
            _ = try await engine.call(VMToolsClick.self, .init(chatID: chat.id, vmID: image.id, x: 7, y: 8), actor: chat.actor)
            _ = try await engine.call(VMToolsShell.self, .init(chatID: chat.id, vmID: image.id, command: "csrutil status"), actor: chat.actor)
            let calls = await MainActor.run { machine.agentCalls }
            #expect(calls.map(\.method) == ["click", "exec"])
            #expect(calls.first?.params["x"] == .int(7))
            #expect(try await VMToolEngineTests.list(engine, chat).last?.agentConnected == true)
            await session.stop()
            #expect(await Self.screenCalls(screens) == [.click(x: 1, y: 1, button: "left", count: 1), .close])
            // The setup has ended: the virtual machine has left the list.
            let error = await engineError {
                try await engine.call(VMToolsClick.self, .init(chatID: chat.id, vmID: image.id, x: 1, y: 1), actor: chat.actor)
            }
            #expect(error == EngineError.notFound("Virtual machine", image.id.uuidString))
        }
    }

    @Test("The actions that need the agent wait for it, then fail; vm_stop refuses the setup virtual machine; a screen that shows nothing fails")
    func errors() async throws {
        let screens = FakeGuestScreens()
        try await Self.withSetup(screens: screens) { engine, _, _, _, image, chat in
            let name = "Set Up macOS \(image.version)"
            #expect(await engineError {
                try await engine.call(VMToolsShell.self, .init(chatID: chat.id, vmID: image.id, command: "true"), actor: chat.actor)
            } == EngineError(.unavailable, "The agent of “\(name)” is not connected."))
            #expect(await engineError {
                try await engine.call(VMToolsStop.self, .init(chatID: chat.id, vmID: image.id), actor: chat.actor)
            } == EngineError(.forbidden, "“\(name)” was started by the user: only the user stops it."))
            _ = try await engine.call(VMToolsScreenshot.self, .init(chatID: chat.id, vmID: image.id), actor: chat.actor)
            await MainActor.run { screens.screens.first?.showsNothing = true }
            #expect(await engineError {
                try await engine.call(VMToolsScreenshot.self, .init(chatID: chat.id, vmID: image.id), actor: chat.actor)
            } == EngineError(.unavailable, "The screen of “\(name)” shows nothing yet."))
        }
    }

    @Test("Without screens in the engine, the actions through the screen fail")
    func noScreens() async throws {
        try await Self.withSetup(screens: nil) { engine, _, _, _, image, chat in
            #expect(await engineError {
                try await engine.call(VMToolsClick.self, .init(chatID: chat.id, vmID: image.id, x: 1, y: 1), actor: chat.actor)
            } == EngineError(.unavailable, "The screen of “Set Up macOS \(image.version)” cannot be driven by this app."))
        }
    }

    @Test("vm_setup_recovery returns once the restart has begun, then the virtual machine starts into Recovery; it is refused while it restarts")
    func recovery() async throws {
        try await Self.withSetup { engine, _, session, machine, image, chat in
            await MainActor.run { machine.confirmsStopRequests = true }
            _ = try await engine.call(VMToolsSetupRecovery.self, .init(chatID: chat.id, imageID: image.id), actor: chat.actor)
            await waitUntil { await MainActor.run { machine.calls.contains(.start(recovery: true)) && session.phase == .running } }
            #expect(await MainActor.run { machine.calls } == [.start(recovery: false), .requestStop, .start(recovery: true)])
            // While it restarts, the call is refused.
            await MainActor.run { machine.confirmsStopRequests = false }
            _ = try await engine.call(VMToolsSetupRecovery.self, .init(chatID: chat.id, imageID: image.id), actor: chat.actor)
            #expect(await engineError {
                try await engine.call(VMToolsSetupRecovery.self, .init(chatID: chat.id, imageID: image.id), actor: chat.actor)
            } == EngineError(.conflict, "The setup virtual machine is restarting or shutting down."))
        }
    }

    @Test("vm_setup_finish needs the agent with SIP off, then returns once the image is Ready")
    func finish() async throws {
        try await Self.withSetup { engine, connection, session, machine, image, chat in
            let refused = EngineError(.conflict, "Finish Setup needs the agent connected with SIP off.")
            #expect(await engineError {
                try await engine.call(VMToolsSetupFinish.self, .init(chatID: chat.id, imageID: image.id), actor: chat.actor)
            } == refused)
            await MainActor.run { machine.agentConnects(sip: .enabled) }
            #expect(await engineError {
                try await engine.call(VMToolsSetupFinish.self, .init(chatID: chat.id, imageID: image.id), actor: chat.actor)
            } == refused)
            await MainActor.run { machine.agentConnects(sip: .disabled) }
            _ = try await engine.call(VMToolsSetupFinish.self, .init(chatID: chat.id, imageID: image.id), actor: chat.actor)
            #expect(await session.phase == .ended)
            #expect(try await connection.call(VMImagesList.self).first { $0.id == image.id }?.state == .ready)
            #expect(await MainActor.run { machine.calls.contains(.shutDownGuest) })
            // The setup no longer runs.
            #expect(await engineError {
                try await engine.call(VMToolsSetupFinish.self, .init(chatID: chat.id, imageID: image.id), actor: chat.actor)
            } == EngineError(.conflict, "The setup of the image is not running."))
            let missing = UUID()
            #expect(await engineError {
                try await engine.call(VMToolsSetupRecovery.self, .init(chatID: chat.id, imageID: missing), actor: chat.actor)
            } == EngineError.notFound("Image", missing.uuidString))
        }
    }
}
