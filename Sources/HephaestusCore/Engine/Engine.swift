import Foundation
import SystemConfiguration

/// The engine of one device: the only code that reads or writes project folders and the data
/// directory, and that starts Claude processes and project runs (docs/architecture.md › Engine
/// and client split). Every client calls `dispatch(method:params:actor:)` with JSON params and
/// receives the JSON events of `subscribe()` (docs/engine-api.md › Dispatcher).
///
/// Use: `let engine = try await Engine(configuration: configuration)`, then `await engine.start()`,
/// then clients through `LocalEngineConnection(engine:)`; `await engine.shutdown()` at quit.
public actor Engine {
    /// A registered method: the actor kinds it accepts and its JSON handler.
    struct Registration: Sendable {
        var actors: Set<ActorKind>
        var run: @Sendable (Data, Actor) async throws -> Data
    }

    enum Lifecycle {
        case created, running, stopped
    }

    // MARK: Device and configuration

    public nonisolated let configuration: EngineConfiguration
    public nonisolated let dataDirectory: DataDirectory
    /// `Logs/engine.log`.
    public nonisolated let log: EngineLog
    /// This device's id, the uppercase UUID of device.yml.
    public nonisolated let deviceID: String
    /// `secrets.json`, shared by the services that read or change it.
    nonisolated let secrets: SecretsStore
    private let lock: DataDirectoryLock

    /// `device.yml` as loaded at launch.
    var device: DeviceRecord
    /// The Mac's computer name, read at launch; the device name when device.yml has none.
    let computerName: String
    /// `settings.yml`.
    var settings: HostSettings
    /// The engine's own writes, recognized by the file watchers (docs/data-model.md › External
    /// changes).
    let ownWrites = OwnWrites()

    // MARK: Engine-owned services, filled by their owners (see each type)

    /// Loaded projects, tickets, bundles and chat metadata (Engine/DomainState.swift).
    var domain: DomainState
    /// Project runs (Engine/ProjectRunner.swift).
    let runs = ProjectRunner()
    /// Claude CLI location, status and models (Claude/ClaudeCLI.swift).
    let claudeCLI = ClaudeCLI()
    /// Chat processes (Claude/ChatManager.swift).
    let chats = ChatManager()
    /// Haiku naming (Claude/TitleNaming.swift).
    let titleNamer: any TitleNamer
    /// The skills library (Skills/SkillsLibrary.swift).
    let skillsLibrary = SkillsLibrary()
    /// Generated skills plugin folders (Skills/SkillsPlugin.swift).
    let skillsPlugins: any SkillsPluginProvider
    /// files.*, docs.list, fs.browse, FSEvents and the Trash (Files/FileService.swift).
    let files = FileService()
    /// search.query (Search/SearchService.swift).
    let search = SearchService()

    // MARK: Servers and local-only services (docs/architecture.md › Local-only services)

    /// Chat tokens and the external token of the MCP server.
    public nonisolated let tokens: MCPTokenStore
    /// The MCP server on 127.0.0.1; its `state` is part of the server status service.
    public nonisolated let mcpServer: MCPServer
    /// The sync server; its status is part of the server status service.
    public nonisolated let syncServer: SyncServer
    /// Bonjour browsing for nearby and paired devices.
    public nonisolated let deviceBrowser: DeviceBrowser
    /// `remotes.yml` and the codes of the paired devices.
    public nonisolated let pairedDevices: PairedDevicesStore

    // MARK: Dispatcher and subscriptions

    private var handlers: [String: Registration] = [:]
    private var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var lifecycle = Lifecycle.created

    /// Startup steps 2 to 4 of docs/architecture.md › Startup, without the projects: creates the
    /// data directory when missing and takes its lock (`StorageError.dataDirectoryInUse` when
    /// another process holds it, exit status 75 for the app), opens `Logs/engine.log` and loads
    /// the device files (docs/data-model.md › Loading). Every method is registered.
    public init(configuration: EngineConfiguration) async throws {
        let directory = DataDirectory(url: configuration.dataDirectory)
        try directory.createIfNeeded()
        let lock = try DataDirectoryLock.acquire(directory)
        let log: EngineLog
        do {
            log = try EngineLog(fileURL: directory.engineLogFile)
        } catch {
            throw StorageError.writeFailed(path: directory.engineLogFile.path, reason: error.localizedDescription)
        }
        let files = try DeviceFileStore.loadAll(directory, log: log)
        let secrets = SecretsStore(directory: directory, secrets: files.secrets)
        let deviceID = files.device.id.uuidString.uppercased()
        let tokens = MCPTokenStore(secrets: secrets)

        self.configuration = configuration
        self.dataDirectory = directory
        self.lock = lock
        self.log = log
        self.deviceID = deviceID
        self.secrets = secrets
        self.device = files.device
        self.computerName = Engine.readComputerName()
        self.settings = files.settings
        self.domain = DomainState(registry: files.registry)
        self.titleNamer = HaikuTitleNamer()
        self.skillsPlugins = SkillsPluginGenerator()
        self.tokens = tokens
        self.mcpServer = MCPServer(tokens: tokens, debugTools: configuration.debugTools, appVersion: configuration.appVersion, log: log)
        self.syncServer = SyncServer(secrets: secrets, log: log)
        self.deviceBrowser = DeviceBrowser(ownDeviceID: deviceID, log: log)
        self.pairedDevices = PairedDevicesStore(dataDirectory: directory, remotes: files.remotes, secrets: secrets, log: log)

        registerAllHandlers()
    }

    /// Startup steps 4 to 7 of docs/architecture.md › Startup, in this order: the projects and
    /// the file watching, Bonjour browsing, the MCP server, the sync server when `syncEnabled`
    /// is true, then the background tasks of the Claude CLI. Calling it again does nothing.
    public func start() async {
        guard lifecycle == .created else { return }
        lifecycle = .running
        await loadProjects()
        await startFileWatching()
        await startSkillsLibraryWatching()
        startDeviceBrowsing()
        await startMCPServer()
        await startSyncServer()
        await startClaudeBackgroundTasks()
    }

    /// docs/architecture.md › Shutdown, steps 1 to 3 and 5: the child processes end (SIGTERM, then
    /// SIGKILL 3 s later, the quit items of the chats written first) and the engine waits for
    /// them; then the MCP server, the sync server, Bonjour and the file watchers close; then
    /// `beforeClosingLog` runs (step 4, telling the Updater, belongs to `AppModel`); every
    /// subscription finishes; engine.log closes and the data directory lock is released. Calling
    /// it again does nothing.
    public func shutdown(beforeClosingLog: @Sendable () async -> Void = {}) async {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopped
        async let chatProcesses: Void = stopChatProcesses()
        async let projectRuns: Void = stopProjectRuns()
        async let claudeHelpers: Void = stopClaudeHelperProcesses()
        _ = await (chatProcesses, projectRuns, claudeHelpers)

        await stopMCPServer()
        await stopSyncServer()
        stopDeviceBrowsing()
        await stopFileWatching()
        await stopSkillsLibraryWatching()
        await beforeClosingLog()

        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
        log.close()
        lock.release()
    }

    // MARK: Dispatcher

    /// Runs one call. Throws EngineError only. The checks run in the order of
    /// docs/engine-api.md › Dispatcher: the method exists, the actor's kind may call it (system
    /// always may), the params decode (empty data counts as `{}`), then the handler runs and its
    /// result is encoded.
    public func dispatch(method: String, params: Data, actor: Actor) async throws -> Data {
        guard let registration = handlers[method] else {
            throw EngineError.unknownMethod(method)
        }
        guard actor.kind == .system || registration.actors.contains(actor.kind) else {
            throw EngineError.notAvailable(method, to: actor.kind)
        }
        return try await registration.run(params, actor)
    }

    /// Typed call through `dispatch`, for the MCP server and tests: same encoding path.
    public nonisolated func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params, actor: Actor) async throws -> M.Result {
        let data: Data
        do {
            data = try EngineJSON.encode(params)
        } catch {
            throw EngineError.internalError(error)
        }
        let result = try await dispatch(method: M.name, params: data, actor: actor)
        do {
            return try EngineJSON.decode(M.Result.self, from: result)
        } catch {
            throw EngineError.unexpectedResult(M.name)
        }
    }

    /// The wire names of every registered method, sorted.
    public var registeredMethods: [String] {
        handlers.keys.sorted()
    }

    /// The actor kinds registered for a method; nil when no method has this name.
    func registeredActors(for method: String) -> Set<ActorKind>? {
        handlers[method]?.actors
    }

    /// A new stream of encoded EngineEventEnvelope JSON; finishes when the engine stops. It
    /// receives every event emitted after it starts and none emitted before, in emission order,
    /// and never drops one (docs/architecture.md › Event subscriptions).
    public func subscribe() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        guard lifecycle != .stopped else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Registers the handler of a method with the actor kinds of the Actors column of
    /// docs/engine-api.md › Method index. The params are decoded and the result encoded with
    /// `EngineJSON`; an error other than EngineError becomes `internal` and is logged.
    func register<M: EngineMethod>(
        _ method: M.Type,
        actors: Set<ActorKind>,
        _ handler: @escaping @Sendable (M.Params, Actor) async throws -> M.Result
    ) {
        let log = self.log
        handlers[M.name] = Registration(actors: actors) { data, actor in
            let params: M.Params
            do {
                params = try Engine.decodeParams(M.Params.self, from: data)
            } catch {
                throw EngineError.invalidParams(M.name, decoding: error)
            }
            let result: M.Result
            do {
                result = try await handler(params, actor)
            } catch let error as EngineError {
                throw error
            } catch {
                log.error(.engine, "\(M.name) failed: \(error)")
                throw EngineError.internalError(error)
            }
            do {
                return try EngineJSON.encode(result)
            } catch {
                log.error(.engine, "\(M.name): the result cannot be encoded: \(error)")
                throw EngineError.internalError(error)
            }
        }
    }

    /// Params: empty data, or JSON `null`, count as `{}` (docs/engine-api.md › JSON encoding).
    private static func decodeParams<P: Decodable>(_ type: P.Type, from data: Data) throws -> P {
        let trimmed = data.filter { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
        if trimmed.isEmpty || trimmed == Data("null".utf8) {
            return try EngineJSON.decode(type, from: Data("{}".utf8))
        }
        return try EngineJSON.decode(type, from: data)
    }

    /// Encodes the envelope once with `EngineJSON` and yields the same bytes to every
    /// subscriber, in emission order. A handler emits after the write it describes succeeded.
    func emit<E: EngineEvent>(_ event: E.Type, _ payload: E.Payload, origin: Actor) {
        let data: Data
        do {
            data = try EngineJSON.encode(OutgoingEnvelope(name: E.name, origin: origin, data: payload))
        } catch {
            log.error(.engine, "event \(E.name) cannot be encoded: \(error)")
            return
        }
        for continuation in subscribers.values {
            continuation.yield(data)
        }
    }

    /// The envelope of `emit`, encoded straight from the typed payload; with sorted keys its
    /// bytes equal the encoding of the `EngineEventEnvelope`.
    private struct OutgoingEnvelope<Payload: Encodable>: Encodable {
        var name: String
        var origin: Actor
        var data: Payload
    }

    // MARK: Registration

    /// docs/engine-api.md › Dispatcher: one registration function per area.
    private func registerAllHandlers() {
        registerDeviceHandlers()
        registerProjectHandlers()
        registerTicketHandlers()
        registerAttachmentHandlers()
        registerBundleHandlers()
        registerChatHandlers()
        registerClaudeHandlers()
        registerFileHandlers()
        registerDocHandlers()
        registerFSHandlers()
        registerWebTabHandlers()
        registerSearchHandlers()
        registerSkillHandlers()
        registerSettingsHandlers()
        registerUIHandlers()
    }

    // MARK: Device

    /// The DeviceInfo of this engine (docs/engine-api.md › DeviceInfo).
    var deviceInfo: DeviceInfo {
        DeviceInfo(id: deviceID, name: device.displayName(computerName: computerName),
                   appVersion: configuration.appVersion, build: configuration.build)
    }

    /// The Mac's computer name (System Settings > General > About).
    // DOC-GAP: docs/data-model.md › Device file uses the computer name when device.yml has no
    // name, but says nothing of a Mac whose computer name cannot be read; `Mac` is used then.
    private static func readComputerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return "Mac"
    }
}
