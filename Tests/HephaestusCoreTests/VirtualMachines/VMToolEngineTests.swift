import Foundation
import Testing
@testable import HephaestusAgent
@testable import HephaestusCore

/// docs/engine-api.md › VM tools and docs/virtual-machines.md › Claude's virtual machines, with
/// stand-ins for the images, the virtual machines and their agents: no test starts a virtual
/// machine. The copies run the agent's own file and `exec` handlers on folders of the test.
@Suite("VM tools")
struct VMToolEngineTests {
    /// The calls of a chat of the project DEMO.
    struct Chat {
        let meta: ChatMeta
        var id: ChatID { meta.id }
        var actor: Actor { .claude(chatID: meta.id.uuidString.uppercased()) }
    }

    /// Short waits, so that the waits and the idle stop end within a test.
    static func timings(placeWait: Duration = waitLimit, idleMinute: Duration = .seconds(60)) -> VMToolTimings {
        VMToolTimings(placeWait: placeWait, startAgentWait: .seconds(5), actionAgentWait: .milliseconds(300), idleMinute: idleMinute,
                      requestTimeout: .seconds(10), execMargin: .seconds(5))
    }

    /// A test engine with the project DEMO, a Ready image, the default image, and machines whose
    /// agent connects as soon as they start.
    static func withVMTools<T>(timings: VMToolTimings = VMToolEngineTests.timings(),
                               _ body: (Engine, LocalEngineConnection, FakeVMImageProvisioner, VMImage, URL) async throws -> T) async throws -> T {
        try await withVMEngine(prepare: { data in
            let root = data.url.deletingLastPathComponent().appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try ProjectFileStore.write(Project(id: "DEMO", name: "Demo", created: ISODate.date(from: "2026-10-31T12:00:00Z")!),
                                       to: ProjectFolder(root: root))
            try DeviceFileStore.write(Registry(projects: [root.path]), to: data)
        }) { engine, connection, provisioner, folder in
            await engine.useVMToolTimings(timings)
            let image = try await addReadyImage(engine, connection, provisioner)
            provisioner.machinesConnectAgent = true
            return try await body(engine, connection, provisioner, image, folder)
        }
    }

    static func newChat(_ connection: LocalEngineConnection) async throws -> Chat {
        Chat(meta: try await connection.call(ChatsCreate.self, .init(projectID: "DEMO", kind: .project)))
    }

    static func start(_ engine: Engine, _ chat: Chat, image: String? = nil, name: String = "Menu checks",
                      cores: Int? = nil, memory: Int? = nil) async throws -> VMToolMachine {
        try await engine.call(VMToolsStart.self, .init(chatID: chat.id, image: image, name: name, cores: cores, memory: memory),
                              actor: chat.actor)
    }

    static func list(_ engine: Engine, _ chat: Chat) async throws -> [VMToolMachine] {
        try await engine.call(VMToolsList.self, .init(chatID: chat.id), actor: chat.actor)
    }

    /// The stand-in of a virtual machine, by the order it was made in.
    static func machine(_ provisioner: FakeVMImageProvisioner, _ index: Int) async throws -> FakeGuestMachine {
        try #require(await MainActor.run { provisioner.machines.count > index ? provisioner.machines[index] : nil })
    }

    /// The requests of a virtual machine's agent but the token's.
    static func actionCalls(_ machine: FakeGuestMachine) async -> [FakeGuestMachine.AgentCall] {
        await MainActor.run { machine.agentCalls.filter { $0.method != VMToolService.setEnvMethod } }
    }

    // MARK: Starting and joining

    @Test("vm_start without image starts a virtual machine of the default image for the calling chat, Started by <project id> · <chat name>")
    func startDefaultImage() async throws {
        try await Self.withVMTools { engine, connection, provisioner, image, _ in
            let chat = try await Self.newChat(connection)
            let started = try await Self.start(engine, chat)
            #expect(started.name == "Menu checks")
            #expect(started.imageID == image.id && started.version == image.version)
            // The default values of Settings.
            #expect(started.cores == 2 && started.memoryGB == 4)
            #expect(started.byClaude && started.state == .running && started.agentConnected)
            #expect(started.startedBy == "DEMO · \(chat.meta.title)")
            #expect(started.runningTime == "0 min")
            let stored = try #require(try await connection.call(VMsList.self).machines.first)
            #expect(stored.id == started.id)
            #expect(stored.startedBy == .claude(projectID: "DEMO", chatID: chat.id))
            #expect(try await Self.list(engine, chat) == [started])
        }
    }

