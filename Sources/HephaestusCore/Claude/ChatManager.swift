import Foundation

/// Durations of the chat processes (docs/chats.md › Chat process); tests shorten them.
struct ChatTimings: Sendable {
    /// No `system/init` within this time: the launch failed (Launch, step 7).
    var startTimeout: Duration = .seconds(60)
    /// SIGKILL after the SIGTERM of a termination by the engine (docs/chats.md › Signals).
    var terminateGrace: Duration = .seconds(5)
    /// Each step of the stop sequence: SIGINT, SIGTERM, SIGKILL.
    var stopStep: Duration = .seconds(5)
    /// Idle termination after a turn ends.
    var idleTimeout: Duration = .seconds(20 * 60)
    /// After closing standard input: SIGTERM, then SIGKILL after the same time again.
    var idleCloseGrace: Duration = .seconds(5)
    /// A control request without an answer after this time is forgotten.
    var controlRequestTimeout: Duration = .seconds(30)
    /// `chat.delta` events of a chat are at most this often.
    var deltaInterval: Duration = .milliseconds(50)
    /// SIGKILL after the SIGTERM of the app quit (docs/architecture.md › Shutdown).
    var shutdownGrace: Duration = .seconds(3)
    /// How long the exit handling waits for the remaining output of an exited process.
    var outputGrace: Duration = .milliseconds(500)
}

/// The chats at runtime: Claude chat processes, their stream-json mapping and control protocol,
/// the computed `state` of each chat, pending permission requests, question sets, driving
/// devices, the chat tokens of each launch and idle termination (docs/chats.md). Used only on the
/// engine actor; the chat metadata files are loaded with their project (`DomainState`)
/// (docs/architecture.md › HephaestusCore folders).
final class ChatManager {
    /// The runtime state of the chats that had a process or a message since the engine started.
    var runtimes: [ChatID: ChatRuntime] = [:]
    /// The question set that is not completed, per chat.
    var openQuestionSets: [ChatID: QuestionsItem] = [:]
    /// The symbol request without answer, per chat (docs/chats.md › Symbol requests).
    var openSymbolRequests: [ChatID: SymbolItem] = [:]
    /// The problems of the symbol catalogue were logged (docs/chats.md › Symbol catalogue).
    var loggedSymbolCatalogProblems = false
    /// Chats whose transcript was replayed since the engine started, so that their question
    /// set, their symbol request and their pending permission requests are known.
    var scannedChats: Set<ChatID> = []
    /// The driving device of each chat (docs/engine-api.md › Chat metadata in the API).
    var drivingDevices: [ChatID: String] = [:]
    /// Chats being deleted: lines of their terminating process are ignored.
    var deleting: Set<ChatID> = []
    /// Whether a chat already has a user message with text, which started its naming.
    var hasTextMessage: [ChatID: Bool] = [:]
    /// The cost of each scanned chat (docs/costs.md › Chat cost).
    var costs: [ChatID: ChatCost] = [:]
    /// The last state reported by `chat.updated`, per chat.
    var reportedStates: [ChatID: ChatState] = [:]
    /// The last `backgroundWork` reported by `chat.updated`, per chat.
    var reportedBackgroundWork: [ChatID: Bool] = [:]
    /// The number of the latest notification event of each chat; a summary of an older one is
    /// dropped (docs/chats.md › Notification events).
    var latestNotifications: [ChatID: Int] = [:]
    var notificationCount = 0
    var timings = ChatTimings()
    let transcripts = JSONLinesWriter()
    var nextGeneration = 0
    /// True once the app quits: nothing launches any more.
    var stopped = false

    init() {}

    /// The computed state of a chat (docs/chats.md › Chat states): the first that applies of
    /// error, waitingPermission, starting, running, waitingAnswers, idle. A chat without runtime
    /// state is idle, or waitingAnswers with a question set that is not completed or a symbol
    /// request without answer.
    func state(of chatID: ChatID) -> ChatState {
        let runtime = runtimes[chatID]
        if runtime?.error == true { return .error }
        if let process = runtime?.process, !process.permissionOrder.isEmpty { return .waitingPermission }
        if runtime?.starting == true { return .starting }
        if runtime?.turnInProgress == true { return .running }
        if openQuestionSets[chatID] != nil || openSymbolRequests[chatID] != nil { return .waitingAnswers }
        return .idle
    }

    /// True while the chat's process has background work running (docs/chats.md › Background
    /// work); an exited process has none.
    func backgroundWork(of chatID: ChatID) -> Bool {
        guard let process = runtimes[chatID]?.process, !process.exited else { return false }
        return process.background.isRunning
    }

    /// The device id of the user that last drove the chat since the engine started; `ui.open`
    /// calls of the chat's Claude target it (docs/engine-api.md › Chat metadata in the API).
    func drivingDeviceID(of chatID: ChatID) -> String? {
        drivingDevices[chatID]
    }

