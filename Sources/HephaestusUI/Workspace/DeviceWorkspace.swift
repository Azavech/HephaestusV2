// OWNER: ui-shell — DeviceWorkspace: the connection, the device's data, the event fan-out, the
// call helper and the replay rule (docs/ui.md › DeviceWorkspace; docs/remote.md › Seeding calls
// and the replay rule).
import Foundation
import HephaestusCore
import Observation

/// One engine event as a workspace delivers it to its views, after applying it.
struct WorkspaceEvent: Sendable {
    /// The actor of the call that caused the event.
    var origin: EngineActor
    var event: DecodedEngineEvent
    /// Chat ids whose metadata the workspace dropped while applying the event (a removed project).
    var removedChatIDs: [String] = []

    /// The kind of the event for the replay rule (docs/remote.md › Event kinds).
    var kind: EventKind {
        switch event {
        case .chatDelta, .runOutput: return .stream
        case .uiOpen, .unknown: return .action
        default: return .state
        }
    }

    enum EventKind {
        /// Carries a complete value, a deletion or a reload request: applying it twice is harmless.
        case state
        /// Appends: applied once, on arrival.
        case stream
        /// Acts: applied once, on arrival.
        case action
    }
}

/// The data of one device, built from its snapshot and kept current by its engine events
/// (docs/ui.md › DeviceWorkspace). Every window showing the device shares its workspace.
///
/// Views read the properties and call `call(_:_:)`; section views that keep their own caches use
/// `seed(_:replace:replay:)` for their seeding calls and `events()` for the events.
@MainActor @Observable
final class DeviceWorkspace {
    /// The device this workspace shows.
    let deviceID: String
    /// `true` for This Mac.
    let isLocal: Bool
    /// `LocalEngineConnection` or `RemoteEngineConnection`.
    let connection: any EngineConnection
    /// The remote connection, for its phase and Reconnect Now; nil for This Mac.
    @ObservationIgnored let remoteConnection: RemoteEngineConnection?

    /// `connecting`, `connected` or `disconnected(reason)`, from the connection.
    private(set) var state: ConnectionState
    /// The phase and next attempt date of a remote connection; nil for This Mac.
    private(set) var phase: RemoteConnectionPhase?
    /// `true` once the workspace has been connected.
    private(set) var hasConnected = false
    /// The message of the last failed connection attempt, shown by the reconnect view while it
    /// reconnects (docs/ui.md › Reconnect view).
    private(set) var lastFailureMessage: String?
    var deviceInfo: DeviceInfo?
    var settings: HostSettings?
    var claudeStatus: ClaudeStatus?
    var models: [ClaudeModel] = []
    /// Every project of the device, sub projects included, in `projects.list` order.
    var projects: [ProjectSummary] = []
    var skills: [SkillSummary] = []
    /// Runs by run id (uppercase UUID string).
    var runs: [String: RunState] = [:]
    /// The metadata of every chat of every project, by chat id (uppercase UUID string).
    var chats: [String: ChatMeta] = [:]
    /// Loaded projects, by id.
    var details: [String: ProjectDetail] = [:]
    /// Project id → ticket id → ticket, for loaded projects.
    var tickets: [String: [String: Ticket]] = [:]
    /// Project id → bundle id → bundle, for loaded projects.
    var bundles: [String: [String: TicketBundle]] = [:]
    /// Web tabs of loaded projects, by project id.
    var webTabs: [String: [WebTab]] = [:]
    /// One transcript state per chat shown in a view, by chat id.
    var transcripts: [String: TranscriptState] = [:]
    /// Projects whose detail, tickets, bundles and web tabs are loaded.
    var loadedProjectIDs: Set<String> = []
    /// Unsent composer text and attachments of existing chats, by chat id.
    var drafts: [String: ComposerDraft] = [:]

    // MARK: Loading state (docs/ui.md › Empty states)

    /// True once the device-level data came from a snapshot.
    var hasSnapshot = false
    /// Projects whose seeding calls are in flight.
    var loadingProjectIDs: Set<String> = []
    /// The error of a failed seeding call of a project, until Try Again succeeds.
    var projectLoadErrors: [String: EngineError] = [:]
    /// Incremented each time the workspace becomes connected; views that load their own data run
    /// their seeding calls again when it changes (docs/remote.md › After a reconnect).
    private(set) var connectionGeneration = 0

