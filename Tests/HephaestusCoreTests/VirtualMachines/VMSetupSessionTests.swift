import Foundation
import Testing
@testable import HephaestusCore

/// docs/virtual-machines.md › Setup, with a stand-in for the setup virtual machine.
@Suite("Image setup")
struct VMSetupSessionTests {
    struct StartFailure: LocalizedError {
        var errorDescription: String? { "The virtual machine failed to start." }
    }

    /// The setup of a new installed image, with its stand-in machine.
    static func begin(_ engine: Engine, _ connection: LocalEngineConnection, _ provisioner: FakeVMImageProvisioner,
                      build: String = "26B131") async throws -> (VMImage, VMSetupSession, FakeGuestMachine) {
        let image = try await addInstalledImage(connection, build: build)
        let session = try await engine.beginImageSetup(image.id)
        await session.useShortWaits()
        return (image, session, try #require(provisioner.machines.last))
    }

    static func state(of image: VMImage, _ connection: LocalEngineConnection) async throws -> VMImageState? {
        try await connection.call(VMImagesList.self).first { $0.id == image.id }?.state
    }

    @Test("Set Up boots the image's disk with the shared folder filled from the bundle")
    func begin() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            #expect(await machine.calls == [.start(recovery: false)])
            #expect(await session.phase == .running)
            #expect(await session.version == "27.2.1")
            #expect(await session.imageID == image.id)
            #expect(await session.agent == nil)
            #expect(await !session.canFinish)
            #expect(await engine.runningVMCount == 1)

            let share = engine.dataDirectory.guestShareFolder
            let request = try #require(provisioner.machineRequests.last)
            #expect(request == GuestMachineRequest(files: VMImageStore.files(of: image.id, in: engine.dataDirectory), cores: 2,
                                                   memoryGB: 4, sharedFolder: share))
            #expect(try String(contentsOf: share.appendingPathComponent("hephaestus-agent"), encoding: .utf8) == "agent")
            #expect(try String(contentsOf: share.appendingPathComponent("install.sh"), encoding: .utf8) == "#!/bin/sh\n")
            let mode = try FileManager.default.attributesOfItem(atPath: share.appendingPathComponent("hephaestus-agent").path)[.posixPermissions] as? Int
            #expect(mode == 0o755)

            // Set Up on an image whose setup runs gives the same setup, without a second machine.
            #expect(try await engine.beginImageSetup(image.id) === session)
            #expect(provisioner.machines.count == 1)
            #expect(try await Self.state(of: image, connection) == .needsSetup)
        }
    }

    @Test("Set Up refuses an unknown image, an image that is not waiting for setup and a third virtual machine")
    func beginErrors() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            #expect(await engineError { try await engine.beginImageSetup(UUID()) }?.code == .notFound)

            provisioner.downloadHold = TestHold()
            let downloading = try await addImage(connection, build: "21F79")
            #expect(await engineError { try await engine.beginImageSetup(downloading.id) }
                == EngineError(.conflict, "The image is not waiting for setup."))
            provisioner.downloadHold = nil

            let ready = try await addReadyImage(engine, connection, provisioner, build: "22A380")
            #expect(await engineError { try await engine.beginImageSetup(ready.id) }
                == EngineError(.conflict, "The image is not waiting for setup."))

            // The third image is installed first: an install waits while 2 virtual machines run.
            let third = try await addInstalledImage(connection, build: "25G83")
            let (_, first, _) = try await Self.begin(engine, connection, provisioner, build: "26B131")
            let (_, second, _) = try await Self.begin(engine, connection, provisioner, build: "26B123")
            #expect(await engine.runningVMCount == 2)
            #expect(await engineError { try await engine.beginImageSetup(third.id) }
                == EngineError(.conflict, "2 virtual machines are already running."))
            await first.close()
            #expect(await engine.runningVMCount == 1)
            let session = try await engine.beginImageSetup(third.id)
            #expect(await session.phase == .running)
            await second.close()
            await session.close()
            #expect(await engine.runningVMCount == 0)

            provisioner.supportsVirtualMachines = false
            #expect(await engineError { try await engine.beginImageSetup(third.id) }
                == EngineError(.unavailable, "Virtual machines need a Mac with Apple silicon."))
        }
    }

    @Test("Set Up fails without the guest agent of the bundle, and when the virtual machine cannot start")
    func beginFailures() async throws {
        let provisioner = FakeVMImageProvisioner(list: try ipswFixture())
        try await withTestEngine(imageProvisioner: provisioner) { engine, connection, _ in
            let image = try await addInstalledImage(connection)
            #expect(await engineError { try await engine.beginImageSetup(image.id) }
                == EngineError(.unavailable, "The guest agent is missing from the app bundle."))
            #expect(await engine.runningVMCount == 0)
        }
        try await withVMEngine { engine, connection, provisioner, _ in
            let image = try await addInstalledImage(connection)
            provisioner.machineFailure = StartFailure()
            #expect(await engineError { try await engine.beginImageSetup(image.id) }
                == EngineError(.unavailable, "The virtual machine failed to start."))
            #expect(await engine.runningVMCount == 0)
            provisioner.machineFailure = nil
            let session = try await engine.beginImageSetup(image.id)
            #expect(await session.phase == .running)
        }
    }

    @Test("A virtual machine that stops while it starts ends its setup and frees its place")
    func stopsWhileStarting() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let image = try await addInstalledImage(connection)
            provisioner.machinesStopWhileStarting = true
            let session = try await engine.beginImageSetup(image.id)
            await waitUntil { await session.phase == .ended }
            #expect(await session.phase == .ended)
            #expect(await engine.runningVMCount == 0)
            #expect(try await Self.state(of: image, connection) == .needsSetup)

            // The next Set Up starts another setup, with another virtual machine.
            provisioner.machinesStopWhileStarting = false
            let again = try await engine.beginImageSetup(image.id)
            #expect(again !== session)
            #expect(await again.phase == .running)
            #expect(provisioner.machines.count == 2)
            #expect(await engine.runningVMCount == 1)
        }
    }

    @Test("Finish Setup is enabled once the agent reports SIP disabled; it shuts the guest down and sets the image to Ready")
    func finish() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            await session.finish()
            #expect(await session.phase == .running)

            await MainActor.run { machine.agentConnects(sip: .enabled) }
            #expect(await session.agent?.sip == .enabled)
            #expect(await !session.canFinish)
            await MainActor.run { machine.agentDisconnects() }
            #expect(await session.agent == nil)
            await MainActor.run { machine.agentConnects(sip: .disabled) }
            #expect(await session.canFinish)

            let events = connection.events
            await session.finish()
            #expect(await machine.calls == [.start(recovery: false), .shutDownGuest])
            #expect(await session.phase == .ended)
            #expect(await session.finished)
            #expect(await session.agent == nil)
            #expect(try await Self.state(of: image, connection) == .ready)
            #expect(await firstImages(on: events) { $0.first?.state == .ready } != nil)
            #expect(try ProjectFileStore.decodeYAML(VMImage.self, at: VMImageStore.files(of: image.id, in: engine.dataDirectory).metadata).state == .ready)
            #expect(await engine.runningVMCount == 0)
        }
    }

    @Test("Finish Setup stops a guest that does not shut down in time, or whose agent refuses")
    func finishStopsAStuckGuest() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            await MainActor.run {
                machine.shutsDownWhenAsked = false
                machine.agentConnects(sip: .disabled)
            }
            await session.finish()
            #expect(await machine.calls == [.start(recovery: false), .shutDownGuest, .stop])
            #expect(try await Self.state(of: image, connection) == .ready)

            // An agent that refuses: stopped at once, without the wait.
            let (other, otherSession, otherMachine) = try await Self.begin(engine, connection, provisioner, build: "26B123")
            await MainActor.run {
                otherSession.timings = VMSetupSession.Timings(finishWait: waitLimit * 10, closeWait: waitLimit * 10,
                                                               restartWait: waitLimit * 10)
                otherMachine.shutDownFailure = GuestAgentError.failed(message: "sudo: a password is required")
                otherMachine.agentConnects(sip: .disabled)
            }
            await otherSession.finish()
            #expect(await otherMachine.calls == [.start(recovery: false), .shutDownGuest, .stop])
            #expect(try await Self.state(of: other, connection) == .ready)

            // An agent whose connection ends before it answers may be shutting the guest down: the
            // wait applies, then the virtual machine is stopped.
            let (third, thirdSession, thirdMachine) = try await Self.begin(engine, connection, provisioner, build: "25G83")
            await MainActor.run {
                thirdMachine.shutDownFailure = GuestAgentError.disconnected
                thirdMachine.agentConnects(sip: .disabled)
            }
            await thirdSession.finish()
            #expect(await thirdMachine.calls == [.start(recovery: false), .shutDownGuest, .stop])
            #expect(try await Self.state(of: third, connection) == .ready)
        }
    }

    @Test("Closing the window before Finish Setup shuts the virtual machine down and leaves the image in Needs setup")
    func close() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            // Without the agent: stopped at once.
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            // The guest wrote to the image's disk meanwhile: the end of the setup tells its size.
            let before = try #require(try await connection.call(VMImagesList.self).first { $0.id == image.id }).diskBytes
            try Data(count: 1_048_576).write(to: VMImageStore.files(of: image.id, in: engine.dataDirectory).disk)
            let events = connection.events
            await session.close()
            #expect(await machine.calls == [.start(recovery: false), .stop])
            #expect(await session.phase == .ended)
            #expect(await !session.finished)
            #expect(try await Self.state(of: image, connection) == .needsSetup)
            #expect(await engine.runningVMCount == 0)
            let after = await firstImages(on: events) { _ in true }?.first { $0.id == image.id }
            #expect(after?.state == .needsSetup)
            #expect((after?.diskBytes ?? 0) >= before + 1_000_000)

            // Set Up starts again from the image's disk, with another virtual machine.
            let again = try await engine.beginImageSetup(image.id)
            #expect(again !== session)
            let secondMachine = try #require(provisioner.machines.last)
            #expect(secondMachine !== machine)
            // With the agent: through the agent.
            await MainActor.run { secondMachine.agentConnects(sip: .disabled) }
            await again.close()
            #expect(await secondMachine.calls == [.start(recovery: false), .shutDownGuest])
            #expect(try await Self.state(of: image, connection) == .needsSetup)
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == nil)
            // A closed setup ignores what comes later.
            await again.finish()
            await again.restartInRecovery()
            #expect(await again.phase == .ended)
        }
    }

    @Test("Set Up on an image whose closed setup still shuts its guest down waits for it, then boots the image again")
    func beginWhileShuttingDown() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            await MainActor.run {
                session.timings.closeWait = waitLimit * 10
                machine.shutsDownWhenAsked = false
                machine.agentConnects(sip: .enabled)
            }
            let closing = Task { await session.close() }
            await waitUntil { await machine.calls.contains(.shutDownGuest) }
            #expect(await session.isShuttingDown)
            #expect(await engine.runningVMCount == 1)

            // Set Up… meanwhile boots nothing: the disk still belongs to the first virtual machine.
            let next = Task { try await engine.beginImageSetup(image.id) }
            try await Task.sleep(for: .milliseconds(150))
            #expect(provisioner.machines.count == 1)

            await MainActor.run { machine.guestShutsDown() }
            await closing.value
            let again = try await next.value
            #expect(again !== session)
            #expect(await again.phase == .running)
            #expect(await !again.isShuttingDown)
            #expect(provisioner.machines.count == 2)
            #expect(await engine.runningVMCount == 1)
            #expect(try await Self.state(of: image, connection) == .needsSetup)
        }
    }

    @Test("A guest that shuts down by itself, or a virtual machine that fails, ends the setup")
    func guestStops() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            await MainActor.run { machine.guestShutsDown() }
            await waitUntil { await session.phase == .ended }
            #expect(await session.phase == .ended)
            #expect(await session.failure == nil)
            #expect(try await Self.state(of: image, connection) == .needsSetup)
            #expect(await engine.runningVMCount == 0)

            let (_, failing, failingMachine) = try await Self.begin(engine, connection, provisioner, build: "26B123")
            await MainActor.run { failingMachine.guestShutsDown(error: "The virtual machine stopped unexpectedly.") }
            await failing.waitUntilEnded()
            #expect(await failing.phase == .ended)
            #expect(await failing.failure == "The virtual machine stopped unexpectedly.")
            #expect(await !failing.restartFailed)
            #expect(await engine.runningVMCount == 0)
            // A session that has ended is not waited for.
            await failing.waitUntilEnded()
        }
    }

    @Test("Restart in Recovery shuts the guest down through the agent, then starts the virtual machine into macOS Recovery")
    func restartInRecovery() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            await MainActor.run { machine.agentConnects(sip: .enabled) }
            await session.restartInRecovery()
            // The shutdown that the restart asked for does not end the setup.
            #expect(await machine.calls == [.start(recovery: false), .shutDownGuest, .start(recovery: true)])
            #expect(await session.phase == .running)
            #expect(await session.agent == nil)
            #expect(await session.canRestartInRecovery)
            #expect(await engine.runningVMCount == 1)
            #expect(try await Self.state(of: image, connection) == .needsSetup)

            // A restart that fails ends the setup.
            #expect(await !session.restartFailed)
            await MainActor.run {
                machine.confirmsStopRequests = true
                machine.startFailure = StartFailure()
            }
            await session.restartInRecovery()
            #expect(await session.phase == .ended)
            #expect(await session.failure == "The virtual machine failed to start.")
            #expect(await session.restartFailed)
            #expect(try await Self.state(of: image, connection) == .needsSetup)
            #expect(await engine.runningVMCount == 0)
        }
    }

    @Test("Restart in Recovery without the agent asks macOS to shut down, and stops a guest that has not stopped in time")
    func restartInRecoveryWithoutAgent() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            // The person in front of the guest confirms: no stop at once.
            let (_, session, machine) = try await Self.begin(engine, connection, provisioner)
            await MainActor.run { machine.confirmsStopRequests = true }
            await session.restartInRecovery()
            #expect(await machine.calls == [.start(recovery: false), .requestStop, .start(recovery: true)])
            #expect(await session.phase == .running)

            // Nobody confirms: stopped at once when the wait ends. The second restart starts
            // from a running virtual machine again.
            await MainActor.run { machine.confirmsStopRequests = false }
            await session.restartInRecovery()
            #expect(await machine.calls == [.start(recovery: false), .requestStop, .start(recovery: true),
                                            .requestStop, .stop, .start(recovery: true)])
            #expect(await session.phase == .running)

            // A virtual machine that takes no stop request is stopped at once, without the wait.
            await MainActor.run {
                session.timings.restartWait = waitLimit * 10
                machine.requestStopFailure = StartFailure()
            }
            await session.restartInRecovery()
            #expect(await Array(machine.calls.suffix(3)) == [.requestStop, .stop, .start(recovery: true)])
            #expect(await session.phase == .running)

            // An agent that refuses leaves the question to macOS.
            await MainActor.run {
                session.useShortWaits()
                machine.requestStopFailure = nil
                machine.confirmsStopRequests = true
                machine.shutDownFailure = GuestAgentError.failed(message: "sudo: a password is required")
                machine.agentConnects(sip: .enabled)
            }
            await session.restartInRecovery()
            #expect(await Array(machine.calls.suffix(3)) == [.shutDownGuest, .requestStop, .start(recovery: true)])
            #expect(await session.phase == .running)
            #expect(await engine.runningVMCount == 1)
        }
    }

    @Test("Closing the window while Restart in Recovery waits for the guest stops the virtual machine at once")
    func closeWhileRestarting() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            await MainActor.run { session.timings.restartWait = waitLimit * 10 }
            let restart = Task { await session.restartInRecovery() }
            await waitUntil { await machine.calls.contains(.requestStop) }
            #expect(await session.phase == .restarting)
            #expect(await !session.canRestartInRecovery)
            await session.close()
            await restart.value
            #expect(await machine.calls == [.start(recovery: false), .requestStop, .stop])
            #expect(await session.phase == .ended)
            #expect(try await Self.state(of: image, connection) == .needsSetup)
            #expect(await engine.runningVMCount == 0)
        }
    }

    @Test("A virtual machine that fails while Restart in Recovery waits ends the setup")
    func failureWhileRestarting() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (_, session, machine) = try await Self.begin(engine, connection, provisioner)
            await MainActor.run { session.timings.restartWait = waitLimit * 10 }
            let restart = Task { await session.restartInRecovery() }
            await waitUntil { await machine.calls.contains(.requestStop) }
            await MainActor.run { machine.guestShutsDown(error: "The virtual machine stopped unexpectedly.") }
            await restart.value
            await waitUntil { await session.phase == .ended }
            #expect(await session.failure == "The virtual machine stopped unexpectedly.")
            #expect(await !machine.calls.contains(.start(recovery: true)))
            #expect(await engine.runningVMCount == 0)
        }
    }

    @Test("Deleting an image stops its setup virtual machine at once")
    func deleteWhileSettingUp() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            await MainActor.run { machine.agentConnects(sip: .disabled) }
            _ = try await connection.call(VMImagesDelete.self, VMImagesDelete.Params(imageID: image.id))
            #expect(await machine.calls == [.start(recovery: false), .stop])
            #expect(await session.phase == .ended)
            #expect(await !session.finished)
            #expect(try await connection.call(VMImagesList.self).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: engine.dataDirectory.vmImageFolder(image.id).path))
            #expect(await engine.runningVMCount == 0)
        }
    }

    @Test("Quitting stops every setup virtual machine and leaves its image in Needs setup")
    func shutdown() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let (image, session, machine) = try await Self.begin(engine, connection, provisioner)
            await MainActor.run { machine.agentConnects(sip: .disabled) }
            await engine.shutdown()
            #expect(await machine.calls == [.start(recovery: false), .stop])
            #expect(await session.phase == .ended)
            let stored = try ProjectFileStore.decodeYAML(VMImage.self, at: VMImageStore.files(of: image.id, in: engine.dataDirectory).metadata)
            #expect(stored.state == .needsSetup)
        }
    }
}