    /// The runtime of a chat, created when missing.
    func runtime(_ chatID: ChatID) -> ChatRuntime {
        if let runtime = runtimes[chatID] { return runtime }
        let runtime = ChatRuntime()
        runtimes[chatID] = runtime
        return runtime
    }
}

/// The runtime state of one chat.
final class ChatRuntime {
    /// The live process, or the exited one while its exit is handled.
    var process: ChatProcess?
    /// The project of the chat, recorded at launch.
    var projectID: ProjectID?
    /// A launch is gathering what it needs.
    var launching = false
    /// The process exited and its token is being revoked; the next launch waits.
    var cleaningUp = false
    /// User message lines delivered while no process can take them; the next launch writes them.
    var pendingMessages: [ChatMessageLine] = []
    /// A launch was asked for and `system/init` has not arrived yet.
    var starting = false
    /// A turn is in progress.
    var turnInProgress = false
    /// The last launch or turn failed; the next delivered message clears it.
    var error = false
    /// The launch that follows a missing session was used.
    var sessionRetried = false
    var deltas = DeltaBuffer()
    var deltaTask: Task<Void, Never>?
    var lastDeltaFlush: ContinuousClock.Instant?
    var idleTask: Task<Void, Never>?
    /// What the current turn's report to an orchestrator chat says (docs/chats.md › Orchestrated
    /// ticket chats); also tells whether the turn was stopped or ended in error.
    var turnReport = TurnReport()
    /// `chats.close` was called during the current turn: the chat closes when the turn ends,
    /// unless it is stopped, ends in error or ends because the process exited (docs/chats.md ›
    /// Closing a chat).
    var closeAfterTurn = false

    /// The process can take a message now: it runs and the engine is not ending it.
    var liveProcess: ChatProcess? {
        guard let process, !process.exited, !process.terminatedByEngine, !cleaningUp else { return nil }
        return process
    }
}

/// What a control request of the engine is for. `permissionMode` keeps the mode it asks for and
/// the actor that changed it, for the approvals of its success answer (docs/chats.md › Changing
/// settings).
enum ControlPurpose: Sendable, Equatable {
    case initialize, interrupt, model, effort, ultracode
    case permissionMode(PermissionMode, origin: Actor)

    /// The setting named in the warning of a refused setting (docs/chats.md › Control protocol).
    var settingName: String? {
        switch self {
        case .model: return "model"
        case .permissionMode: return "permission mode"
        case .effort: return "effort"
        case .ultracode: return "ultracode"
        case .initialize, .interrupt: return nil
        }
    }
}

/// A pending `can_use_tool` request: its item and the `permission_suggestions`.
struct PendingPermission {
    var item: PermissionRequestItem
    var suggestions: JSONValue?
}

/// One Claude process of a chat.
final class ChatProcess {
    let handle: any ClaudeProcess
    let generation: Int
    /// Launched with `--resume`.
    let resumed: Bool
    /// The MCP port written in its configuration file.
    var mcpPort: Int
    var mapper: StreamMapper
    let log: AppendFile
    let stdoutCapture: AppendFile?
    let stderr = StderrTracker()
    let stdoutFinished = Latch()

    var sawInit = false
    /// User message lines written before `system/init`, delivered again when the session was
    /// not found.
    var messagesBeforeInit: [ChatMessageLine] = []
    /// The messages written whose `UserPromptSubmit` hook has not run yet.
    var hookRecords = LinkedItemsHookRecords()
    /// The messages written to the process that the CLI has not finished, and its open CLI turn.
    var turns = TurnTracker()
    /// The background work the CLI reports for the process.
    var background = BackgroundWorkTracker()
    var nextRequestNumber = 1
    var pendingControl: [String: (purpose: ControlPurpose, timer: Task<Void, Never>?)] = [:]
    var permissions: [String: PendingPermission] = [:]
    var permissionOrder: [String] = []
    var initTimer: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var terminationTask: Task<Void, Never>?
    /// Stop was pressed during the current turn.
    var stopRequested = false
    /// The engine ends the process: idle termination, deletion, project removal, missing
    /// `system/init`, an `mcpPort` change or the app quit.
    var terminatedByEngine = false
    /// End the process when its turn ends (an `mcpPort` change during a turn).
    var terminateAfterTurn = false
    var exited = false

    init(handle: any ClaudeProcess, generation: Int, resumed: Bool, mcpPort: Int, mapper: StreamMapper, log: AppendFile,
         stdoutCapture: AppendFile?) {
        self.handle = handle
        self.generation = generation
        self.resumed = resumed
        self.mcpPort = mcpPort
        self.mapper = mapper
        self.log = log
        self.stdoutCapture = stdoutCapture
    }

    /// The next request id: `hephaestus-<n>`, counting from 1.
    func takeRequestID() -> String {
        defer { nextRequestNumber += 1 }
        return ControlLines.requestID(nextRequestNumber)
    }