    @Test("vm_start from another chat joins the virtual machine Claude runs from the same image; it never joins the user's")
    func join() async throws {
        try await Self.withVMTools { engine, connection, provisioner, image, _ in
            provisioner.machinesConnectAgent = false
            let user = try await createVM(connection, image: image, name: "Mine")
            provisioner.machinesConnectAgent = true
            let first = try await Self.newChat(connection)
            let second = try await Self.newChat(connection)
            let started = try await Self.start(engine, first, cores: 3)
            #expect(started.id != user.id)
            let joined = try await Self.start(engine, second, image: image.version, name: "Other name", cores: 2)
            #expect(joined.id == started.id)
            #expect(joined.name == "Menu checks" && joined.cores == 3)
            let byID = try await Self.start(engine, second, image: image.id.uuidString)
            #expect(byID.id == started.id)
            #expect(await MainActor.run { provisioner.machines.count } == 3)
            #expect(Set(try await connection.call(VMsList.self).machines.map(\.id)) == [user.id, started.id])
        }
    }

    @Test("vm_start checks the image, the name, the cores and the memory")
    func startErrors() async throws {
        try await Self.withVMTools { engine, connection, provisioner, image, _ in
            let chat = try await Self.newChat(connection)
            let waiting = try await addInstalledImage(connection, build: "26B123")
            let missing = UUID()
            func error(_ image: String?, name: String = "VM", cores: Int? = nil, memory: Int? = nil) async -> EngineError? {
                await engineError { try await Self.start(engine, chat, image: image, name: name, cores: cores, memory: memory) }
            }
            #expect(await error(missing.uuidString) == EngineError(.notFound, "Image \(missing.uuidString) not found."))
            #expect(await error("99.0") == EngineError(.notFound, "No Ready image of macOS 99.0."))
            #expect(await error(waiting.id.uuidString) == EngineError(.conflict, "The image is not Ready."))
            #expect(await error(nil, name: " ") == EngineError(.invalid, "name: use 1 to 100 characters on one line."))
            let limits = VMImageLimits.host
            #expect(await error(nil, cores: 1) == EngineError(.invalid, "cores: use a number from 2 to \(limits.cores.upperBound)."))
            #expect(await error(nil, memory: 3) == EngineError(.invalid, "memory: use a number from 4 to \(limits.memoryGB.upperBound)."))
            _ = try await connection.call(SettingsUpdate.self, .init(defaultVMImage: .clear))
            #expect(await error(nil) == EngineError(.conflict, "No image is the default; name one with image."))
            #expect(try await connection.call(VMsList.self).machines.isEmpty)
            provisioner.supportsVirtualMachines = false
            #expect(await error(image.id.uuidString) == EngineError(.unavailable, "Virtual machines need a Mac with Apple silicon."))
        }
    }

