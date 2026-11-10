import Foundation
import Testing
import Virtualization
@testable import HephaestusCore

/// The capture of the answer of ipsw.me, `Fixtures/ipsw/virtualmac.json`
/// (docs/development.md › ipsw.me capture).
func ipswFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "virtualmac", withExtension: "json", subdirectory: "Fixtures/ipsw"))
    return try Data(contentsOf: url)
}

/// Something a stand-in operation waits for until the test releases it; a cancelled task ends the
/// wait with `CancellationError`, as the real download and install end.
final class TestHold: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var released = false

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeNow = lock.withLock { () -> Result<Void, Error>? in
                    if released { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    waiters[id] = continuation
                    return nil
                }
                if let resumeNow { continuation.resume(with: resumeNow) }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            released = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// The number of operations that wait.
    var waitingCount: Int { lock.withLock { waiters.count } }
}

/// A provisioner that reaches no network and starts no virtual machine: it answers the list with
/// `list`, writes a few bytes as the IPSW, reports the fractions it was given and ends each
/// operation as the test tells it to (docs/development.md › Test rules).
final class FakeVMImageProvisioner: VMImageProvisioning, @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var supportsVirtualMachines = true
        var list: Result<Data, Error> = .failure(VMImageFailure("no list"))
        var downloadFractions: [Double] = [0.25, 0.5, 1]
        var installFractions: [Double] = [0.5, 1]
        var downloadFailure: Error?
        var installFailure: Error?
        var machineFailure: Error?
        var machinesStopWhileStarting = false
        var machinesConnectAgent = false
        var downloadHold: TestHold?
        var installHold: TestHold?
        var listCalls = 0
        var downloads: [MacOSVersion] = []
        var installs: [VMImageInstallRequest] = []
        var machines: [FakeGuestMachine] = []
        var machineRequests: [GuestMachineRequest] = []
    }

    init(list: Data? = nil) {
        if let list {
            state.list = .success(list)
        }
    }

    private func update<T>(_ body: (inout State) -> T) -> T {
        lock.withLock { body(&state) }
    }

    var supportsVirtualMachines: Bool {
        get { update { $0.supportsVirtualMachines } }
        set { update { $0.supportsVirtualMachines = newValue } }
    }
    var list: Result<Data, Error> {
        get { update { $0.list } }
        set { update { $0.list = newValue } }
    }
    var downloadFractions: [Double] {
        get { update { $0.downloadFractions } }
        set { update { $0.downloadFractions = newValue } }
    }
    var installFractions: [Double] {
        get { update { $0.installFractions } }
        set { update { $0.installFractions = newValue } }
    }
    var downloadFailure: Error? {
        get { update { $0.downloadFailure } }
        set { update { $0.downloadFailure = newValue } }
    }
    var installFailure: Error? {
        get { update { $0.installFailure } }
        set { update { $0.installFailure = newValue } }
    }
    var machineFailure: Error? {
        get { update { $0.machineFailure } }
        set { update { $0.machineFailure = newValue } }
    }
    /// True: the virtual machines made from now on stop while they start.
    var machinesStopWhileStarting: Bool {
        get { update { $0.machinesStopWhileStarting } }
        set { update { $0.machinesStopWhileStarting = newValue } }
    }
    /// True: the virtual machines made from now on connect their agent as soon as they start.
    var machinesConnectAgent: Bool {
        get { update { $0.machinesConnectAgent } }
        set { update { $0.machinesConnectAgent = newValue } }
    }
    /// While set, a download waits after its fractions until the hold is released.
    var downloadHold: TestHold? {
        get { update { $0.downloadHold } }
        set { update { $0.downloadHold = newValue } }
    }
    /// While set, an install waits after its fractions until the hold is released.
    var installHold: TestHold? {
        get { update { $0.installHold } }
        set { update { $0.installHold = newValue } }
    }
    var listCalls: Int { update { $0.listCalls } }
    var downloads: [MacOSVersion] { update { $0.downloads } }
    var installs: [VMImageInstallRequest] { update { $0.installs } }
    var machines: [FakeGuestMachine] { update { $0.machines } }
    var machineRequests: [GuestMachineRequest] { update { $0.machineRequests } }

    func versionList() async throws -> Data {
        try update { state -> Result<Data, Error> in
            state.listCalls += 1
            return state.list
        }.get()
    }

    func download(_ version: MacOSVersion, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (fractions, hold) = update { state -> ([Double], TestHold?) in
            state.downloads.append(version)
            return (state.downloadFractions, state.downloadHold)
        }
        try Data("ipsw".utf8).write(to: file)
        do {
            for fraction in fractions {
                progress(fraction)
            }
            try await hold?.wait()
            if let failure = downloadFailure { throw failure }
        } catch {
            // A failed download leaves no file.
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func install(_ request: VMImageInstallRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (fractions, hold) = update { state -> ([Double], TestHold?) in
            state.installs.append(request)
            return (state.installFractions, state.installHold)
        }
        for fraction in fractions {
            progress(fraction)
        }
        try await hold?.wait()
        if let failure = installFailure { throw failure }
        try Data("model".utf8).write(to: request.files.hardwareModel)
        try Data("identifier".utf8).write(to: request.files.machineIdentifier)
        try Data("auxiliary".utf8).write(to: request.files.auxiliaryStorage)
        // A disk of 4 bytes: its size, rounded up, is 1 GB.
        try Data("disk".utf8).write(to: request.files.disk)
    }

    @MainActor func makeMachine(_ request: GuestMachineRequest) throws -> any GuestMachine {
        if let failure = machineFailure { throw failure }
        let machine = FakeGuestMachine()
        machine.stopsWhileStarting = machinesStopWhileStarting
        machine.connectsAgentOnStart = machinesConnectAgent
        update { state in
            state.machines.append(machine)
            state.machineRequests.append(request)
        }
        return machine
    }
}

/// A virtual machine that runs nothing: it records what its owner asks and sends the events the
/// test tells it to.
@MainActor
final class FakeGuestMachine: GuestMachine {
    enum Call: Equatable {
        case start(recovery: Bool)
        case stop
        case shutDownGuest
        case requestStop
    }

    /// One request to the agent.
    struct AgentCall: Equatable {
        var method: String
        var params: [String: JSONValue]
        var data: Data
    }

    var events: ((GuestMachineEvent) -> Void)?
    var virtualMachine: VZVirtualMachine? { nil }
    private(set) var calls: [Call] = []
    /// The requests to the agent, in the order they were sent, without those that grow the
    /// guest's container.
    private(set) var agentCalls: [AgentCall] = []
    /// The requests that grow the guest's container (docs/virtual-machines.md › Starting). They
    /// never reach `agentHandler`, which may run commands on this Mac.
    private(set) var growCalls: [AgentCall] = []
    /// The answer to a request that grows the guest's container: nil answers exit status 0.
    var growFailure: Error?
    /// The exit status of a request that grows the guest's container.
    var growExitStatus = 0
    /// True while the agent is connected.
    private(set) var agentIsConnected = false
    /// True: the agent connects as soon as the virtual machine starts.
    var connectsAgentOnStart = false
    /// Answers a request of the agent; nil answers `{}`.
    var agentHandler: (@Sendable (AgentCall) async throws -> GuestAgentResponse)?
    /// While set, the requests of these methods wait until their hold is released.
    var agentHolds: [String: TestHold] = [:]
    private(set) var isRunning = false
    var startFailure: Error?
    /// True: the guest stops before `start` returns.
    var stopsWhileStarting = false
    /// The outcome of `shutDownGuest()`: nil makes the guest shut down, which sends `stopped`.
    var shutDownFailure: Error?
    /// False: the guest does not shut down when the agent asks it to.
    var shutsDownWhenAsked = true
    /// The outcome of `requestStop()`: nil makes the request go through.
    var requestStopFailure: Error?
    /// True: the person in front of the guest confirms the shutdown that `requestStop()` asks.
    var confirmsStopRequests = false

    func start(recovery: Bool) async throws {
        calls.append(.start(recovery: recovery))
        if let startFailure { throw startFailure }
        isRunning = true
        if connectsAgentOnStart {
            agentConnects(sip: .disabled)
        }
        if stopsWhileStarting {
            guestShutsDown()
        }
    }

    func agentRequest(_ method: String, params: [String: JSONValue], data: Data, timeout: Duration) async throws -> GuestAgentResponse {
        guard agentIsConnected else { throw GuestAgentError.disconnected }
        let call = AgentCall(method: method, params: params, data: data)
        if method == "exec", params["command"] == .string(GuestDisk.growContainerCommand) {
            growCalls.append(call)
            if let growFailure { throw growFailure }
            return GuestAgentResponse(result: ["exitStatus": .int(growExitStatus), "timedOut": .bool(false), "stdout": "",
                                               "stderr": .string(growExitStatus == 0 ? "" : "Error: -69519"), "truncated": .bool(false)])
        }
        agentCalls.append(call)
        if let hold = agentHolds[method] {
            try await hold.wait()
        }
        guard agentIsConnected else { throw GuestAgentError.disconnected }
        return try await agentHandler?(call) ?? GuestAgentResponse()
    }

    func stop() async {
        calls.append(.stop)
        isRunning = false
        agentIsConnected = false
    }

    func shutDownGuest() async throws {
        calls.append(.shutDownGuest)
        if let shutDownFailure { throw shutDownFailure }
        if shutsDownWhenAsked {
            guestShutsDown()
        }
    }

    func requestStop() throws {
        calls.append(.requestStop)
        if let requestStopFailure { throw requestStopFailure }
        if confirmsStopRequests {
            guestShutsDown()
        }
    }

    /// The agent connects and reports this status.
    func agentConnects(sip: GuestAgentStatus.SIP) {
        agentIsConnected = true
        events?(.agentConnected(GuestAgentStatus(version: "1.0", sip: sip, user: "example", osVersion: "27.2.1", osBuild: "26B131",
                                                 accessibility: true, screenRecording: true)))
    }

    func agentDisconnects() {
        agentIsConnected = false
        events?(.agentDisconnected)
    }

    /// The guest shuts down by itself, or the virtual machine fails with `error`.
    func guestShutsDown(error: String? = nil) {
        isRunning = false
        agentIsConnected = false
        events?(.stopped(error: error))
    }
}

extension VMSetupSession {
    /// Short waits for the tests of a guest that does not shut down.
    func useShortWaits() {
        timings = Timings(finishWait: .milliseconds(200), stopWait: .milliseconds(200), restartWait: .milliseconds(200))
    }
}

/// The images of the first `vmImages.changed` event of `stream` that satisfies `predicate`, or nil
/// after the wait limit.
func firstImages(on stream: AsyncStream<EngineEventEnvelope>,
                 where predicate: @escaping @Sendable ([VMImage]) -> Bool) async -> [VMImage]? {
    let envelope = await firstElement(of: stream) { envelope in
        guard envelope.name == VMImagesChangedEvent.name, let images = try? envelope.payload(VMImagesChangedEvent.self) else { return false }
        return predicate(images)
    }
    return envelope.flatMap { try? $0.payload(VMImagesChangedEvent.self) }
}

/// A guest agent and an install script in the test's folder, as `GuestTools`.
func makeGuestTools(in folder: URL) throws -> GuestTools {
    let tools = folder.appendingPathComponent("Tools", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let agent = tools.appendingPathComponent("HephaestusAgent")
    let script = tools.appendingPathComponent("install-agent.sh")
    try Data("agent".utf8).write(to: agent)
    try Data("#!/bin/sh\n".utf8).write(to: script)
    return GuestTools(agent: agent, installScript: script)
}

/// Runs `body` with a test engine whose images come from a `FakeVMImageProvisioner` that answers
/// the list with the ipsw.me capture, and whose guest tools are files of the test's folder.
func withVMEngine<T>(prepare: (DataDirectory) throws -> Void = { _ in },
                     _ body: (Engine, LocalEngineConnection, FakeVMImageProvisioner, URL) async throws -> T) async throws -> T {
    let provisioner = FakeVMImageProvisioner(list: try ipswFixture())
    let toolsFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusCoreTests-tools-\(UUID().uuidString)", isDirectory: true)
    let tools = try makeGuestTools(in: toolsFolder)
    defer { try? FileManager.default.removeItem(at: toolsFolder) }
    return try await withTestEngine(imageProvisioner: provisioner, guestTools: tools, prepare: prepare) { engine, connection, folder in
        try await body(engine, connection, provisioner, folder)
    }
}

/// Adds an image of the newest version.
func addImage(_ connection: LocalEngineConnection, build: String = "26B131") async throws -> VMImage {
    try await connection.call(VMImagesAdd.self, VMImagesAdd.Params(build: build))
}

/// Adds an image and waits until it is in `needsSetup`.
func addInstalledImage(_ connection: LocalEngineConnection, build: String = "26B131") async throws -> VMImage {
    let events = connection.events
    let image = try await addImage(connection, build: build)
    let images = try #require(await firstImages(on: events) { $0.first { $0.id == image.id }?.state == .needsSetup })
    return try #require(images.first { $0.id == image.id })
}

/// Adds an image and finishes its setup: it is Ready.
func addReadyImage(_ engine: Engine, _ connection: LocalEngineConnection, _ provisioner: FakeVMImageProvisioner,
                   build: String = "26B131") async throws -> VMImage {
    let image = try await addInstalledImage(connection, build: build)
    let session = try await engine.beginImageSetup(image.id)
    let machine = try #require(await MainActor.run { provisioner.machines.last })
    await MainActor.run { machine.agentConnects(sip: .disabled) }
    await session.finish()
    let list = try await connection.call(VMImagesList.self)
    return try #require(list.first { $0.id == image.id })
}

/// The data of the first `vms.changed` event of `stream` that satisfies `predicate`, or nil after
/// the wait limit.
func firstVMList(on stream: AsyncStream<EngineEventEnvelope>, where predicate: @escaping @Sendable (VMList) -> Bool) async -> VMList? {
    let envelope = await firstElement(of: stream) { envelope in
        guard envelope.name == VMsChangedEvent.name, let list = try? envelope.payload(VMsChangedEvent.self) else { return false }
        return predicate(list)
    }
    return envelope.flatMap { try? $0.payload(VMsChangedEvent.self) }
}

/// `vms.create` with 2 cores, 4 GB of memory and the image's own disk size, so that the disk does
/// not grow.
func createVM(_ connection: LocalEngineConnection, image: VMImage, name: String = "Menu checks") async throws -> VirtualMachine {
    try await connection.call(VMsCreate.self, VMsCreate.Params(name: name, imageID: image.id, cores: 2, memoryGB: 4, diskGB: image.diskGB))
}

/// Starts a virtual machine for Claude, as a chat of the project DEMO, without the checks of the
/// chat that `vm_start` makes (docs/virtual-machines.md › Lifecycle).
func createClaudeVM(_ engine: Engine, image: VMImage, chatID: ChatID = UUID(), name: String = "Settings check") async throws -> VirtualMachine {
    try await engine.createVirtualMachine(VMsCreate.Params(name: name, imageID: image.id, cores: 2, memoryGB: 4, diskGB: image.diskGB),
                                          startedBy: .claude(projectID: "DEMO", chatID: chatID), .system)
}

/// Waits until `condition` holds, at most the wait limit: the bound only ends a test that fails.
func waitUntil(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + waitLimit
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// The events a test saw, in order.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [EngineEventEnvelope] = []

    var envelopes: [EngineEventEnvelope] { lock.withLock { seen } }

    func append(_ envelope: EngineEventEnvelope) {
        lock.withLock { seen.append(envelope) }
    }
}
