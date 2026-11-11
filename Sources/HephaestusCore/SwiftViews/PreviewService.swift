import Darwin
import Foundation

/// The engine's state for the `views.*` and `previews.*` methods (docs/engine-api.md › Views and
/// previews): the scans of the Swift files kept, the packages and Xcode projects with their builds
/// and preview hosts, and the preview sessions. Engine state, used only on the engine actor.
final class PreviewService {
    /// The scan of a file, kept until its size or its modification date changes.
    struct CachedScan: Sendable {
        var size: Int
        var modified: Date
        var scan: SwiftFileScan
    }

    /// A package or an Xcode project with previews.
    final class Unit {
        let unit: PreviewBuildUnit
        let buildFolder: URL
        /// The running build.
        var build: Task<Void, Never>?
        /// A file of the folder changed since the last build, or no build ran yet.
        var outOfDate = true
        /// The target of each file, by absolute path, as the last build found it.
        var fileTargets: [String: String] = [:]
        var targets: [String: Target] = [:]
        /// The targets whose copy the build folder of a package holds, by name.
        var mirrored: [String: PackageTarget] = [:]
        /// The tool that runs, set from the build's own tasks.
        let process = ProcessBox()

        init(unit: PreviewBuildUnit, buildFolder: URL) {
            self.unit = unit
            self.buildFolder = buildFolder
        }
    }

    /// A target previewed, with the result of its last build and its preview host.
    final class Target {
        let name: String
        var executable: URL?
        var builtAt: Date?
        /// The messages of its last build when it failed.
        var failure: [String]?
        var host: PreviewHost?
        /// Changes at each start of a host, so that the end of a replaced host changes nothing.
        var hostID = UUID()
        var idleStop: Task<Void, Never>?

        init(name: String) {
            self.name = name
        }
    }

    /// The image of one preview of a session.
    struct Frame {
        var sequence: Int
        var png: String
        var width: Int
        var height: Int
    }

    /// A preview session.
    final class Session {
        let id: UUID
        let projectRoot: String
        /// The absolute path of the view's file, and its project path.
        let file: String
        let path: String
        let name: String
        /// The title and the registry key of each preview.
        let previews: [(title: String, key: String)]
        /// The folder of its package or Xcode project; nil when it has none.
        let unitKey: String?
        var targetName: String?
        var settings: PreviewSettings
        var state: PreviewState = .building
        var progress: String?
        var builtAt: Date?
        var messages: [String] = []
        var frames: [Int: Frame] = [:]
        var sequence = 1
        var lastPoll = Date()
        var polls = 0
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        init(id: UUID, projectRoot: String, file: String, path: String, name: String, previews: [(title: String, key: String)],
             unitKey: String?, settings: PreviewSettings) {
            self.id = id
            self.projectRoot = projectRoot
            self.file = file
            self.path = path
            self.name = name
            self.previews = previews
            self.unitKey = unitKey
            self.settings = settings
        }

        func windowKey(_ index: Int) -> String {
            "\(id.uuidString)/\(index)"
        }
    }

    var scans: [String: CachedScan] = [:]
    var units: [String: Unit] = [:]
    var sessions: [UUID: Session] = [:]
    var sweeper: Task<Void, Never>?

    /// A session that no poll followed for this long stops.
    static let sessionLifetime: TimeInterval = 60
    /// A host without session stops after this time.
    static let hostIdleTime: Duration = .seconds(60)
    /// The longest wait of `previews.poll`.
    static let pollWait: Duration = .seconds(20)

    func sessions(ofUnit key: String) -> [Session] {
        sessions.values.filter { $0.unitKey == key }
    }

    func sessions(ofUnit key: String, target: String) -> [Session] {
        sessions.values.filter { $0.unitKey == key && $0.targetName == target }
    }
}

/// The process of a running tool, shared with the tasks of a build.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ChildProcess?

    var process: ChildProcess? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// The result of the build of a package or an Xcode project.
struct PreviewUnitBuild: Sendable {
    enum Outcome: Sendable {
        case success(executable: URL)
        case failure([String])
    }

    /// The target of each file asked for, by absolute path.
    var fileTargets: [String: String] = [:]
    /// Why a file has no target to preview.
    enum FileFailure: Sendable {
        case noTarget
        case notPreviewable(target: String, productType: String)
        case messages([String])
    }