    func cancelTimers() {
        initTimer?.cancel()
        stopTask?.cancel()
        for entry in pendingControl.values { entry.timer?.cancel() }
    }
}

/// A user message line for the Claude process, the `uuid` it carries (docs/chats.md › User
/// messages), and what the linked items hook needs: the text of its `text` block and the
/// `Open in the app:` lines of its linked items (docs/chats.md › Linked items hook).
struct ChatMessageLine: Sendable, Hashable {
    var data: Data
    var uuid: String
    var prompt: String = ""
    var context: [String] = []
}

/// docs/chats.md › Turn tracking: the user messages written to one process that the CLI has not
/// finished, each with the last `command_lifecycle` state reported, and whether a CLI turn is
/// open (from a `system/init` to its `result`).
struct TurnTracker: Sendable {
    enum MessageState: Sendable, Equatable {
        /// Written; the CLI has reported nothing yet.
        case none
        case queued
        case started
    }

    private(set) var outstanding: [(uuid: String, state: MessageState)] = []
    private(set) var cliTurnOpen = false

    /// Claude still works on something: a message is outstanding or a CLI turn is open.
    var isWorking: Bool { cliTurnOpen || !outstanding.isEmpty }

    /// Step 1: a message written to the process.
    mutating func written(_ uuid: String) {
        outstanding.append((uuid, .none))
    }

    /// Step 2: `system/init`.
    mutating func cliTurnOpened() {
        cliTurnOpen = true
    }

    /// Step 3: a `command_lifecycle` line. Returns true when it finished an outstanding message.
    mutating func commandState(_ uuid: String, _ state: String) -> Bool {
        guard let index = outstanding.firstIndex(where: { $0.uuid == uuid }) else { return false }
        switch state {
        case "queued":
            outstanding[index].state = .queued
            return false
        case "started":
            outstanding[index].state = .started
            return false
        default:
            outstanding.remove(at: index)
            return true
        }
    }

    /// Step 4: `result` closes the CLI turn and finishes the started messages, or else the oldest
    /// message the CLI reported nothing about.
    mutating func resultReceived() {
        cliTurnOpen = false
        if outstanding.contains(where: { $0.state == .started }) {
            outstanding.removeAll { $0.state == .started }
        } else if let index = outstanding.firstIndex(where: { $0.state == .none }) {
            outstanding.remove(at: index)
        }
    }
}

/// docs/chats.md › Background work: the background tasks of one process that the CLI reports
/// running, every task id it has listed, and whether a notification turn is pending: the CLI
/// turn the CLI starts on its own to give Claude the result of a background task that ended while
/// no CLI turn was open.
struct BackgroundWorkTracker: Sendable {
    private(set) var runningTasks: Set<String> = []
    private var listedTasks: Set<String> = []
    private(set) var notificationTurnPending = false

    /// The process has background work running.
    var isRunning: Bool { !runningTasks.isEmpty || notificationTurnPending }

    /// Rule 1: `background_tasks_changed`.
    mutating func tasksChanged(_ taskIDs: [String]) {
        runningTasks = Set(taskIDs)
        listedTasks.formUnion(taskIDs)
    }

    /// Rule 2: `task_notification`; only a listed task that ends while no CLI turn is open makes
    /// a notification turn pending.
    mutating func taskEnded(_ taskID: String, cliTurnOpen: Bool) {
        guard !cliTurnOpen, listedTasks.contains(taskID) else { return }
        notificationTurnPending = true
    }

    /// Rule 3: `system/init` ends the pending notification turn.
    mutating func cliTurnOpened() {
        notificationTurnPending = false
    }
}

/// The text streamed per block and not yet sent as `chat.delta` (docs/chats.md › Streaming).
struct DeltaBuffer {
    struct Pending {
        var itemID: String
        var kind: ChatDeltaEvent.Payload.Kind
        var text: String
        /// Order in which the buffer became non-empty.
        var since: Int
    }

    private var pending: [String: Pending] = [:]
    private var counter = 0

    var isEmpty: Bool { pending.isEmpty }

    mutating func append(itemID: String, kind: ChatDeltaEvent.Payload.Kind, text: String) {
        if pending[itemID] != nil {
            pending[itemID]?.text += text
        } else {
            counter += 1
            pending[itemID] = Pending(itemID: itemID, kind: kind, text: text, since: counter)
        }
    }

    /// Drops the buffer of a block whose final item was emitted.
    mutating func drop(_ itemID: String) {
        pending[itemID] = nil
    }

    /// Takes the buffer that became non-empty first.
    mutating func takeOldest() -> Pending? {
        guard let oldest = pending.values.min(by: { $0.since < $1.since }) else { return nil }
        pending[oldest.itemID] = nil
        return oldest
    }
}