    @Test("While 2 virtual machines run, vm_start waits for a free place, then fails after the wait")
    func waitForPlace() async throws {
        try await Self.withVMTools(timings: Self.timings(placeWait: .milliseconds(300))) { engine, connection, provisioner, image, _ in
            provisioner.machinesConnectAgent = false
            let first = try await createVM(connection, image: image, name: "First")
            _ = try await createVM(connection, image: image, name: "Second")
            provisioner.machinesConnectAgent = true
            let chat = try await Self.newChat(connection)
            let clock = ContinuousClock()
            let began = clock.now
            #expect(await engineError { try await Self.start(engine, chat) }
                == EngineError(.unavailable, "2 virtual machines are still running after a wait of 10 minutes."))
            #expect(clock.now - began >= .milliseconds(300))

            await engine.useVMToolTimings(Self.timings())
            let waiting = Task { try await Self.start(engine, chat) }
            await waitUntil { await engine.vmToolWaiterCount == 1 }
            _ = try await connection.call(VMsStop.self, VMParams(vmID: first.id))
            let started = try await waiting.value
            #expect(started.byClaude && started.state == .running)
            #expect(try await connection.call(VMsList.self).runningCount == 2)
        }
    }

    // MARK: The queue

    @Test("The actions of every chat on one virtual machine run one at a time, in the order they arrive")
    func arrivalOrder() async throws {
        try await Self.withVMTools { engine, connection, provisioner, _, _ in
            let first = try await Self.newChat(connection)
            let second = try await Self.newChat(connection)
            let vm = try await Self.start(engine, first)
            _ = try await Self.start(engine, second)
            let machine = try await Self.machine(provisioner, 1)
            let hold = TestHold()
            await MainActor.run { machine.agentHolds["type"] = hold }

            let typeA = Task { try await engine.call(VMToolsType.self, .init(chatID: first.id, vmID: vm.id, text: "a"), actor: first.actor) }
            await waitUntil { await Self.actionCalls(machine).count == 1 }
            let typeB = Task { try await engine.call(VMToolsType.self, .init(chatID: second.id, vmID: vm.id, text: "b"), actor: second.actor) }
            await waitUntil { await engine.pendingVMActions(vm.id) == 2 }
            let click = Task { try await engine.call(VMToolsClick.self, .init(chatID: first.id, vmID: vm.id, x: 10, y: 20), actor: first.actor) }
            await waitUntil { await engine.pendingVMActions(vm.id) == 3 }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await Self.actionCalls(machine).map(\.method) == ["type"])

            hold.release()
            _ = try await typeA.value
            _ = try await typeB.value
            _ = try await click.value
            let calls = await Self.actionCalls(machine)
            #expect(calls.map(\.method) == ["type", "type", "click"])
            #expect(calls.map { $0.params["text"] } == [.string("a"), .string("b"), nil])
            #expect(calls.last?.params == ["x": 10, "y": 20, "button": "left", "count": 1])
            #expect(await engine.pendingVMActions(vm.id) == 0)
        }
    }

    @Test("The actions send their requests to the agent: screenshot, key in menu notation, shell")
    func actions() async throws {
        try await Self.withVMTools { engine, connection, provisioner, _, _ in
            let chat = try await Self.newChat(connection)
            let vm = try await Self.start(engine, chat)
            let machine = try await Self.machine(provisioner, 1)
            await MainActor.run {
                machine.agentHandler = { call in
                    switch call.method {
                    case "screenshot": return GuestAgentResponse(result: ["width": 2560, "height": 1600, "scale": 2], data: Data("png".utf8))
                    case "exec": return GuestAgentResponse(result: ["exitStatus": 0, "timedOut": false, "stdout": "disabled\n",
                                                                    "stderr": "", "truncated": false])
                    default: return GuestAgentResponse()
                    }
                }
            }
            let shot = try await engine.call(VMToolsScreenshot.self, .init(chatID: chat.id, vmID: vm.id), actor: chat.actor)
            #expect(shot.width == 2560 && shot.height == 1600)
            #expect(shot.path.hasPrefix(engine.dataDirectory.screenshotsFolder.path + "/vm-\(vm.id.uuidString)-"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: shot.path)) == Data("png".utf8))

            _ = try await engine.call(VMToolsKey.self, .init(chatID: chat.id, vmID: vm.id, key: "⇧⌘K"), actor: chat.actor)
            _ = try await engine.call(VMToolsKey.self, .init(chatID: chat.id, vmID: vm.id, key: "↩"), actor: chat.actor)
            #expect(await engineError {
                try await engine.call(VMToolsKey.self, .init(chatID: chat.id, vmID: vm.id, key: "Command-K"), actor: chat.actor)
            } == EngineError(.invalid, "key: use the macOS menu notation, for example ⇧⌘K."))

            let shell = try await engine.call(VMToolsShell.self, .init(chatID: chat.id, vmID: vm.id, command: "csrutil status", asRoot: true),
                                              actor: chat.actor)
            #expect(shell == VMShellResult(exitStatus: 0, timedOut: false, stdout: "disabled\n", stderr: "", truncated: false))
            #expect(await engineError {
                try await engine.call(VMToolsShell.self, .init(chatID: chat.id, vmID: vm.id, command: "true", timeout: 1801), actor: chat.actor)
            } == EngineError(.invalid, "timeout: use a number from 1 to 1800."))

            let calls = await Self.actionCalls(machine)
            #expect(calls.map(\.method) == ["screenshot", "key", "key", "exec"])
            #expect(calls[1].params == ["key": "k", "modifiers": ["shift", "command"]])
            #expect(calls[2].params == ["key": "return", "modifiers": []])
            #expect(calls[3].params == ["command": "csrutil status", "asRoot": true, "timeout": 60])
        }
    }

    @Test("An action on a stopped virtual machine, or whose agent is not connected, fails")
    func actionFailures() async throws {
        try await Self.withVMTools { engine, connection, provisioner, image, _ in
            let chat = try await Self.newChat(connection)
            provisioner.machinesConnectAgent = false
            let user = try await createVM(connection, image: image, name: "Mine")
            #expect(await engineError {
                try await engine.call(VMToolsType.self, .init(chatID: chat.id, vmID: user.id, text: "x"), actor: chat.actor)
            } == EngineError(.unavailable, "The agent of “Mine” is not connected."))
            _ = try await connection.call(VMsStop.self, VMParams(vmID: user.id))
            #expect(await engineError {
                try await engine.call(VMToolsType.self, .init(chatID: chat.id, vmID: user.id, text: "x"), actor: chat.actor)
            } == EngineError(.conflict, "The virtual machine “Mine” is not running."))
            let missing = UUID()
            #expect(await engineError {
                try await engine.call(VMToolsType.self, .init(chatID: chat.id, vmID: missing, text: "x"), actor: chat.actor)
            } == EngineError(.notFound, "Virtual machine \(missing.uuidString) not found."))
        }
    }

    // MARK: Idle stop

    @Test("A virtual machine of Claude stops and is deleted after the idle minutes without an action; the user's does not")
    func idleStop() async throws {
        try await Self.withVMTools(timings: Self.timings(idleMinute: .milliseconds(100))) { engine, connection, provisioner, image, _ in
            provisioner.machinesConnectAgent = false
            let user = try await createVM(connection, image: image, name: "Mine")
            provisioner.machinesConnectAgent = true
            _ = try await connection.call(SettingsUpdate.self, .init(claudeVMIdleMinutes: 1440))
            let chat = try await Self.newChat(connection)
            let vm = try await Self.start(engine, chat)
            let machine = try await Self.machine(provisioner, 2)

            // An action keeps it running past the idle time.
            let hold = TestHold()
            await MainActor.run { machine.agentHolds["type"] = hold }
            let typing = Task { try await engine.call(VMToolsType.self, .init(chatID: chat.id, vmID: vm.id, text: "a"), actor: chat.actor) }
            await waitUntil { await Self.actionCalls(machine).count == 1 }
            _ = try await connection.call(SettingsUpdate.self, .init(claudeVMIdleMinutes: 1))
            try await Task.sleep(for: .milliseconds(300))
            #expect(Set(try await connection.call(VMsList.self).machines.map(\.id)) == [user.id, vm.id])

            // Once the queue is empty, the new value applies.
            hold.release()
            _ = try await typing.value
            await waitUntil { (try? await connection.call(VMsList.self).machines.map(\.id)) == [user.id] }
            #expect(try await connection.call(VMsList.self).machines.map(\.id) == [user.id])
            #expect(await MainActor.run { machine.calls }.contains(.shutDownGuest))
            #expect(!FileManager.default.fileExists(atPath: engine.dataDirectory.virtualMachineFolder(vm.id).path))
            #expect(try await connection.call(VMsList.self).machines.first?.state == .running)
        }
    }

    @Test("vm_start without cores or memory uses the New VMs values, and a new virtual machine gets defaultVMDiskGB or the image's disk")
    func startDefaults() async throws {
        try await Self.withVMTools { engine, connection, provisioner, image, _ in
            _ = try await connection.call(SettingsUpdate.self, .init(defaultVMCores: 3, defaultVMMemoryGB: 5, defaultVMDiskGB: 40))
            let chat = try await Self.newChat(connection)
            let started = try await Self.start(engine, chat)
            #expect(started.cores == 3 && started.memoryGB == 5)
            let machine = try #require(try await connection.call(VMsList.self).machines.first)
            // Its disk grew from the image's 1 GB, and the guest's container grew at the start.
            #expect(image.diskGB == 1)
            #expect(machine.diskGB == 40 && !machine.growContainer)
            #expect(await MainActor.run { provisioner.machines.last?.growCalls.count } == 1)
            _ = try await engine.call(VMToolsStop.self, .init(chatID: chat.id, vmID: started.id), actor: chat.actor)

            // Values given win over the defaults.
            let given = try await Self.start(engine, chat, cores: 2, memory: 4)
            #expect(given.cores == 2 && given.memoryGB == 4)
        }
    }

    @Test("The New VMs values: 2, 4 and 64 by default, each refused outside its range on this Mac")
    func newVMsSettings() async throws {
        let defaults = HostSettings()
        #expect(defaults.defaultVMCores == 2 && defaults.defaultVMMemoryGB == 4 && defaults.defaultVMDiskGB == 64)
        let read = try YAMLCoding.decode(HostSettings.self, from: "schema: 1\n")
        #expect(read.defaultVMCores == 2 && read.defaultVMMemoryGB == 4 && read.defaultVMDiskGB == 64)
        let limits = VMImageLimits.host
        try await withTestEngine { _, connection, _ in
            let refused: [(SettingsUpdate.Params, String)] = [
                (.init(defaultVMCores: 1), "defaultVMCores: use a number from 2 to \(limits.cores.upperBound)."),
                (.init(defaultVMCores: limits.cores.upperBound + 1), "defaultVMCores: use a number from 2 to \(limits.cores.upperBound)."),
                (.init(defaultVMMemoryGB: 3), "defaultVMMemoryGB: use a number from 4 to \(limits.memoryGB.upperBound)."),
                (.init(defaultVMMemoryGB: limits.memoryGB.upperBound + 1),
                 "defaultVMMemoryGB: use a number from 4 to \(limits.memoryGB.upperBound)."),
                (.init(defaultVMDiskGB: 31), "defaultVMDiskGB: use a number from 32 to 2048."),
                (.init(defaultVMDiskGB: 2049), "defaultVMDiskGB: use a number from 32 to 2048."),
            ]
            for (params, message) in refused {
                #expect(await engineError { try await connection.call(SettingsUpdate.self, params) } == EngineError(.invalid, message))
            }
            #expect(try await connection.call(SettingsGet.self) == HostSettings())
            let updated = try await connection.call(SettingsUpdate.self, .init(defaultVMCores: 2, defaultVMMemoryGB: 4, defaultVMDiskGB: 2048))
            #expect(updated.defaultVMDiskGB == 2048)
        }
        // A value of a larger Mac's file stays until it changes, and is brought into the range where it is used.
        let small = VMImageLimits(processorCount: 4, physicalMemory: 8 * VMImageLimits.bytesPerGB)
        let larger = HostSettings(defaultVMCores: 12, defaultVMMemoryGB: 32)
        try larger.checkVMDefaults(changedFrom: larger, limits: small)
        #expect(throws: ValidationError.invalid("defaultVMCores", "use a number from 2 to 4")) {
            try HostSettings(defaultVMCores: 6, defaultVMMemoryGB: 32).checkVMDefaults(changedFrom: larger, limits: small)
        }
        #expect(larger.vmDefaults(small) == (4, 8, 64))
    }

    @Test("claudeVMIdleMinutes: 10 by default, 1 to 1440")
    func idleSetting() async throws {
        #expect(HostSettings().claudeVMIdleMinutes == 10)
        #expect(try YAMLCoding.decode(HostSettings.self, from: "schema: 1\n").claudeVMIdleMinutes == 10)
        try await withTestEngine { _, connection, _ in
            for minutes in [0, 1441] {
                #expect(await engineError { try await connection.call(SettingsUpdate.self, .init(claudeVMIdleMinutes: minutes)) }
                    == EngineError(.invalid, "claudeVMIdleMinutes: use a number from 1 to 1440."))
            }
            let updated = try await connection.call(SettingsUpdate.self, .init(claudeVMIdleMinutes: 1))
            #expect(updated.claudeVMIdleMinutes == 1)
        }
    }

    // MARK: vm_stop and the user's virtual machines

    @Test("vm_stop stops and deletes a virtual machine of Claude, and refuses one the user started")
    func stop() async throws {
        try await Self.withVMTools { engine, connection, provisioner, image, _ in
            provisioner.machinesConnectAgent = false
            let user = try await createVM(connection, image: image, name: "Mine")
            provisioner.machinesConnectAgent = true
            let chat = try await Self.newChat(connection)
            #expect(await engineError {
                try await engine.call(VMToolsStop.self, .init(chatID: chat.id, vmID: user.id), actor: chat.actor)
            } == EngineError(.forbidden, "“Mine” was started by the user: only the user stops it."))
            let vm = try await Self.start(engine, chat)
            _ = try await engine.call(VMToolsStop.self, .init(chatID: chat.id, vmID: vm.id), actor: chat.actor)
            let list = try await connection.call(VMsList.self)
            #expect(list.machines.map(\.id) == [user.id])
            #expect(list.machines.first?.state == .running)
        }
    }

    @Test("Only the chat's own Claude uses the VM tools")
    func ownChatOnly() async throws {
        try await Self.withVMTools { engine, connection, _, _, _ in
            let chat = try await Self.newChat(connection)
            let other = try await Self.newChat(connection)
            let refusal = EngineError(.forbidden, "Only the chat's own Claude can use the VM tools.")
            #expect(await engineError { try await engine.call(VMToolsList.self, .init(chatID: chat.id), actor: other.actor) } == refusal)
            #expect(await engineError {
                try await engine.call(VMToolsImages.self, .init(chatID: chat.id), actor: .claude(chatID: Actor.externalChatID))
            } == refusal)
            #expect(await engineError { try await connection.call(VMToolsList.self, .init(chatID: chat.id)) }?.code == .forbidden)
            let images = try await engine.call(VMToolsImages.self, .init(chatID: chat.id), actor: chat.actor)
            #expect(images.count == 1 && images.first?.isDefault == true && images.first?.state == .ready)
        }
    }

    // MARK: Claude token

    @Test("Each virtual machine gets the Claude token when its agent connects; the setup virtual machine and the image never get it")
    func tokenKeptOutOfTheImage() async throws {
        let token = "token-\(UUID().uuidString)"
        try await withVMEngine(prepare: { data in
            let root = data.url.deletingLastPathComponent().appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try ProjectFileStore.write(Project(id: "DEMO", name: "Demo", created: Date(timeIntervalSince1970: 0)), to: ProjectFolder(root: root))
            try DeviceFileStore.write(Registry(projects: [root.path]), to: data)
        }) { engine, connection, provisioner, _ in
            await engine.useVMToolTimings(Self.timings())
            #expect(throws: EngineError(.invalid, "claudeVMToken: use one line without white space.")) {
                try engine.setClaudeVMToken("two words")
            }
            try engine.setClaudeVMToken("  \(token)\n")
            #expect(engine.claudeVMToken == token)

            let image = try await addReadyImage(engine, connection, provisioner)
            let setup = try await Self.machine(provisioner, 0)
            #expect(await MainActor.run { setup.agentCalls }.isEmpty)

            provisioner.machinesConnectAgent = true
            let chat = try await Self.newChat(connection)
            let vm = try await Self.start(engine, chat)
            #expect(vm.agentConnected)
            let machine = try await Self.machine(provisioner, 1)
            #expect(await MainActor.run { machine.agentCalls }
                == [.init(method: "setEnv", params: ["name": "CLAUDE_CODE_OAUTH_TOKEN", "value": .string(token)], data: Data())])

            // A new connection of the agent gets it again.
            await MainActor.run {
                machine.agentDisconnects()
                machine.agentConnects(sip: .disabled)
            }
            await waitUntil { await MainActor.run { machine.agentCalls.count } == 2 }

            // Nothing of the image, of the virtual machine's folder or of the log holds it.
            for folder in [engine.dataDirectory.vmImageFolder(image.id), engine.dataDirectory.virtualMachineFolder(vm.id),
                           engine.dataDirectory.logsFolder] {
                let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
                for file in files where !file.hasDirectoryPath {
                    let data = (try? Data(contentsOf: file)) ?? Data()
                    #expect(data.range(of: Data(token.utf8)) == nil, "\(file.lastPathComponent) holds the token")
                }
            }
            let secrets = try DeviceFileStore.loadSecrets(engine.dataDirectory, log: nil)
            #expect(secrets.claudeVMToken == token)

            try engine.setClaudeVMToken(" ")
            #expect(engine.claudeVMToken == nil)
            let text = try String(contentsOf: engine.dataDirectory.secretsFile, encoding: .utf8)
            #expect(!text.contains("claudeVMToken"))
        }
    }

    @Test("Without a token, the agent gets no setEnv and the virtual machine is ready at once")
    func noToken() async throws {
        try await Self.withVMTools { engine, connection, provisioner, _, _ in
            let chat = try await Self.newChat(connection)
            let vm = try await Self.start(engine, chat)
            #expect(vm.agentConnected)
            let machine = try await Self.machine(provisioner, 1)
            #expect(await MainActor.run { machine.agentCalls }.isEmpty)
        }
    }

    // MARK: Copies

    /// Serves the requests of a virtual machine with the agent's own handlers, on this Mac: the
    /// guest's paths are folders of the test.
    @MainActor
    static func serveWithAgentHandlers(_ machine: FakeGuestMachine) {
        machine.agentHandler = { call in
            let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(JSONValue.object(call.params)))
            let params = AgentParams(values: object as? [String: Any] ?? [:])
            let result: AgentResult
            switch call.method {
            case "stat": result = try AgentFiles.status(params)
            case "readFile": result = try AgentFiles.readFile(params)
            case "writeFile": result = try AgentFiles.writeFile(params, call.data)
            case "exec": result = try AgentCommands.exec(params, shell: ["/bin/sh", "-c"], rootKill: nil)
            default: result = AgentResult()
            }
            let json = try JSONDecoder().decode(JSONValue.self, from: try JSONSerialization.data(withJSONObject: result.json))
            return GuestAgentResponse(result: json.objectValue ?? [:], data: result.data)
        }
    }

    @Test("vm_copy_in and vm_copy_out copy a file and a folder, with its symbolic links and permissions")
    func copies() async throws {
        try await Self.withVMTools { engine, connection, provisioner, _, folder in
            let chat = try await Self.newChat(connection)
            let vm = try await Self.start(engine, chat)
            let machine = try await Self.machine(provisioner, 1)
            await MainActor.run { Self.serveWithAgentHandlers(machine) }
            let manager = FileManager.default
            let mac = folder.appendingPathComponent("Mac", isDirectory: true)
            let guest = folder.appendingPathComponent("Guest", isDirectory: true)
            let app = mac.appendingPathComponent("Demo.app/Contents", isDirectory: true)
            try manager.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try Data("binary".utf8).write(to: app.appendingPathComponent("MacOS/Demo"))
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("MacOS/Demo").path)
            try manager.createSymbolicLink(atPath: app.appendingPathComponent("Current").path, withDestinationPath: "MacOS")
            let file = mac.appendingPathComponent("notes.txt")
            try Data("hello".utf8).write(to: file)

            func copy<M: EngineMethod>(_ method: M.Type, _ source: URL, _ destination: URL) async throws where M.Params == VMToolCopyParams {
                _ = try await engine.call(method, VMToolCopyParams(chatID: chat.id, vmID: vm.id, source: source.path,
                                                                    destination: destination.path), actor: chat.actor)
            }
            try await copy(VMToolsCopyIn.self, file, guest.appendingPathComponent("in/notes.txt"))
            #expect(try String(contentsOf: guest.appendingPathComponent("in/notes.txt"), encoding: .utf8) == "hello")
            try await copy(VMToolsCopyIn.self, mac.appendingPathComponent("Demo.app"), guest.appendingPathComponent("Apps/Demo.app"))
            let copied = guest.appendingPathComponent("Apps/Demo.app/Contents")
            #expect(try String(contentsOf: copied.appendingPathComponent("MacOS/Demo"), encoding: .utf8) == "binary")
            #expect(try manager.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("Current").path) == "MacOS")
            #expect((try manager.attributesOfItem(atPath: copied.appendingPathComponent("MacOS/Demo").path)[.posixPermissions] as? NSNumber)?
                .intValue == 0o755)

            let back = folder.appendingPathComponent("Back", isDirectory: true)
            try await copy(VMToolsCopyOut.self, guest.appendingPathComponent("in/notes.txt"), back.appendingPathComponent("notes.txt"))
            #expect(try String(contentsOf: back.appendingPathComponent("notes.txt"), encoding: .utf8) == "hello")
            try await copy(VMToolsCopyOut.self, guest.appendingPathComponent("Apps"), back.appendingPathComponent("Apps"))
            #expect(try manager.destinationOfSymbolicLink(atPath: back.appendingPathComponent("Apps/Demo.app/Contents/Current").path) == "MacOS")
            // The archives of the folders are removed from the guest's /tmp.
            #expect(try manager.contentsOfDirectory(atPath: "/tmp").filter { $0.hasPrefix("hephaestus-copy-") }.isEmpty)

            let missing = guest.appendingPathComponent("missing").path
            #expect(await engineError {
                try await copy(VMToolsCopyOut.self, URL(fileURLWithPath: missing), back.appendingPathComponent("x"))
            } == EngineError(.notFound, "\(missing) does not exist in the guest."))
            #expect(await engineError {
                _ = try await engine.call(VMToolsCopyIn.self, VMToolCopyParams(chatID: chat.id, vmID: vm.id, source: "relative",
                                                                               destination: "/tmp/x"), actor: chat.actor)
            } == EngineError(.invalid, "source: use an absolute path or a path starting with ~/."))
        }
    }

    @Test("claudeVMToken: one line without white space, absent while none is set")
    func tokenRule() throws {
        #expect(try Secrets.checkedClaudeVMToken("  abc-123\n") == "abc-123")
        #expect(try Secrets.checkedClaudeVMToken(" \n ") == nil)
        #expect(throws: ValidationError.self) { try Secrets.checkedClaudeVMToken("abc 123") }
        #expect(throws: ValidationError.self) { try Secrets.checkedClaudeVMToken(String(repeating: "a", count: 4097)) }
        let without = try StorageJSON.fileEncoder().encode(Secrets(pairingCode: "7K3M-Q9TX-2HVD-R4NP", mcpExternalToken: String(repeating: "a", count: 64)))
        #expect(!String(decoding: without, as: UTF8.self).contains("claudeVMToken"))
        let with = Secrets(pairingCode: "7K3M-Q9TX-2HVD-R4NP", mcpExternalToken: String(repeating: "a", count: 64), claudeVMToken: "abc")
        #expect(try StorageJSON.decodeObject(Secrets.self, from: try StorageJSON.fileEncoder().encode(with)) == with)
    }

    @Test("The common prompt lists the VM tools and tells Claude to start one freely, and never to stop the user's; all but vm_copy_out are pre-approved")
    func prompt() {
        let common = Prompts.text(.common)
        #expect(common.contains("- Virtual machines: vm_list_images, vm_list, vm_start, vm_stop, vm_screenshot, vm_click, vm_drag, vm_scroll, "
            + "vm_type, vm_key, vm_ui_tree, vm_shell, vm_copy_in, vm_copy_out (macOS virtual machines of this Mac that you start, drive and "
            + "stop for your checks).\n"))
        #expect(common.contains("# Virtual machines\n\nStart a virtual machine with vm_start freely, without asking, whenever a check needs one"))
        #expect(common.contains("act on it only when the user names it in this chat, by its name or with its linked item, and never stop it."))
        let tools = Set(ClaudeCommandLine.preApprovedTools.split(separator: ",").map(String.init))
        for tool in MCPToolCatalog.tools where tool.handling == .vmTool {
            #expect(tools.contains("mcp__hephaestus__\(tool.name)") == (tool.name != "vm_copy_out"), "\(tool.name)")
        }
    }

    // MARK: Menu notation

    @Test("vm_key reads the macOS menu notation as the agent's key and modifiers")
    func keyNotation() {
        #expect(VMKeyNotation.agentKey("⇧⌘K")! == ("k", ["shift", "command"]))
        #expect(VMKeyNotation.agentKey("⌘s")! == ("s", ["command"]))
        #expect(VMKeyNotation.agentKey("⌃⌥Space")! == ("space", ["control", "option"]))
        #expect(VMKeyNotation.agentKey("F12")! == ("f12", []))
        #expect(VMKeyNotation.agentKey("⌘,")! == (",", ["command"]))
        #expect(VMKeyNotation.agentKey("⇟")! == ("pageDown", []))
        #expect(VMKeyNotation.agentKey("⌦")! == ("forwardDelete", []))
        #expect(VMKeyNotation.agentKey("⌘⇧K") == nil)
        #expect(VMKeyNotation.agentKey("⌘") == nil)
        #expect(VMKeyNotation.agentKey("Cmd-K") == nil)
    }
}

extension Engine {
    func useVMToolTimings(_ timings: VMToolTimings) {
        vmTools.timings = timings
    }

    /// The actions queued or running on a virtual machine.
    func pendingVMActions(_ vmID: UUID) -> Int {
        vmTools.queues[vmID]?.pending ?? 0
    }

    /// The calls of `vm_start` that wait for a free place.
    var vmToolWaiterCount: Int {
        vmTools.waiters.count
    }
}