    /// The failure of each file without target.
    var fileFailures: [String: FileFailure] = [:]
    var targets: [String: Outcome] = [:]
}

extension Engine {
    /// docs/engine-api.md › Views and previews.
    func registerViewHandlers() {
        register(ViewsList.self, actors: [.user]) { [unowned self] params, _ in
            try await self.viewsList(params)
        }
        register(PreviewsStart.self, actors: [.user]) { [unowned self] params, _ in
            try await self.previewsStart(params)
        }
        register(PreviewsUpdate.self, actors: [.user]) { [unowned self] params, _ in
            try await self.previewsUpdate(params)
        }
        register(PreviewsPoll.self, actors: [.user]) { [unowned self] params, _ in
            try await self.previewsPoll(params)
        }
        register(PreviewsInput.self, actors: [.user]) { [unowned self] params, _ in
            try await self.previewsInput(params)
        }
        register(PreviewsStop.self, actors: [.user]) { [unowned self] params, _ in
            await self.previewsStop(params)
        }
    }

    // MARK: Methods

    /// `views.list` (docs/engine-api.md › views.list).
    func viewsList(_ params: ViewsList.Params) async throws -> [ProjectView] {
        let id = try fileProjectID(params.projectID)
        let root = try fileProjectRoot(id)
        return await projectViews(rootPath: root.path)
    }

    /// `previews.start` (docs/engine-api.md › previews.start).
    func previewsStart(_ params: PreviewsStart.Params) async throws -> PreviewSession {
        let id = try fileProjectID(params.projectID)
        _ = try fileProjectRoot(id)
        let path = try ProjectPaths.normalize(params.path, param: "path", allowRoot: false)
        let root = try fileProjectRoot(id)
        let absolute = URL(fileURLWithPath: root.absolutePath(path)).standardizedFileURL.path
        guard absolute.hasSuffix(".swift"), FileItem.at(absolute)?.kind == .file else {
            throw EngineError.notFound("File", path)
        }
        let views = await projectViews(rootPath: root.path)
        guard let view = views.first(where: { $0.path == path && $0.name == params.name }) else {
            throw EngineError(.notFound, "View \(params.name) not found in \(path).")
        }
        guard !view.previews.isEmpty else {
            throw EngineError(.invalid, "\(params.name) has no #Preview.")
        }
        try Self.checkPreviewSettings(params.settings)
        let scan = previews.scans[absolute]?.scan ?? ViewFinder.scanFile(at: URL(fileURLWithPath: absolute)) ?? SwiftFileScan()
        let ordinals = ViewFinder.previewOrdinals(of: view, in: scan)
        let items = zip(view.previews, ordinals).enumerated().map { index, pair in
            (title: pair.0.name ?? "Preview \(index + 1)", key: PreviewHostSource.registryKey(path: absolute, block: pair.1))
        }
        let unit = topLevelRoot(of: id).flatMap { PreviewBuildUnit.of(file: URL(fileURLWithPath: absolute), root: $0) }
        let unitKey = unit.map { $0.folder.standardizedFileURL.path }
        let session = PreviewService.Session(id: UUID(), projectRoot: root.path, file: absolute, path: path, name: params.name,
                                             previews: items, unitKey: unitKey, settings: params.settings)
        previews.sessions[session.id] = session
        startPreviewSweeper()
        if let unit, let unitKey {
            let state = previews.units[unitKey] ?? PreviewService.Unit(
                unit: unit, buildFolder: dataDirectory.runtimeFolder.appendingPathComponent("previews").appendingPathComponent(unit.buildFolderName))
            previews.units[unitKey] = state
            attachPreviewSession(session, to: state)
        } else {
            session.state = .buildFailed
            session.messages = ["No Swift package or Xcode project holds \(path)."]
        }
        return PreviewSession(sessionID: session.id)
    }

    /// `previews.update` (docs/engine-api.md › previews.update).
    func previewsUpdate(_ params: PreviewsUpdate.Params) async throws -> Empty {
        let session = try previewSession(params.sessionID)
        try Self.checkPreviewSettings(params.settings)
        session.settings = params.settings
        if let host = previewHost(of: session) {
            for index in session.previews.indices {
                host.send(.update(window: session.windowKey(index), settings: params.settings))
            }
        }
        return Empty()
    }