    /// The parts of a project's seeding calls that succeeded.
    @ObservationIgnored var seededParts: [String: Set<ProjectPart>] = [:]
    /// Parent of every project seen since the workspace opened, to find the nearest remaining
    /// ancestor of a removed project (docs/projects.md › Removing a project).
    @ObservationIgnored var knownParents: [String: String] = [:]
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<WorkspaceEvent>.Continuation] = [:]
    @ObservationIgnored private var recorders: [UUID: [WorkspaceEvent]] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private(set) var isClosed = false

    /// The parts of a project that the four seeding calls load (docs/ui.md › DeviceWorkspace,
    /// Loading step 3).
    enum ProjectPart: CaseIterable {
        case detail, tickets, bundles, webTabs
    }

    /// Opens the workspace of a connection: subscribes to its events first, then follows its
    /// state; each time the state becomes `connected`, the device-level data is loaded.
    init(deviceID: String, connection: any EngineConnection, remote: RemoteEngineConnection? = nil, isLocal: Bool) {
        self.deviceID = deviceID
        self.isLocal = isLocal
        self.connection = connection
        self.remoteConnection = remote
        self.state = connection.state
        self.deviceInfo = connection.deviceInfo
        self.phase = remote?.phase
        let events = connection.events
        let states = connection.stateUpdates
        tasks.append(Task { [weak self] in
            for await envelope in events {
                self?.receive(envelope)
            }
        })
        tasks.append(Task { [weak self] in
            for await state in states {
                self?.connectionStateChanged(state)
            }
        })
        if let remote {
            let phases = remote.phaseUpdates
            tasks.append(Task { [weak self] in
                for await phase in phases {
                    self?.phaseChanged(phase)
                }
            })
        }
    }

    /// Closes the connection of a remote workspace; the local workspace is never closed.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.close()
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    // MARK: Derived values

    var isConnected: Bool { state == .connected }

    /// The device name: from the engine once known, else the paired record's name.
    var deviceName: String {
        deviceInfo?.name ?? remoteConnection?.device.name ?? "This Mac"
    }

    /// The summary of a project of this device.
    func project(_ projectID: String) -> ProjectSummary? {
        projects.first { $0.id == projectID }
    }

    /// The top-level ancestor of a project, the project itself for a top-level one.
    func topLevelProject(of projectID: String) -> ProjectSummary? {
        var current = project(projectID)
        while let parentID = current?.parentID, let parent = project(parentID) {
            current = parent
        }
        return current
    }

    /// Every descendant of a project in `projects.list` order, with its depth below it (1 for a
    /// direct sub project).
    func descendants(of projectID: String) -> [(project: ProjectSummary, depth: Int)] {
        projects.compactMap { summary in
            var depth = 0
            var parentID = summary.parentID
            while let current = parentID {
                depth += 1
                if current == projectID { return (summary, depth) }
                parentID = project(current)?.parentID
            }
            return nil
        }
    }

    /// The chats of a project.
    func chats(of projectID: String) -> [ChatMeta] {
        chats.values.filter { $0.projectID == projectID }
    }

    /// The runs of a project, newest first.
    func runs(of projectID: String) -> [RunState] {
        runs.values.filter { $0.info.projectID == projectID }.sorted { $0.info.started > $1.info.started }
    }

    // MARK: Calls

    /// Calls a method on the device's engine. Throws EngineError only.
    func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        try await connection.call(method, params)
    }

    /// Calls a method without params.
    func call<M: EngineMethod>(_ method: M.Type) async throws -> M.Result where M.Params == Empty {
        try await connection.call(method, Empty())
    }

    /// Runs a seeding call under the replay rule (docs/remote.md › Seeding calls and the replay
    /// rule): the state events that arrive while it is in flight are recorded; when the result
    /// arrives, `replace` stores it, then the recorded events are passed to `replay` in arrival
    /// order. Every event is also applied when it arrives, so a failed call leaves the data as the
    /// events made it. Stream and action events are never recorded.
    @discardableResult
    func seed<R>(_ call: () async throws -> R, replace: (R) -> Void, replay: (WorkspaceEvent) -> Void) async throws -> R {
        let id = UUID()
        recorders[id] = []
        let result: R
        do {
            result = try await call()
        } catch {
            recorders[id] = nil
            throw error
        }
        let recorded = recorders.removeValue(forKey: id) ?? []
        replace(result)
        for event in recorded {
            replay(event)
        }
        return result
    }

    // MARK: Events

    /// A new stream of the workspace's events, each delivered after the workspace applied it, in
    /// arrival order. It finishes when the workspace closes.
    func events() -> AsyncStream<WorkspaceEvent> {
        let (stream, continuation) = AsyncStream<WorkspaceEvent>.makeStream(bufferingPolicy: .unbounded)
        guard !isClosed else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.subscribers[id] = nil
            }
        }
        return stream
    }

    private func receive(_ envelope: EngineEventEnvelope) {
        guard let decoded = try? envelope.decoded() else {
            // DOC-GAP: the docs do not say what a client does with an event whose payload does
            // not decode; it is ignored like an unknown message (docs/remote.md › Unknown messages).
            return
        }
        var event = WorkspaceEvent(origin: envelope.origin, event: decoded)
        if event.kind == .state {
            for id in recorders.keys {
                recorders[id]?.append(event)
            }
        }
        apply(&event)
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: Connection

    private func connectionStateChanged(_ newState: ConnectionState) {
        let wasConnected = state == .connected
        state = newState
        guard newState == .connected, !wasConnected || connectionGeneration == 0 else { return }
        let reconnect = hasConnected
        hasConnected = true
        connectionGeneration += 1
        Task { [weak self] in
            await self?.loadDeviceLevelData(afterReconnect: reconnect)
        }
    }

    private func phaseChanged(_ newPhase: RemoteConnectionPhase) {
        phase = newPhase
        switch newPhase {
        case .waiting(let message, _), .needsPairing(let message), .sameDevice(let message), .replaced(let message):
            lastFailureMessage = message
        case .connected:
            lastFailureMessage = nil
        case .connecting, .helloSent, .authSent, .closed:
            break
        }
    }

    /// Reconnect Now of the reconnect view (docs/remote.md › Phases).
    func reconnectNow() {
        remoteConnection?.reconnectNow()
    }
}
