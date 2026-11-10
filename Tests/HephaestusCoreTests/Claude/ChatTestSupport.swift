import Foundation
import Testing
@testable import HephaestusCore

/// Records the events of a connection, so that a test can wait for one or read them all.
actor EventRecorder {
    private var events: [EngineEventEnvelope] = []
    private var waiters: [UUID: (predicate: @Sendable (EngineEventEnvelope) -> Bool, continuation: CheckedContinuation<EngineEventEnvelope?, Never>)] = [:]
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<EngineEventEnvelope>) {
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<EngineEventEnvelope>) {
        task = Task {
            for await event in stream { self.receive(event) }
        }
    }

    private func receive(_ event: EngineEventEnvelope) {
        events.append(event)
        for (id, waiter) in waiters where waiter.predicate(event) {
            waiters[id] = nil
            waiter.continuation.resume(returning: event)
        }
    }

    var all: [EngineEventEnvelope] { events }

    func named(_ name: String) -> [EngineEventEnvelope] { events.filter { $0.name == name } }

    /// The first event (already received or to come) named `name` that satisfies `predicate`.
    func wait(for name: String, timeout: Duration = waitLimit,
              where predicate: @escaping @Sendable (EngineEventEnvelope) -> Bool = { _ in true }) async -> EngineEventEnvelope? {
        if let existing = events.first(where: { $0.name == name && predicate($0) }) { return existing }
        let id = UUID()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            self.timeOut(id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            waiters[id] = ({ $0.name == name && predicate($0) }, continuation)
        }
    }

    private func timeOut(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }

    func stop() {
        task?.cancel()
        for waiter in waiters.values { waiter.continuation.resume(returning: nil) }
        waiters = [:]
    }
}

extension EngineEventEnvelope {
    /// The item of a `chat.item` event.
    var chatItem: ChatItem? { try? payload(ChatItemEvent.self).item }
    /// The metadata of a `chat.updated` event.
    var chatMeta: ChatMeta? { try? payload(ChatUpdatedEvent.self) }
}

/// A started test engine with the project DEMO (`Demo`) registered on disk, the fake launcher,
/// and short timings.
struct ChatTestBed {
    let engine: Engine
    let connection: LocalEngineConnection
    let launcher: FakeClaudeLauncher
    let folder: ProjectFolder
    let dataDirectory: DataDirectory
    let events: EventRecorder

    var root: URL { folder.root }

    /// A new chat of the project; with a message it starts Claude.
    func createChat(kind: ChatKind = .project, ticketID: TicketID? = nil, bundleID: BundleID? = nil, settings: ChatSettings? = nil,
                    message: String? = nil) async throws -> ChatMeta {
        try await connection.call(ChatsCreate.self, .init(projectID: "DEMO", kind: kind, ticketID: ticketID, bundleID: bundleID,
                                                          settings: settings, message: message.map { ChatMessageInput(text: $0) }))
    }

    func send(_ chatID: ChatID, _ text: String, attachments: [AttachmentUpload]? = nil) async throws {
        _ = try await connection.call(ChatsSend.self, .init(chatID: chatID, message: ChatMessageInput(text: text, attachments: attachments)))
    }

    func transcript(_ chatID: ChatID) async throws -> [ChatItem] {
        try await connection.call(ChatsGet.self, .init(chatID: chatID)).items
    }

    func state(_ chatID: ChatID) async -> ChatState {
        await engine.chatState(chatID)
    }

    /// Waits until the chat has `state`.
    @discardableResult
    func waitForState(_ chatID: ChatID, _ state: ChatState, timeout: Duration = waitLimit) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await self.state(chatID) == state { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await self.state(chatID) == state
    }

    /// Waits for a `chat.item` of the chat whose item satisfies `predicate`.
    func waitForItem(_ chatID: ChatID, timeout: Duration = waitLimit,
                     where predicate: @escaping @Sendable (ChatItem) -> Bool) async -> ChatItem? {
        await events.wait(for: "chat.item", timeout: timeout) { event in
            guard let payload = try? event.payload(ChatItemEvent.self), payload.chatID == chatID else { return false }
            return predicate(payload.item)
        }?.chatItem
    }

    /// The `system` item texts of the chat's transcript file.
    func systemTexts(_ chatID: ChatID) async throws -> [String] {
        try await transcript(chatID).compactMap { item in
            if case .system(let system) = item { return system.text }
            return nil
        }
    }

    /// Writes a ticket file and reloads it, as a change made outside the engine.
    func writeTicket(_ ticket: Ticket) async throws {
        try ProjectFileStore.write(ticket, to: folder)
        await engine.projectDataFilesChanged(projectID: "DEMO", paths: [folder.ticketFile(ticket.id).path])
    }