    /// `previews.poll` (docs/engine-api.md › previews.poll).
    func previewsPoll(_ params: PreviewsPoll.Params) async throws -> PreviewStatus {
        let session = try previewSession(params.sessionID)
        guard params.after >= 0 else {
            throw EngineError.invalid("after", "use 0 or more")
        }
        session.lastPoll = Date()
        if session.sequence <= params.after {
            session.polls += 1
            let waiter = UUID()
            let timer = Task { [weak self] in
                try? await Task.sleep(for: PreviewService.pollWait)
                await self?.resumePreviewWaiter(session.id, waiter)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if previews.sessions[session.id] == nil {
                    continuation.resume()
                } else {
                    session.waiters[waiter] = continuation
                }
            }
            timer.cancel()
            session.polls -= 1
            session.lastPoll = Date()
            guard previews.sessions[session.id] != nil else {
                throw EngineError(.notFound, "Preview session \(session.id.uuidString) not found.")
            }
        }
        return status(of: session, after: params.after)
    }

    /// `previews.input` (docs/engine-api.md › previews.input).
    func previewsInput(_ params: PreviewsInput.Params) async throws -> Empty {
        let session = try previewSession(params.sessionID)
        guard session.previews.indices.contains(params.preview) else {
            throw EngineError.invalid("preview", "use 0 to \(session.previews.count - 1)")
        }
        if session.state == .running || session.state == .building, let host = previewHost(of: session) {
            host.send(.input(window: session.windowKey(params.preview), event: params.event))
        }
        return Empty()
    }

    /// `previews.stop` (docs/engine-api.md › previews.stop).
    func previewsStop(_ params: PreviewsStop.Params) async -> Empty {
        stopPreviewSession(params.sessionID)
        return Empty()
    }

    // MARK: Views

    /// The views of the Swift files under a root, the scans of unchanged files taken from the cache.
    func projectViews(rootPath: String) async -> [ProjectView] {
        let root = URL(fileURLWithPath: rootPath)
        let cache = previews.scans
        let (files, updates, found) = await Task.detached { () -> ([ScannedSwiftFile], [String: PreviewService.CachedScan], Set<String>) in
            var files: [ScannedSwiftFile] = []
            var updates: [String: PreviewService.CachedScan] = [:]
            var found: Set<String> = []
            for file in ViewFinder.swiftFiles(under: root) {
                let key = file.url.path
                found.insert(key)
                if let cached = cache[key], cached.size == file.size, cached.modified == file.modified {
                    files.append(ScannedSwiftFile(path: file.path, url: file.url, scan: cached.scan))
                    continue
                }
                guard let scan = ViewFinder.scanFile(at: file.url) else { continue }
                updates[key] = PreviewService.CachedScan(size: file.size, modified: file.modified, scan: scan)
                files.append(ScannedSwiftFile(path: file.path, url: file.url, scan: scan))
            }
            return (files, updates, found)
        }.value
        let prefix = root.standardizedFileURL.path + "/"
        for key in previews.scans.keys where key.hasPrefix(prefix) && !found.contains(key) {
            previews.scans.removeValue(forKey: key)
        }
        previews.scans.merge(updates) { $1 }
        return ViewFinder.views(in: files)
    }

    /// The root of the top-level project of a project: the package or the Xcode project of a file
    /// is looked for up to it.
    func topLevelRoot(of id: ProjectID) -> URL? {
        var current = id
        while let parent = domain.projects[current]?.parentID, domain.projectRoot(parent) != nil {
            current = parent
        }
        return domain.projectRoot(current)?.standardizedFileURL
    }

    static func checkPreviewSettings(_ settings: PreviewSettings) throws {
        guard PreviewSettings.sizeRange.contains(settings.width) else {
            throw EngineError.invalid("settings.width", "use 50 to 2000 points")
        }
        guard PreviewSettings.sizeRange.contains(settings.height) else {
            throw EngineError.invalid("settings.height", "use 50 to 2000 points")
        }
    }

    // MARK: Sessions

    func previewSession(_ id: UUID) throws -> PreviewService.Session {
        guard let session = previews.sessions[id] else {
            throw EngineError(.notFound, "Preview session \(id.uuidString) not found.")
        }
        return session
    }

    func previewHost(of session: PreviewService.Session) -> PreviewHost? {
        guard let key = session.unitKey, let name = session.targetName else { return nil }
        return previews.units[key]?.targets[name]?.host
    }

    func status(of session: PreviewService.Session, after: Int) -> PreviewStatus {
        let frames = session.previews.enumerated().map { index, preview -> PreviewFrame in
            guard let frame = session.frames[index] else {
                return PreviewFrame(index: index, title: preview.title)
            }
            return PreviewFrame(index: index, title: preview.title, sequence: frame.sequence,
                                pngBase64: frame.sequence > after ? frame.png : nil, width: frame.width, height: frame.height)
        }
        return PreviewStatus(sequence: session.sequence, state: session.state, progress: session.state == .building ? session.progress : nil,
                             builtAt: session.builtAt, messages: session.messages, previews: frames)
    }

    /// A change of the session: its sequence grows and its polls return.
    func notifyPreviewSession(_ session: PreviewService.Session) {
        session.sequence += 1
        let waiters = session.waiters.values
        session.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumePreviewWaiter(_ sessionID: UUID, _ waiter: UUID) {
        previews.sessions[sessionID]?.waiters.removeValue(forKey: waiter)?.resume()
    }

    /// Ends a session: its windows close, and its target's host stops 60 seconds after its last
    /// session.
    func stopPreviewSession(_ id: UUID) {
        guard let session = previews.sessions.removeValue(forKey: id) else { return }
        let waiters = session.waiters.values
        session.waiters.removeAll()
        waiters.forEach { $0.resume() }
        guard let key = session.unitKey, let name = session.targetName, let target = previews.units[key]?.targets[name] else { return }
        if let host = target.host {
            for index in session.previews.indices {
                host.send(PreviewHost.Command(type: "close", window: session.windowKey(index)))
            }
        }
        if previews.sessions(ofUnit: key, target: name).isEmpty {
            target.idleStop?.cancel()
            target.idleStop = Task { [weak self] in
                try? await Task.sleep(for: PreviewService.hostIdleTime)
                guard !Task.isCancelled else { return }
                await self?.stopIdlePreviewHost(key, name)
            }
        }
    }

    private func stopIdlePreviewHost(_ key: String, _ name: String) {
        guard previews.sessions(ofUnit: key, target: name).isEmpty, let target = previews.units[key]?.targets[name] else { return }
        target.host?.stop()
        target.host = nil
        target.idleStop = nil
    }

    /// Stops the sessions that no poll followed for 60 seconds, every 10 seconds while sessions
    /// exist.
    func startPreviewSweeper() {
        guard previews.sweeper == nil else { return }
        previews.sweeper = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard let self, await self.sweepPreviewSessions() else { return }
            }
        }
    }

    /// False once no session remains.
    private func sweepPreviewSessions() -> Bool {
        let now = Date()
        for session in previews.sessions.values
            where session.polls == 0 && now.timeIntervalSince(session.lastPoll) > PreviewService.sessionLifetime {
            stopPreviewSession(session.id)
        }
        if previews.sessions.isEmpty || hasStopped {
            previews.sweeper = nil
            return false
        }
        return true
    }

    /// Gives a new session what its target has, or starts a build.
    func attachPreviewSession(_ session: PreviewService.Session, to unit: PreviewService.Unit) {
        guard !unit.outOfDate, unit.build == nil, let name = unit.fileTargets[session.file], let target = unit.targets[name] else {
            requestPreviewBuild(unit)
            return
        }
        session.targetName = name
        target.idleStop?.cancel()
        target.idleStop = nil
        if let failure = target.failure {
            session.state = .buildFailed
            session.messages = Self.previewMessages(failure, projectRoot: session.projectRoot)
        } else if let host = target.host {
            session.state = .running
            session.builtAt = target.builtAt
            openPreviewWindows(session, host: host)
        } else if target.executable != nil {
            startPreviewHost(unit, target)
        } else {
            requestPreviewBuild(unit)
        }
    }

    func openPreviewWindows(_ session: PreviewService.Session, host: PreviewHost) {
        for (index, preview) in session.previews.enumerated() {
            host.send(.open(window: session.windowKey(index), preview: preview.key, settings: session.settings))
        }
    }

    // MARK: Builds

    /// A file of the folder of a package or an Xcode project changed (docs/views.md › Refresh):
    /// the previews that use it build again; the others build when a session needs them.
    func previewFilesChanged(rootPath: String, paths: Set<String>) {
        guard !previews.units.isEmpty else { return }
        let absolute = paths.map { $0.isEmpty ? rootPath : rootPath + "/" + $0 }
        for (key, unit) in previews.units {
            let changed = absolute.contains { path in
                if path == key || key.hasPrefix(path + "/") { return true }
                guard path.hasPrefix(key + "/") else { return false }
                let components = path.dropFirst(key.count + 1).split(separator: "/").map(String.init)
                return !components.contains(where: ViewFinder.skippedFolderNames.contains)
            }
            guard changed else { continue }
            if previews.sessions(ofUnit: key).isEmpty {
                unit.outOfDate = true
            } else {
                requestPreviewBuild(unit)
            }
        }
    }

    func requestPreviewBuild(_ unit: PreviewService.Unit) {
        unit.outOfDate = true
        guard unit.build == nil, !hasStopped else { return }
        let key = unit.unit.folder.standardizedFileURL.path
        unit.build = Task { [weak self] in
            await self?.runPreviewBuilds(key)
        }
    }

    /// Builds the unit until no change came during its last build.
    private func runPreviewBuilds(_ key: String) async {
        while let unit = previews.units[key], unit.outOfDate, !hasStopped {
            let sessions = previews.sessions(ofUnit: key)
            if sessions.isEmpty { break }
            unit.outOfDate = false
            for session in sessions {
                session.state = .building
                session.progress = nil
                notifyPreviewSession(session)
            }
            let environment = await childProcessEnvironment()
            let files = Set(sessions.map(\.file))
            let result = await buildPreviewUnit(unit, files: files, environment: environment)
            if hasStopped { break }
            applyPreviewBuild(result, to: unit, key: key, environment: environment)
        }
        previews.units[key]?.build = nil
    }

    private func applyPreviewBuild(_ result: PreviewUnitBuild, to unit: PreviewService.Unit, key: String, environment: [String: String]) {
        unit.fileTargets.merge(result.fileTargets) { $1 }
        let builtAt = Date()
        for (name, outcome) in result.targets {
            let target = unit.targets[name] ?? PreviewService.Target(name: name)
            unit.targets[name] = target
            target.host?.stop()
            target.host = nil
            switch outcome {
            case .success(let executable):
                target.executable = executable
                target.builtAt = builtAt
                target.failure = nil
            case .failure(let messages):
                target.executable = nil
                target.failure = messages
            }
        }
        for session in previews.sessions(ofUnit: key) {
            if let failure = result.fileFailures[session.file] {
                session.targetName = nil
                session.state = .buildFailed
                switch failure {
                case .noTarget:
                    session.messages = ["No target of \(unit.unit.displayName) builds \(session.path)."]
                case .notPreviewable(let target, let productType):
                    session.messages = ["Previews need an application or framework target: \(target) is \(productType)."]
                case .messages(let messages):
                    session.messages = Self.previewMessages(messages, projectRoot: session.projectRoot)
                }
                notifyPreviewSession(session)
                continue
            }
            session.targetName = unit.fileTargets[session.file]
            guard let name = session.targetName, let target = unit.targets[name] else { continue }
            if let failure = target.failure {
                session.state = .buildFailed
                session.messages = Self.previewMessages(failure, projectRoot: session.projectRoot)
                notifyPreviewSession(session)
            }
        }
        for (name, outcome) in result.targets {
            guard case .success = outcome, let target = unit.targets[name] else { continue }
            if !previews.sessions(ofUnit: key, target: name).isEmpty {
                startPreviewHost(unit, target, environment: environment)
            }
        }
    }

    /// Starts the host of a target that built, and opens the windows of its sessions.
    func startPreviewHost(_ unit: PreviewService.Unit, _ target: PreviewService.Target, environment: [String: String]? = nil) {
        guard let executable = target.executable else { return }
        let key = unit.unit.folder.standardizedFileURL.path
        let name = target.name
        let hostID = UUID()
        target.hostID = hostID
        let environment = environment ?? ProcessEnvironment.withoutHephaestusVariables(claudeCLI.loginEnvironment ?? ProcessInfo.processInfo.environment)
        let (stream, continuation) = AsyncStream<PreviewHost.Message>.makeStream()
        do {
            let host = try PreviewHost(executable: executable, directory: executable.deletingLastPathComponent(), environment: environment,
                                       onMessage: { continuation.yield($0) },
                                       onExit: { termination, tail in
                                           continuation.finish()
                                           Task { [weak self] in await self?.previewHostExited(key, name, hostID, termination, tail) }
                                       })
            target.host = host
        } catch {
            target.host = nil
            for session in previews.sessions(ofUnit: key, target: name) {
                session.state = .stopped
                session.messages = ["The previews stopped: \(error)."]
                notifyPreviewSession(session)
            }
            return
        }
        Task { [weak self] in
            for await message in stream {
                await self?.previewHostMessage(key, name, hostID, message)
            }
        }
        for session in previews.sessions(ofUnit: key, target: name) {
            session.state = .running
            session.builtAt = target.builtAt
            session.messages = []
            notifyPreviewSession(session)
            if let host = target.host { openPreviewWindows(session, host: host) }
        }
    }

    private func previewHostMessage(_ key: String, _ name: String, _ hostID: UUID, _ message: PreviewHost.Message) {
        guard previews.units[key]?.targets[name]?.hostID == hostID, message.type == "frame", let window = message.window,
              let png = message.png else { return }
        let parts = window.split(separator: "/")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let index = Int(parts[1]),
              let session = previews.sessions[id] else { return }
        session.frames[index] = PreviewService.Frame(sequence: session.sequence + 1, png: png, width: message.width ?? 0,
                                                     height: message.height ?? 0)
        notifyPreviewSession(session)
    }

    private func previewHostExited(_ key: String, _ name: String, _ hostID: UUID, _ termination: ProcessTermination, _ tail: [String]) {
        guard let target = previews.units[key]?.targets[name], target.hostID == hostID else { return }
        target.host = nil
        for session in previews.sessions(ofUnit: key, target: name) {
            session.state = .stopped
            session.messages = ["The previews stopped: \(PreviewHost.reason(termination))."] + tail
            notifyPreviewSession(session)
        }
    }

    /// The progress of a build, for the sessions of its unit.
    func previewBuildProgress(_ key: String, _ progress: String) {
        for session in previews.sessions(ofUnit: key) where session.state == .building && session.progress != progress {
            session.progress = progress
            notifyPreviewSession(session)
        }
    }

    /// Builds the targets of the files asked for.
    private func buildPreviewUnit(_ unit: PreviewService.Unit, files: Set<String>, environment: [String: String]) async -> PreviewUnitBuild {
        let key = unit.unit.folder.standardizedFileURL.path
        let makeOutput = { () -> PreviewBuildOutput in
            PreviewBuildOutput { [weak self] progress in
                Task { await self?.previewBuildProgress(key, progress) }
            }
        }
        let box = unit.process
        let track: (ChildProcess?) -> Void = { process in box.process = process }
        var result = PreviewUnitBuild()
        let folder = unit.unit.folder
        let folderPath = folder.standardizedFileURL.path
        func failAll(_ messages: [String]) {
            for file in files { result.fileFailures[file] = .messages(messages) }
        }
        func relative(_ file: String) -> String {
            file.hasPrefix(folderPath + "/") ? String(file.dropFirst(folderPath.count + 1)) : file
        }
        switch unit.unit.kind {
        case .package:
            do {
                try SwiftPackagePreviewBuild.prepareFolder(package: folder, buildFolder: unit.buildFolder,
                                                           hostTargets: unit.mirrored.values.sorted { $0.name < $1.name })
            } catch {
                failAll(["The build folder cannot be written: \(error.localizedDescription)"])
                return result
            }
            let describeOutput = makeOutput()
            guard let targets = await SwiftPackagePreviewBuild.describe(buildFolder: unit.buildFolder, environment: environment,
                                                                        output: describeOutput, track: track) else {
                failAll(describeOutput.lastLines.isEmpty ? ["swift package describe failed."] : describeOutput.lastLines)
                return result
            }
            var wanted: [String: PackageTarget] = [:]
            for file in files {
                guard let target = PackageTarget.target(of: relative(file), in: targets) else {
                    result.fileFailures[file] = .noTarget
                    continue
                }
                result.fileTargets[file] = target.name
                wanted[target.name] = target
            }
            var maps: [String: [String: PreviewSourceMap]] = [:]
            for target in wanted.values.sorted(by: { $0.name < $1.name }) {
                do {
                    maps[target.name] = try SwiftPackagePreviewBuild.mirror(target: target, package: folder, buildFolder: unit.buildFolder)
                    unit.mirrored[target.name] = target
                } catch {
                    result.targets[target.name] = .failure(["The build folder cannot be written: \(error.localizedDescription)"])
                    wanted[target.name] = nil
                }
            }
            do {
                try SwiftPackagePreviewBuild.prepareFolder(package: folder, buildFolder: unit.buildFolder,
                                                           hostTargets: unit.mirrored.values.sorted { $0.name < $1.name })
            } catch {
                failAll(["The build folder cannot be written: \(error.localizedDescription)"])
                return result
            }
            for target in wanted.values.sorted(by: { $0.name < $1.name }) {
                let output = makeOutput()
                output.sourceMaps = maps[target.name] ?? [:]
                if let executable = await SwiftPackagePreviewBuild.build(target: target, buildFolder: unit.buildFolder,
                                                                         environment: environment, output: output, track: track) {
                    result.targets[target.name] = .success(executable: executable)
                } else {
                    result.targets[target.name] = .failure(output.failureMessages)
                }
            }
        case .xcodeProject(let projectURL):
            guard let project = XcodeProject.read(projectURL) else {
                failAll(["The project \(unit.unit.displayName) cannot be read."])
                return result
            }
            var wanted: [String: XcodeProject.Target] = [:]
            for file in files {
                guard let target = project.target(of: file) else {
                    result.fileFailures[file] = .noTarget
                    continue
                }
                guard XcodeProject.previewableProductTypes.contains(target.productType) else {
                    result.fileFailures[file] = .notPreviewable(target: target.name, productType: target.productType)
                    continue
                }
                result.fileTargets[file] = target.name
                wanted[target.name] = target
            }
            for target in wanted.values.sorted(by: { $0.name < $1.name }) {
                let output = makeOutput()
                guard let scheme = await XcodePreviewBuild.scheme(for: target.name, project: projectURL, folder: folder,
                                                                  environment: environment, output: output, track: track) else {
                    result.targets[target.name] = .failure(output.lastLines.isEmpty ? ["No scheme of \(unit.unit.displayName) builds \(target.name)."] : output.lastLines)
                    continue
                }
                guard await XcodePreviewBuild.build(project: projectURL, scheme: scheme, folder: folder, buildFolder: unit.buildFolder,
                                                    environment: environment, output: output, track: track) else {
                    result.targets[target.name] = .failure(output.failureMessages)
                    continue
                }
                let settingsOutput = makeOutput()
                guard let settings = await XcodePreviewBuild.settings(target: target.name, project: projectURL, scheme: scheme, folder: folder,
                                                                      buildFolder: unit.buildFolder, environment: environment,
                                                                      output: settingsOutput, track: track) else {
                    result.targets[target.name] = .failure(settingsOutput.lastLines)
                    continue
                }
                let hostOutput = makeOutput()
                if let executable = await XcodePreviewBuild.compileHost(target: target, settings: settings, buildFolder: unit.buildFolder,
                                                                        environment: environment, output: hostOutput, track: track) {
                    result.targets[target.name] = .success(executable: executable)
                } else {
                    result.targets[target.name] = .failure(hostOutput.failureMessages)
                }
            }
        }
        return result
    }

    /// The messages of a build for a session: the paths of its project made project paths.
    static func previewMessages(_ messages: [String], projectRoot: String) -> [String] {
        let prefix = projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/"
        return messages.map { line in
            for candidate in [prefix, "/private" + prefix] where line.hasPrefix(candidate) {
                return String(line.dropFirst(candidate.count))
            }
            return line
        }
    }

    /// At shutdown: the builds and the hosts end.
    func stopPreviews() async {
        previews.sweeper?.cancel()
        var processes: [ChildProcess] = []
        for unit in previews.units.values {
            unit.build?.cancel()
            if let process = unit.process.process {
                process.signalGroup(SIGTERM)
                processes.append(process)
            }
            for target in unit.targets.values {
                target.idleStop?.cancel()
                if let host = target.host {
                    host.process.signalGroup(SIGTERM)
                    processes.append(host.process)
                    target.host = nil
                }
            }
        }
        for session in previews.sessions.values {
            let waiters = session.waiters.values
            session.waiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        for process in processes {
            while !process.hasExited, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !process.hasExited { process.signalGroup(SIGKILL) }
        }
    }
}