    /// Writes a bundle file and reloads it, as a change made outside the engine.
    func writeBundle(_ bundle: TicketBundle) async throws {
        try ProjectFileStore.write(bundle, to: folder)
        await engine.projectDataFilesChanged(projectID: "DEMO", paths: [folder.bundleFile(bundle.id).path])
    }
}

/// Fast timings: the graces and steps that tests wait for are short. The fake answers at once,
/// so the start and control request timeouts and the output grace only bound a run that a busy
/// machine slows down: they are `waitLimit`.
func testChatTimings() -> ChatTimings {
    var timings = ChatTimings()
    timings.startTimeout = waitLimit
    timings.terminateGrace = .milliseconds(300)
    timings.stopStep = .milliseconds(300)
    timings.idleTimeout = .seconds(60)
    timings.idleCloseGrace = .milliseconds(200)
    timings.controlRequestTimeout = waitLimit
    timings.shutdownGrace = .milliseconds(500)
    // The fake's output ends with its exit: the grace only gives a loaded machine time to read it.
    timings.outputGrace = waitLimit
    return timings
}

/// The fake CLI answers at once; the timeouts only bound a run that a busy machine slows down.
func testCLITimings() -> ClaudeCLITimings {
    var timings = ClaudeCLITimings()
    timings.versionTimeout = waitLimit
    timings.loginShellTimeout = waitLimit
    timings.probeTimeout = waitLimit
    timings.killGrace = .milliseconds(200)
    timings.statusWait = waitLimit
    timings.shutdownGrace = .milliseconds(500)
    return timings
}

extension Engine {
    /// Sets the timings before `start()`.
    func useTimings(chats chatTimings: ChatTimings, cli cliTimings: ClaudeCLITimings) {
        chats.timings = chatTimings
        claudeCLI.timings = cliTimings
    }

    func chatState(_ chatID: ChatID) -> ChatState {
        chats.state(of: chatID)
    }

    /// Waits until the CLI status is no longer `checking`.
    func waitUntilClaudeChecked(timeout: Duration = waitLimit) async {
        let deadline = ContinuousClock.now + timeout
        while claudeCLI.status.checking, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    var currentClaudeStatus: ClaudeStatus { claudeCLI.status }
}

/// Runs `body` with a started engine whose data directory and project DEMO are in a new
/// temporary folder, then closes the connection and shuts the engine down.
func withChatEngine<T>(launcher: FakeClaudeLauncher = FakeClaudeLauncher(), debugTools: Bool = false, settings: HostSettings? = nil,
                       chatTimings: ChatTimings = testChatTimings(), cliTimings: ClaudeCLITimings = testCLITimings(),
                       waitForCLI: Bool = true, githubCLI: (any GitHubCLIRunning)? = nil,
                       imageProvisioner: (any VMImageProvisioning)? = nil, guestTools: GuestTools? = nil,
                       prepare: (ProjectFolder, DataDirectory) throws -> Void = { _, _ in },
                       _ body: (ChatTestBed) async throws -> T) async throws -> T {
    try await TestEngineSlots.withSlot { try await withTemporaryDirectory { temporary in
        let data = DataDirectory(url: temporary.appendingPathComponent("Data", isDirectory: true))
        try FileManager.default.createDirectory(at: data.url, withIntermediateDirectories: true)
        let root = temporary.appendingPathComponent("Project", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = ProjectFolder(root: root)
        try ProjectFileStore.write(Project(id: "DEMO", name: "Demo", created: ISODate.date(from: "2026-10-31T12:00:00Z")!), to: folder)
        try DeviceFileStore.write(Registry(projects: [folder.root.path]), to: data)
        if let settings { try DeviceFileStore.write(settings, to: data) }
        try prepare(folder, data)
        let engine = try await Engine(configuration: .test(dataDirectory: data.url, debugTools: debugTools, claudeLauncher: launcher,
                                                           githubCLI: githubCLI, imageProvisioner: imageProvisioner,
                                                           guestTools: guestTools))
        await engine.useFileTrash(.folder(temporary.appendingPathComponent("Trash", isDirectory: true)))
        await engine.useTimings(chats: chatTimings, cli: cliTimings)
        await engine.start()
        let connection = await LocalEngineConnection(engine: engine)
        let bed = ChatTestBed(engine: engine, connection: connection, launcher: launcher, folder: folder, dataDirectory: data,
                              events: EventRecorder(connection.events))
        if waitForCLI { await engine.waitUntilClaudeChecked() }
        do {
            let result = try await body(bed)
            await bed.events.stop()
            connection.close()
            await engine.shutdown()
            return result
        } catch {
            await bed.events.stop()
            connection.close()
            await engine.shutdown()
            throw error
        }
    } }
}
