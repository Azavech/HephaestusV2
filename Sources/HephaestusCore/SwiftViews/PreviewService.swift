import Darwin
import Foundation

/// The engine's state for the `views.*` and `previews.*` methods (docs/engine-api.md › Views and
/// previews): the scans of the Swift files kept, the packages and Xcode projects with their builds
/// and preview hosts per target and platform, the preview sessions and the simulator devices of
/// the iOS hosts. Engine state, used only on the engine actor.
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
        /// Grows at each change of a file of the folder: a build of an earlier generation is out
        /// of date.
        var generation = 1
        /// The generation of the last read of its targets; 0 before the first.
        var readGeneration = 0
        /// The start of the last build.
        var buildStartedAt: Date?
        /// The target of each file, by absolute path, as the last read found it.
        var fileTargets: [String: String] = [:]
        /// Why a file has no target to preview, as the last read found it.
        var fileFailures: [String: PreviewUnitBuild.FileFailure] = [:]
        var targets: [String: Target] = [:]
        /// The targets whose copy the build folder of a package holds, by name.
        var mirrored: [String: PackageTarget] = [:]
        /// What the reading of the elements knows of the project, from the last build or selection.
        var elementContext = ViewElementContext()
        /// The tool that runs, set from the build's own tasks.
        let process = ProcessBox()

        init(unit: PreviewBuildUnit, buildFolder: URL) {
            self.unit = unit
            self.buildFolder = buildFolder
        }
    }

    /// A target previewed: its platforms and, for each, its last build and its preview host.
    final class Target {
        let name: String
        /// The platforms it builds for (docs/views.md › Platforms of a target).
        var platforms: Set<PreviewPlatform> = [.macOS]
        var builds: [PreviewPlatform: PlatformBuild] = [:]

        init(name: String) {
            self.name = name
        }

        func build(for platform: PreviewPlatform) -> PlatformBuild {
            if let build = builds[platform] { return build }
            let build = PlatformBuild()
            builds[platform] = build
            return build
        }
    }

    /// The build of a target for one platform, and its preview host.
    final class PlatformBuild {
        /// The host's executable on macOS, its app on iOS.
        var product: URL?
        /// The identifier of the iOS app.
        var bundleID: String?
        var builtAt: Date?
        /// The messages of its last build when it failed.
        var failure: [String]?
        /// The unit's generation it was built from; 0 before its first build.
        var generation = 0
        var host: (any PreviewHostConnection)?
        /// Changes at each start of a host, so that the end of a replaced host changes nothing.
        var hostID = UUID()
        var idleStop: Task<Void, Never>?
        /// Why its host stopped by itself.
        var stopMessages: [String]?
    }

    /// A preview of a session: its rank and its device, nil for the Mac.
    struct FrameKey: Hashable {
        var index: Int
        var device: String?
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
        var frames: [FrameKey: Frame] = [:]
        /// The element selected with `previews.select`: its number and type in the file, and the
        /// id of its marks (docs/views.md › Select mode).
        var selection: (index: Int, type: String, mark: String)?
        /// The places of the selected element in each preview.
        var outlines: [FrameKey: [PreviewRect]] = [:]
        /// The selected element read from the file, kept until the file or the selection changes.
        var elementCache: (modified: Date, size: Int, index: Int, element: ViewElement?)?
        var sequence = 1
        /// The sequence when the session's windows last opened in a preview host: the images of
        /// the hosts that run have a greater sequence.
        var runningSince = 0
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

        /// The platforms it asks for: macOS, and iOS while a device is checked.
        var wantedPlatforms: Set<PreviewPlatform> {
            settings.devices.isEmpty ? [.macOS] : [.macOS, .iOS]
        }

        /// The key of the host window of a preview: `<session>/<index>` on the Mac,
        /// `<session>/<index>/<device>` on a device.
        func windowKey(_ index: Int, device: String? = nil) -> String {
            device.map { "\(id.uuidString)/\(index)/\($0)" } ?? "\(id.uuidString)/\(index)"
        }
    }

    var scans: [String: CachedScan] = [:]
    var units: [String: Unit] = [:]
    var sessions: [UUID: Session] = [:]
    var sweeper: Task<Void, Never>?
    /// The simulator device of each iOS host, by `<unit key>/<target>`.
    var simulatorLeases: [String: String] = [:]

    /// The `select` requests waiting for their host's answer, by number.
    var selectRequests: [Int: CheckedContinuation<[String]?, Never>] = [:]
    var nextRequest = 1

    /// The longest wait for the answer of a host to `select`.
    static let selectWait: Duration = .seconds(2)

    /// A session that no poll followed for this long stops.
    static let sessionLifetime: TimeInterval = 60
    /// A host without session stops after this time.
    static let hostIdleTime: Duration = .seconds(60)
    /// The longest wait of `previews.poll`.
    static let pollWait: Duration = .seconds(20)
    /// The longest wait of `previews.capture` for its previews.
    static let captureLimit: Duration = .seconds(15 * 60)
    /// `previews.capture` returns once no image changed for this long...
    static let captureQuiet: Duration = .seconds(1)
    /// ...or this long after every preview had its image.
    static let captureSettle: Duration = .seconds(5)

    func sessions(ofUnit key: String) -> [Session] {
        sessions.values.filter { $0.unitKey == key }
    }

    func sessions(ofUnit key: String, target: String) -> [Session] {
        sessions.values.filter { $0.unitKey == key && $0.targetName == target }
    }

    /// The platforms a session shows: those of its target that it asks for; nil while its
    /// target is not known (docs/views.md › Device rows).
    func shownPlatforms(_ session: Session) -> Set<PreviewPlatform>? {
        guard let key = session.unitKey, let unit = units[key], let name = session.targetName, let target = unit.targets[name] else {
            return nil
        }
        return target.platforms.intersection(session.wantedPlatforms)
    }

    /// The sessions of a target that show a platform.
    func sessions(ofUnit key: String, target: String, showing platform: PreviewPlatform) -> [Session] {
        sessions(ofUnit: key, target: target).filter { shownPlatforms($0)?.contains(platform) == true }
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
        /// The host's executable, or its iOS app with its identifier.
        case success(product: URL, bundleID: String?)
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
    /// The platforms of each target read.
    var targetPlatforms: [String: Set<PreviewPlatform>] = [:]
    var outcomes: [String: [PreviewPlatform: Outcome]] = [:]
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
        register(PreviewsSelect.self, actors: [.user]) { [unowned self] params, _ in
            try await self.previewsSelect(params)
        }
        register(PreviewsEdit.self, actors: [.user]) { [unowned self] params, _ in
            try await self.previewsEdit(params)
        }
        register(PreviewsStop.self, actors: [.user]) { [unowned self] params, _ in
            await self.previewsStop(params)
        }
        register(PreviewsCapture.self, actors: [.claude]) { [unowned self] params, _ in
            try await self.previewsCapture(params)
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
        let session = try await startPreviewSession(projectID: params.projectID, path: params.path, name: params.name,
                                                    settings: params.settings)
        return PreviewSession(sessionID: session.id)
    }

    /// The checks and the start of `previews.start`, also used by `previews.capture`, which first
    /// marks the view's package or Xcode project out of date when one of its Swift files changed
    /// since the start of its last build (`checksModified`).
    func startPreviewSession(projectID: ProjectID, path rawPath: String, name: String, settings: PreviewSettings,
                             checksModified: Bool = false) async throws -> PreviewService.Session {
        let id = try fileProjectID(projectID)
        _ = try fileProjectRoot(id)
        let path = try ProjectPaths.normalize(rawPath, param: "path", allowRoot: false)
        let root = try fileProjectRoot(id)
        let absolute = URL(fileURLWithPath: root.absolutePath(path)).standardizedFileURL.path
        guard absolute.hasSuffix(".swift"), FileItem.at(absolute)?.kind == .file else {
            throw EngineError.notFound("File", path)
        }
        let views = await projectViews(rootPath: root.path)
        guard let view = views.first(where: { $0.path == path && $0.name == name }) else {
            throw EngineError(.notFound, "View \(name) not found in \(path).")
        }
        guard !view.previews.isEmpty else {
            throw EngineError(.invalid, "\(name) has no #Preview.")
        }
        try Self.checkPreviewSettings(settings)
        let scan = previews.scans[absolute]?.scan ?? ViewFinder.scanFile(at: URL(fileURLWithPath: absolute)) ?? SwiftFileScan()
        let ordinals = ViewFinder.previewOrdinals(of: view, in: scan)
        let items = zip(view.previews, ordinals).enumerated().map { index, pair in
            (title: pair.0.name ?? "Preview \(index + 1)", key: PreviewHostSource.registryKey(path: absolute, block: pair.1))
        }
        let unit = topLevelRoot(of: id).flatMap { PreviewBuildUnit.of(file: URL(fileURLWithPath: absolute), root: $0) }
        let unitKey = unit.map { $0.folder.standardizedFileURL.path }
        if checksModified, let unitKey, let state = previews.units[unitKey], let startedAt = state.buildStartedAt {
            let folder = URL(fileURLWithPath: unitKey)
            let changed = await Task.detached {
                ViewFinder.swiftFiles(under: folder).contains { $0.modified > startedAt }
            }.value
            if changed { state.generation += 1 }
        }
        let session = PreviewService.Session(id: UUID(), projectRoot: root.path, file: absolute, path: path, name: name,
                                             previews: items, unitKey: unitKey, settings: settings)
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
        return session
    }

    /// `previews.capture` (docs/engine-api.md › previews.capture): a session that no window
    /// shows, followed until its previews of the last build are drawn, its build failed or its
    /// host stopped; the images are written to `Runtime/screenshots/`.
    func previewsCapture(_ params: PreviewsCapture.Params) async throws -> PreviewCapture {
        let session = try await startPreviewSession(projectID: params.projectID, path: params.path, name: params.name,
                                                    settings: params.settings, checksModified: true)
        // A session followed by a capture is never swept.
        session.polls += 1
        defer {
            session.polls -= 1
            stopPreviewSession(session.id)
        }
        let deadline = ContinuousClock.now + PreviewService.captureLimit
        var complete: ContinuousClock.Instant?
        var changed = ContinuousClock.now
        var shown: [PreviewService.FrameKey: Int] = [:]
        while previews.sessions[session.id] != nil {
            let unit = session.unitKey.flatMap { previews.units[$0] }
            let pending = unit.map { $0.build != nil || previewUnitNeedsBuild($0) } ?? false
            let now = ContinuousClock.now
            switch session.state {
            case .buildFailed where !pending, .stopped where !pending:
                return PreviewCapture(state: session.state, builtAt: session.builtAt, messages: session.messages)
            case .running where !pending && session.previews.indices.allSatisfy({
                (session.frames[PreviewService.FrameKey(index: $0, device: nil)]?.sequence ?? 0) > session.runningSince
            }):
                let sequences = session.frames.mapValues(\.sequence)
                if complete == nil {
                    complete = now
                    changed = now
                } else if sequences != shown {
                    changed = now
                }
                shown = sequences
                if let complete, now - changed >= PreviewService.captureQuiet || now - complete >= PreviewService.captureSettle {
                    return try writePreviewImages(session)
                }
            default:
                complete = nil
            }
            guard now < deadline else { break }
            var wait = deadline - now
            if let complete {
                wait = min(wait, max(.milliseconds(10), min(changed + PreviewService.captureQuiet, complete + PreviewService.captureSettle) - now))
            }
            await waitForPreviewChange(session, at: wait)
        }
        throw EngineError(.unavailable, "The previews of \(params.name) did not show within 15 minutes.")
    }

    /// Writes the images of a session's previews to `Runtime/screenshots/`.
    private func writePreviewImages(_ session: PreviewService.Session) throws -> PreviewCapture {
        let folder = dataDirectory.runtimeFolder.appendingPathComponent("screenshots")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let time = formatter.string(from: Date())
        var images: [PreviewImageFile] = []
        for (index, preview) in session.previews.enumerated() {
            guard let frame = session.frames[PreviewService.FrameKey(index: index, device: nil)], let png = Data(base64Encoded: frame.png) else {
                continue
            }
            let file = folder.appendingPathComponent("preview-\(time)-\(index + 1).png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: file, options: .atomic)
            } catch {
                throw EngineError(.internal, "\(file.path) cannot be written: \(Self.withoutFinalPeriod(error.localizedDescription)).")
            }
            images.append(PreviewImageFile(index: index, title: preview.title, path: file.path, width: frame.width, height: frame.height))
        }
        return PreviewCapture(state: .running, builtAt: session.builtAt, previews: images)
    }

    /// Waits for a change of the session, at most `timeout`.
    private func waitForPreviewChange(_ session: PreviewService.Session, at timeout: Duration) async {
        let waiter = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
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
    }

    /// `previews.update` (docs/engine-api.md › previews.update): the Mac windows take the new
    /// settings; the windows of the devices no longer checked close, those of the new devices
    /// open, and the first device of a target without iOS build starts that build.
    func previewsUpdate(_ params: PreviewsUpdate.Params) async throws -> Empty {
        let session = try previewSession(params.sessionID)
        try Self.checkPreviewSettings(params.settings)
        let old = session.settings
        let oldShown = previews.shownPlatforms(session) ?? []
        session.settings = params.settings
        let shown = previews.shownPlatforms(session) ?? []
        let names = Set(params.settings.devices.map(\.name))
        session.frames = session.frames.filter { key, _ in key.device.map(names.contains) ?? true }
        guard let key = session.unitKey, let unit = previews.units[key], let name = session.targetName, let target = unit.targets[name] else {
            notifyPreviewSession(session)
            return Empty()
        }
        if shown.contains(.macOS), let host = target.builds[.macOS]?.host {
            for index in session.previews.indices {
                host.send(.update(window: session.windowKey(index), settings: params.settings))
            }
        }
        let oldDevices = oldShown.contains(.iOS) ? old.devices : []
        let newDevices = shown.contains(.iOS) ? params.settings.devices : []
        if let host = target.builds[.iOS]?.host {
            let kept = Set(newDevices.map(\.name))
            let before = Set(oldDevices.map(\.name))
            for device in oldDevices where !kept.contains(device.name) {
                for index in session.previews.indices {
                    host.send(PreviewHost.Command(type: "close", window: session.windowKey(index, device: device.name)))
                }
            }
            for device in newDevices {
                for (index, preview) in session.previews.enumerated() {
                    let window = session.windowKey(index, device: device.name)
                    host.send(before.contains(device.name)
                              ? .update(window: window, settings: params.settings, device: device)
                              : .open(window: window, preview: preview.key, settings: params.settings, device: device))
                }
            }
        }
        if shown.contains(.iOS) {
            let build = target.build(for: .iOS)
            build.idleStop?.cancel()
            build.idleStop = nil
            if previewUnitNeedsBuild(unit) {
                requestPreviewBuild(unit)
            } else {
                startPreviewHosts(unit)
            }
        } else if oldShown.contains(.iOS) {
            schedulePreviewHostIdleStop(key, name, .iOS)
        }
        notifyPreviewSession(session)
        refreshPreviewSession(session)
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
        if let device = params.device, !session.settings.devices.contains(where: { $0.name == device }) {
            throw EngineError.invalid("device", "\(device) is not a device of the session")
        }
        let platform: PreviewPlatform = params.device == nil ? .macOS : .iOS
        if session.state == .running || session.state == .building, let host = previewHost(of: session, platform) {
            host.send(.input(window: session.windowKey(params.preview, device: params.device), event: params.event))
        }
        return Empty()
    }

    /// `previews.stop` (docs/engine-api.md › previews.stop).
    func previewsStop(_ params: PreviewsStop.Params) async -> Empty {
        stopPreviewSession(params.sessionID)
        return Empty()
    }

    /// `previews.select` (docs/engine-api.md › previews.select).
    func previewsSelect(_ params: PreviewsSelect.Params) async throws -> PreviewSelection {
        let session = try previewSession(params.sessionID)
        guard let preview = params.preview else {
            clearPreviewSelection(session)
            return PreviewSelection()
        }
        guard session.previews.indices.contains(preview) else {
            throw EngineError.invalid("preview", "use 0 to \(session.previews.count - 1)")
        }
        guard let x = params.x else { throw EngineError.invalid("x", "required with preview") }
        guard let y = params.y else { throw EngineError.invalid("y", "required with preview") }
        guard let host = previewHost(of: session, .macOS) else {
            throw EngineError(.unavailable, "The previews are not running.")
        }
        let request = previews.nextRequest
        previews.nextRequest += 1
        var command = PreviewHost.Command(type: "select", window: session.windowKey(preview))
        command.x = x
        command.y = y
        command.request = request
        host.send(command)
        let ids = await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            previews.selectRequests[request] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: PreviewService.selectWait)
                await self?.answerSelectRequest(request, nil)
            }
        }
        guard previews.sessions[session.id] != nil else {
            throw EngineError(.notFound, "Preview session \(session.id.uuidString) not found.")
        }
        guard let ids else { throw EngineError(.unavailable, "The previews did not answer.") }
        let marks = ids.compactMap { id in ViewElementScanner.parseMarkID(id).map { (id: id, mark: $0) } }
        guard let found = marks.first(where: { Self.samePreviewPath($0.mark.path, session.file) }) else {
            clearPreviewSelection(session)
            return PreviewSelection()
        }
        let context = await refreshViewElementContext(session)
        guard let text = try? String(contentsOfFile: session.file, encoding: .utf8) else {
            throw EngineError(.notFound, "File \(session.path) not found.")
        }
        let file = ViewElementScanner.read(text, context: context)
        guard file.elements.indices.contains(found.mark.index), file.elements[found.mark.index].type == found.mark.type else {
            throw EngineError(.conflict, "The previews are older than \(session.path): select again once they are built.")
        }
        session.selection = (found.mark.index, found.mark.type, found.id)
        session.elementCache = nil
        session.outlines = [:]
        trackPreviewSelection(session)
        notifyPreviewSession(session)
        return PreviewSelection(element: ViewElementEditor.viewElement(file.elements[found.mark.index], in: file, path: session.path))
    }

    /// `previews.edit` (docs/engine-api.md › previews.edit).
    func previewsEdit(_ params: PreviewsEdit.Params) async throws -> ViewElement {
        let session = try previewSession(params.sessionID)
        guard session.selection != nil else { throw EngineError(.invalid, "No element is selected.") }
        let context = await refreshViewElementContext(session)
        guard let selection = session.selection else { throw EngineError(.invalid, "No element is selected.") }
        let text: String
        do {
            text = try String(contentsOfFile: session.file, encoding: .utf8)
        } catch {
            throw EngineError(.internal, "\(session.path) cannot be written: \(error.localizedDescription).")
        }
        let file = ViewElementScanner.read(text, context: context)
        guard file.elements.indices.contains(selection.index), file.elements[selection.index].type == selection.type else {
            clearPreviewSelection(session)
            throw EngineError(.notFound, "The element is no longer in \(session.path): select it again.")
        }
        let edited = try ViewElementEditor.apply(params.edit, to: file.elements[selection.index], in: file)
        if edited != text {
            do {
                try AtomicFile.write(Data(edited.utf8), to: URL(fileURLWithPath: session.file))
            } catch {
                let reason = (error as? StorageError).flatMap { error -> String? in
                    if case .writeFailed(_, let reason) = error { return reason }
                    return nil
                } ?? error.localizedDescription
                throw EngineError(.internal, "\(session.path) cannot be written: \(reason).")
            }
        }
        let written = ViewElementScanner.read(edited, context: context)
        session.elementCache = nil
        notifyPreviewSession(session)
        let element = written.elements.indices.contains(selection.index) ? written.elements[selection.index] : file.elements[selection.index]
        return ViewElementEditor.viewElement(element, in: written.elements.indices.contains(selection.index) ? written : file,
                                             path: session.path)
    }

    // MARK: Selection

    /// Two absolute paths of the same file, `/private` before `/var` or `/tmp` or not.
    static func samePreviewPath(_ a: String, _ b: String) -> Bool {
        func normalized(_ path: String) -> String {
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            return standard.hasPrefix("/private/") ? String(standard.dropFirst("/private".count)) : standard
        }
        return normalized(a) == normalized(b)
    }

    private func answerSelectRequest(_ request: Int, _ ids: [String]?) {
        previews.selectRequests.removeValue(forKey: request)?.resume(returning: ids)
    }

    /// Clears the selection of a session and its outlines.
    func clearPreviewSelection(_ session: PreviewService.Session) {
        guard session.selection != nil || !session.outlines.isEmpty else { return }
        session.selection = nil
        session.elementCache = nil
        session.outlines = [:]
        trackPreviewSelection(session)
        notifyPreviewSession(session)
    }

    /// Tells the Mac host which element to outline in the session's previews.
    func trackPreviewSelection(_ session: PreviewService.Session) {
        guard let host = previewHost(of: session, .macOS) else { return }
        for index in session.previews.indices {
            var command = PreviewHost.Command(type: "track", window: session.windowKey(index))
            command.element = session.selection?.mark
            host.send(command)
        }
    }

    /// What the reading of the elements knows of the session's package or Xcode project, read
    /// again from its files.
    func refreshViewElementContext(_ session: PreviewService.Session) async -> ViewElementContext {
        guard let key = session.unitKey else { return ViewElementContext() }
        let context = await viewElementContext(folder: key)
        previews.units[key]?.elementContext = context
        return context
    }

    /// The context of the Swift files under a folder.
    func viewElementContext(folder: String) async -> ViewElementContext {
        _ = await projectViews(rootPath: folder)
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let files = previews.scans.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map { key, cached in
            ScannedSwiftFile(path: String(key.dropFirst(prefix.count)), url: URL(fileURLWithPath: key), scan: cached.scan)
        }
        return ViewElementContext.of(files)
    }

    /// The selected element as the file has it now; a selection whose element is gone clears.
    func selectedElement(of session: PreviewService.Session) -> ViewElement? {
        guard let selection = session.selection else { return nil }
        guard let item = FileItem.at(session.file) else {
            clearSelectionQuietly(session)
            return nil
        }
        if let cache = session.elementCache, cache.modified == item.modified, cache.size == item.size, cache.index == selection.index {
            return cache.element
        }
        let context = session.unitKey.flatMap { previews.units[$0]?.elementContext } ?? ViewElementContext()
        guard let text = try? String(contentsOfFile: session.file, encoding: .utf8) else { return nil }
        let file = ViewElementScanner.read(text, context: context)
        guard file.elements.indices.contains(selection.index), file.elements[selection.index].type == selection.type else {
            clearSelectionQuietly(session)
            return nil
        }
        let element = ViewElementEditor.viewElement(file.elements[selection.index], in: file, path: session.path)
        session.elementCache = (item.modified, item.size, selection.index, element)
        return element
    }

    /// Clears a selection while a status is made: the status carries the change.
    private func clearSelectionQuietly(_ session: PreviewService.Session) {
        session.selection = nil
        session.elementCache = nil
        session.outlines = [:]
        trackPreviewSelection(session)
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
        var names: Set<String> = []
        for device in settings.devices {
            if let problem = device.problem {
                throw EngineError.invalid("settings.devices", "\(device.name): \(problem)")
            }
            guard names.insert(device.name).inserted else {
                throw EngineError.invalid("settings.devices", "\(device.name) is listed twice")
            }
        }
    }

    // MARK: Sessions

    func previewSession(_ id: UUID) throws -> PreviewService.Session {
        guard let session = previews.sessions[id] else {
            throw EngineError(.notFound, "Preview session \(id.uuidString) not found.")
        }
        return session
    }

    func previewHost(of session: PreviewService.Session, _ platform: PreviewPlatform) -> (any PreviewHostConnection)? {
        guard let key = session.unitKey, let name = session.targetName else { return nil }
        return previews.units[key]?.targets[name]?.builds[platform]?.host
    }

    /// The status of a session: the Mac's previews in the order of their blocks, then each
    /// device's, for the platforms it shows whose last build did not fail.
    func status(of session: PreviewService.Session, after: Int) -> PreviewStatus {
        let element = selectedElement(of: session)
        var shown = previews.shownPlatforms(session) ?? []
        if let key = session.unitKey, let name = session.targetName, let target = previews.units[key]?.targets[name] {
            shown = shown.filter { target.builds[$0]?.failure == nil }
        }
        var keys: [PreviewService.FrameKey] = []
        if shown.contains(.macOS) {
            keys += session.previews.indices.map { PreviewService.FrameKey(index: $0, device: nil) }
        }
        if shown.contains(.iOS) {
            for device in session.settings.devices {
                keys += session.previews.indices.map { PreviewService.FrameKey(index: $0, device: device.name) }
            }
        }
        let frames = keys.map { key -> PreviewFrame in
            let title = session.previews[key.index].title
            let outlines = session.selection == nil ? [] : session.outlines[key] ?? []
            guard let frame = session.frames[key] else {
                return PreviewFrame(index: key.index, title: title, device: key.device, outlines: outlines)
            }
            return PreviewFrame(index: key.index, title: title, device: key.device, sequence: frame.sequence,
                                pngBase64: frame.sequence > after ? frame.png : nil, width: frame.width, height: frame.height,
                                outlines: outlines)
        }
        return PreviewStatus(sequence: session.sequence, state: session.state, progress: session.state == .building ? session.progress : nil,
                             builtAt: session.builtAt, messages: session.messages, previews: frames, element: element)
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

    /// Sets the state of a session from its target's builds and hosts (docs/views.md › Build
    /// rules): `building` while a build of a platform it shows runs, `buildFailed` when one
    /// failed, `stopped` when a host stopped by itself, `running` otherwise.
    func refreshPreviewSession(_ session: PreviewService.Session) {
        guard let key = session.unitKey, let unit = previews.units[key] else { return }
        if unit.build != nil && unit.readGeneration != unit.generation {
            setPreviewSessionState(session, .building, messages: [], builtAt: session.builtAt)
            return
        }
        if let failure = unit.fileFailures[session.file] {
            let messages: [String]
            switch failure {
            case .noTarget:
                messages = ["No target of \(unit.unit.displayName) builds \(session.path)."]
            case .notPreviewable(let target, let productType):
                messages = ["Previews need an application or framework target: \(target) is \(productType)."]
            case .messages(let lines):
                messages = Self.previewMessages(lines, projectRoot: session.projectRoot)
            }
            setPreviewSessionState(session, .buildFailed, messages: messages, builtAt: session.builtAt)
            return
        }
        guard let shown = previews.shownPlatforms(session), let name = session.targetName, let target = unit.targets[name] else {
            setPreviewSessionState(session, .building, messages: [], builtAt: session.builtAt)
            return
        }
        let building = unit.build != nil && shown.contains { (target.builds[$0]?.generation ?? 0) != unit.generation }
        var failed: [(platform: PreviewPlatform, messages: [String])] = []
        var stopped: [String]?
        var builtAt: Date?
        for platform in shown.sorted() {
            guard let build = target.builds[platform] else { continue }
            if let failure = build.failure {
                failed.append((platform, Self.previewMessages(failure, projectRoot: session.projectRoot)))
            } else if let messages = build.stopMessages, stopped == nil {
                stopped = messages
            }
            if let date = build.builtAt { builtAt = max(builtAt ?? date, date) }
        }
        // The errors of a failed platform, after its line, while the other one's previews run.
        let partial = failed.count < shown.count ? failed.flatMap { [$0.platform.heading] + $0.messages } : []
        if building {
            setPreviewSessionState(session, .building, messages: partial, builtAt: builtAt ?? session.builtAt)
        } else if !failed.isEmpty && failed.count == shown.count {
            let messages = failed.count == 1 ? failed[0].messages : failed.flatMap { [$0.platform.heading] + $0.messages }
            setPreviewSessionState(session, .buildFailed, messages: messages, builtAt: builtAt)
        } else if let stopped {
            setPreviewSessionState(session, .stopped, messages: stopped, builtAt: builtAt)
        } else {
            setPreviewSessionState(session, .running, messages: partial, builtAt: builtAt)
        }
    }

    private func setPreviewSessionState(_ session: PreviewService.Session, _ state: PreviewState, messages: [String], builtAt: Date?) {
        guard session.state != state || session.messages != messages || session.builtAt != builtAt else { return }
        if state == .building && session.state != .building { session.progress = nil }
        session.state = state
        session.messages = messages
        session.builtAt = builtAt
        notifyPreviewSession(session)
    }

    /// Ends a session: its windows close, and the hosts of its target stop 60 seconds after their
    /// last session.
    func stopPreviewSession(_ id: UUID) {
        guard let session = previews.sessions[id] else { return }
        let shown = previews.shownPlatforms(session) ?? []
        previews.sessions.removeValue(forKey: id)
        let waiters = session.waiters.values
        session.waiters.removeAll()
        waiters.forEach { $0.resume() }
        guard let key = session.unitKey, let name = session.targetName, let target = previews.units[key]?.targets[name] else { return }
        for platform in shown {
            guard let host = target.builds[platform]?.host else { continue }
            for index in session.previews.indices {
                if platform == .macOS {
                    host.send(PreviewHost.Command(type: "close", window: session.windowKey(index)))
                } else {
                    for device in session.settings.devices {
                        host.send(PreviewHost.Command(type: "close", window: session.windowKey(index, device: device.name)))
                    }
                }
            }
        }
        for platform in PreviewPlatform.allCases {
            schedulePreviewHostIdleStop(key, name, platform)
        }
    }

    /// Stops the host of a target and platform 60 seconds after its last session.
    func schedulePreviewHostIdleStop(_ key: String, _ name: String, _ platform: PreviewPlatform) {
        guard let build = previews.units[key]?.targets[name]?.builds[platform],
              previews.sessions(ofUnit: key, target: name, showing: platform).isEmpty, build.host != nil || platform == .iOS else { return }
        build.idleStop?.cancel()
        build.idleStop = Task { [weak self] in
            try? await Task.sleep(for: PreviewService.hostIdleTime)
            guard !Task.isCancelled else { return }
            await self?.stopIdlePreviewHost(key, name, platform)
        }
    }

    private func stopIdlePreviewHost(_ key: String, _ name: String, _ platform: PreviewPlatform) {
        guard previews.sessions(ofUnit: key, target: name, showing: platform).isEmpty,
              let build = previews.units[key]?.targets[name]?.builds[platform] else { return }
        build.host?.stop()
        build.host = nil
        build.idleStop = nil
        if platform == .iOS {
            releasePreviewSimulator("\(key)/\(name)")
        }
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
        if unit.readGeneration == unit.generation, let name = unit.fileTargets[session.file], unit.targets[name] != nil {
            session.targetName = name
        }
        if previewUnitNeedsBuild(unit) {
            requestPreviewBuild(unit)
        }
        refreshPreviewSession(session)
        guard let name = session.targetName, let target = unit.targets[name], let shown = previews.shownPlatforms(session) else { return }
        for platform in shown {
            let build = target.build(for: platform)
            build.idleStop?.cancel()
            build.idleStop = nil
            if let host = build.host {
                openPreviewWindows(session, platform, host: host)
            }
        }
        startPreviewHosts(unit)
    }

    /// Starts the hosts of the current builds that sessions show and that have none, except a
    /// host that stopped by itself: the next build starts it again (docs/views.md › Preview host).
    func startPreviewHosts(_ unit: PreviewService.Unit) {
        let key = unit.unit.folder.standardizedFileURL.path
        for target in unit.targets.values {
            for platform in PreviewPlatform.allCases {
                guard let build = target.builds[platform], build.host == nil, build.product != nil, build.failure == nil,
                      build.stopMessages == nil, build.generation == unit.generation,
                      !previews.sessions(ofUnit: key, target: target.name, showing: platform).isEmpty else { continue }
                startPreviewHost(unit, target, platform)
            }
        }
    }

    /// Opens the windows of a session's previews in the host of a platform.
    func openPreviewWindows(_ session: PreviewService.Session, _ platform: PreviewPlatform, host: any PreviewHostConnection) {
        session.runningSince = session.sequence
        for (index, preview) in session.previews.enumerated() {
            if platform == .macOS {
                host.send(.open(window: session.windowKey(index), preview: preview.key, settings: session.settings))
                // The element selected is outlined in the Mac previews (docs/views.md › Select mode).
                if let mark = session.selection?.mark {
                    var command = PreviewHost.Command(type: "track", window: session.windowKey(index))
                    command.element = mark
                    host.send(command)
                }
            } else {
                for device in session.settings.devices {
                    host.send(.open(window: session.windowKey(index, device: device.name), preview: preview.key,
                                    settings: session.settings, device: device))
                }
            }
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
            unit.generation += 1
            if !previews.sessions(ofUnit: key).isEmpty {
                requestPreviewBuild(unit)
            }
        }
    }

    /// True when a session of the unit has no current read of its file's target, or shows a
    /// platform whose build is not of the unit's generation.
    func previewUnitNeedsBuild(_ unit: PreviewService.Unit) -> Bool {
        let key = unit.unit.folder.standardizedFileURL.path
        for session in previews.sessions(ofUnit: key) {
            guard unit.readGeneration == unit.generation else { return true }
            if unit.fileFailures[session.file] != nil { continue }
            guard let name = unit.fileTargets[session.file], let target = unit.targets[name] else { return true }
            let shown = target.platforms.intersection(session.wantedPlatforms)
            if shown.contains(where: { (target.builds[$0]?.generation ?? 0) != unit.generation }) { return true }
        }
        return false
    }

    func requestPreviewBuild(_ unit: PreviewService.Unit) {
        guard unit.build == nil, !hasStopped else { return }
        let key = unit.unit.folder.standardizedFileURL.path
        unit.build = Task { [weak self] in
            await self?.runPreviewBuilds(key)
        }
        for session in previews.sessions(ofUnit: key) {
            refreshPreviewSession(session)
        }
    }

    /// Builds the unit until its sessions need no build: a change that came during a build
    /// starts another.
    private func runPreviewBuilds(_ key: String) async {
        while let unit = previews.units[key], !hasStopped {
            let sessions = previews.sessions(ofUnit: key)
            if sessions.isEmpty || !previewUnitNeedsBuild(unit) { break }
            let generation = unit.generation
            unit.buildStartedAt = Date()
            var requests: [String: Set<PreviewPlatform>] = [:]
            for session in sessions {
                requests[session.file, default: []].formUnion(session.wantedPlatforms)
                refreshPreviewSession(session)
            }
            let environment = await childProcessEnvironment()
            let result = await buildPreviewUnit(unit, requests: requests, generation: generation, environment: environment)
            if hasStopped { break }
            applyPreviewBuild(result, to: unit, key: key, generation: generation, environment: environment)
        }
        guard let unit = previews.units[key] else { return }
        unit.build = nil
        startPreviewHosts(unit)
        for session in previews.sessions(ofUnit: key) {
            refreshPreviewSession(session)
        }
    }

    private func applyPreviewBuild(_ result: PreviewUnitBuild, to unit: PreviewService.Unit, key: String, generation: Int,
                                   environment: [String: String]) {
        unit.readGeneration = generation
        for (file, name) in result.fileTargets {
            unit.fileTargets[file] = name
            unit.fileFailures[file] = nil
        }
        for (file, failure) in result.fileFailures {
            unit.fileTargets[file] = nil
            unit.fileFailures[file] = failure
        }
        for (name, platforms) in result.targetPlatforms {
            let target = unit.targets[name] ?? PreviewService.Target(name: name)
            unit.targets[name] = target
            target.platforms = platforms
        }
        let builtAt = Date()
        for (name, outcomes) in result.outcomes {
            let target = unit.targets[name] ?? PreviewService.Target(name: name)
            unit.targets[name] = target
            for (platform, outcome) in outcomes {
                let build = target.build(for: platform)
                build.host?.stop()
                build.host = nil
                build.generation = generation
                build.stopMessages = nil
                switch outcome {
                case .success(let product, let bundleID):
                    build.product = product
                    build.bundleID = bundleID
                    build.builtAt = builtAt
                    build.failure = nil
                case .failure(let messages):
                    build.product = nil
                    build.failure = messages
                }
            }
        }
        var newlyKnown: [PreviewService.Session] = []
        for session in previews.sessions(ofUnit: key) {
            let name = unit.fileTargets[session.file]
            if name != session.targetName, name != nil { newlyKnown.append(session) }
            session.targetName = name
        }
        var started: Set<String> = []
        for (name, outcomes) in result.outcomes {
            guard let target = unit.targets[name] else { continue }
            for (platform, outcome) in outcomes {
                guard case .success = outcome, !previews.sessions(ofUnit: key, target: name, showing: platform).isEmpty else { continue }
                startPreviewHost(unit, target, platform, environment: environment)
                started.insert("\(name)/\(platform.rawValue)")
            }
        }
        // A session whose target this read found shows its previews in the hosts that already run.
        for session in newlyKnown {
            guard let name = session.targetName, let target = unit.targets[name] else { continue }
            for platform in previews.shownPlatforms(session) ?? [] where !started.contains("\(name)/\(platform.rawValue)") {
                guard let build = target.builds[platform], let host = build.host else { continue }
                build.idleStop?.cancel()
                build.idleStop = nil
                openPreviewWindows(session, platform, host: host)
            }
        }
        for session in previews.sessions(ofUnit: key) {
            refreshPreviewSession(session)
        }
    }

    /// Starts the host of a target that built for a platform, and opens the windows of its
    /// sessions: the Mac host as a process, the iOS host as an app in a simulator device.
    func startPreviewHost(_ unit: PreviewService.Unit, _ target: PreviewService.Target, _ platform: PreviewPlatform,
                          environment: [String: String]? = nil) {
        let build = target.build(for: platform)
        guard let product = build.product else { return }
        let key = unit.unit.folder.standardizedFileURL.path
        let name = target.name
        let hostID = UUID()
        build.hostID = hostID
        build.stopMessages = nil
        let environment = environment ?? ProcessEnvironment.withoutHephaestusVariables(claudeCLI.loginEnvironment ?? ProcessInfo.processInfo.environment)
        let (stream, continuation) = AsyncStream<PreviewHost.Message>.makeStream()
        do {
            switch platform {
            case .macOS:
                build.host = try PreviewHost(executable: product, directory: product.deletingLastPathComponent(), environment: environment,
                                             onMessage: { continuation.yield($0) },
                                             onExit: { [weak self] termination, tail in
                                                 continuation.finish()
                                                 Task { [weak self] in
                                                     await self?.previewHostEnded(key, name, platform, hostID,
                                                                                  "The previews stopped: \(PreviewHost.reason(termination)).", tail)
                                                 }
                                             })
            case .iOS:
                let host = try PreviewSimulatorHost(onMessage: { continuation.yield($0) },
                                                    onEnd: { [weak self] reason, tail in
                                                        continuation.finish()
                                                        Task { [weak self] in
                                                            await self?.previewHostEnded(key, name, platform, hostID,
                                                                                         "The previews stopped: \(reason).", tail)
                                                        }
                                                    })
                build.host = host
                launchPreviewSimulatorHost(host, app: product, bundleID: build.bundleID ?? "", leaseKey: "\(key)/\(name)",
                                           environment: environment)
            }
        } catch {
            build.host = nil
            build.stopMessages = ["The previews stopped: \(error)."]
            for session in previews.sessions(ofUnit: key, target: name, showing: platform) {
                refreshPreviewSession(session)
            }
            return
        }
        Task { [weak self] in
            for await message in stream {
                await self?.previewHostMessage(key, name, platform, hostID, message)
            }
        }
        for session in previews.sessions(ofUnit: key, target: name, showing: platform) {
            refreshPreviewSession(session)
            if let host = build.host { openPreviewWindows(session, platform, host: host) }
        }
    }

    /// Leases a simulator device, installs the app in it and launches it with the port and the
    /// token of its connection (docs/views.md › iOS Simulator).
    private func launchPreviewSimulatorHost(_ host: PreviewSimulatorHost, app: URL, bundleID: String, leaseKey: String,
                                            environment: [String: String]) {
        let set = previewSimulatorSet
        Task { [weak self] in
            guard let self else { return }
            do {
                let udid = try await self.leasePreviewSimulator(leaseKey, environment: environment)
                try await PreviewSimulator.install(app, on: udid, set: set, environment: environment)
                // A launch just after a first boot may come to nothing: the app is launched again.
                for _ in 0..<PreviewSimulatorHost.launches {
                    guard !host.isEnded else { return }
                    try await PreviewSimulator.launch(bundleID, on: udid, port: host.port, token: host.token, set: set, environment: environment)
                    let deadline = ContinuousClock.now + PreviewSimulatorHost.connectWait
                    while !host.isConnected, !host.isEnded, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    if host.isConnected || host.isEnded { return }
                }
                host.fail("the app did not start in the iOS Simulator")
            } catch {
                host.fail(String(describing: error).trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            }
        }
    }

    /// `Runtime/simulators/`: the device set of the engine's simulator devices.
    var previewSimulatorSet: URL {
        dataDirectory.runtimeFolder.appendingPathComponent("simulators", isDirectory: true)
    }

    /// The simulator device of an iOS host: the one it already has, else a free device of the set,
    /// else a new one; booted.
    func leasePreviewSimulator(_ leaseKey: String, environment: [String: String]) async throws -> String {
        let set = previewSimulatorSet
        if let udid = previews.simulatorLeases[leaseKey] {
            try await PreviewSimulator.boot(udid, set: set, environment: environment)
            return udid
        }
        guard let runtime = try await PreviewSimulator.runtime(set: set, environment: environment) else {
            throw PreviewSimulator.Failure(message: PreviewSimulator.noRuntimeMessage)
        }
        let devices = try await PreviewSimulator.devices(set: set, runtime: runtime.identifier, environment: environment)
        let udid: String
        if let leased = previews.simulatorLeases[leaseKey] {
            udid = leased
        } else if let free = devices.first(where: { !Set(previews.simulatorLeases.values).contains($0.udid) }) {
            udid = free.udid
            previews.simulatorLeases[leaseKey] = udid
        } else {
            let names = Set(devices.map(\.name))
            var number = 1
            while names.contains(PreviewSimulator.deviceNamePrefix + String(number)) { number += 1 }
            udid = try await PreviewSimulator.create(name: PreviewSimulator.deviceNamePrefix + String(number), runtime: runtime, set: set,
                                                     environment: environment)
            previews.simulatorLeases[leaseKey] = udid
        }
        try await PreviewSimulator.boot(udid, set: set, environment: environment)
        return udid
    }

    /// At launch: the devices of the set that an earlier run left booted, after a crash for
    /// example, shut down (docs/views.md › iOS Simulator).
    func shutDownLeftoverPreviewSimulators() {
        let set = previewSimulatorSet
        guard FileManager.default.fileExists(atPath: set.path) else { return }
        let environment = ProcessEnvironment.withoutHephaestusVariables(ProcessInfo.processInfo.environment)
        Task.detached {
            await PreviewSimulator.shutdownAll(set: set, environment: environment)
        }
    }

    /// The host of a lease stopped for good: its device shuts down.
    func releasePreviewSimulator(_ leaseKey: String) {
        guard let udid = previews.simulatorLeases.removeValue(forKey: leaseKey) else { return }
        let set = previewSimulatorSet
        let environment = ProcessEnvironment.withoutHephaestusVariables(claudeCLI.loginEnvironment ?? ProcessInfo.processInfo.environment)
        Task.detached {
            await PreviewSimulator.shutdown(udid, set: set, environment: environment)
        }
    }

    private func previewHostMessage(_ key: String, _ name: String, _ platform: PreviewPlatform, _ hostID: UUID,
                                    _ message: PreviewHost.Message) {
        guard previews.units[key]?.targets[name]?.builds[platform]?.hostID == hostID else { return }
        if message.type == "selected" {
            if let request = message.request { answerSelectRequest(request, message.elements ?? []) }
            return
        }
        guard let window = message.window else { return }
        let parts = window.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let id = UUID(uuidString: String(parts[0])), let index = Int(parts[1]),
              let session = previews.sessions[id] else { return }
        let device = parts.count == 3 ? String(parts[2]) : nil
        if let device, !session.settings.devices.contains(where: { $0.name == device }) { return }
        let frameKey = PreviewService.FrameKey(index: index, device: device)
        switch message.type {
        case "frame":
            guard let png = message.png else { return }
            session.frames[frameKey] = PreviewService.Frame(sequence: session.sequence + 1, png: png, width: message.width ?? 0,
                                                            height: message.height ?? 0)
            notifyPreviewSession(session)
        case "outlines":
            let outlines = (message.outlines ?? []).compactMap { values -> PreviewRect? in
                values.count == 4 ? PreviewRect(x: values[0], y: values[1], width: values[2], height: values[3]) : nil
            }
            guard session.outlines[frameKey] ?? [] != outlines else { return }
            session.outlines[frameKey] = outlines
            if session.selection != nil { notifyPreviewSession(session) }
        default:
            break
        }
    }

    private func previewHostEnded(_ key: String, _ name: String, _ platform: PreviewPlatform, _ hostID: UUID, _ reason: String,
                                  _ tail: [String]) {
        guard let build = previews.units[key]?.targets[name]?.builds[platform], build.hostID == hostID else { return }
        build.host = nil
        build.stopMessages = [reason] + tail
        for session in previews.sessions(ofUnit: key, target: name, showing: platform) {
            refreshPreviewSession(session)
        }
    }

    /// The progress of a build, for the sessions of its unit.
    func previewBuildProgress(_ key: String, _ progress: String) {
        for session in previews.sessions(ofUnit: key) where session.state == .building && session.progress != progress {
            session.progress = progress
            notifyPreviewSession(session)
        }
    }

    /// True when the build of a target for a platform is of the generation built.
    private func previewBuildIsCurrent(_ unit: PreviewService.Unit, _ name: String, _ platform: PreviewPlatform, _ generation: Int) -> Bool {
        unit.targets[name]?.builds[platform]?.generation == generation
    }

    /// Builds the targets of the files asked for, for the platforms asked for that they build for
    /// and whose build is not of `generation`.
    private func buildPreviewUnit(_ unit: PreviewService.Unit, requests: [String: Set<PreviewPlatform>], generation: Int,
                                  environment: [String: String]) async -> PreviewUnitBuild {
        let key = unit.unit.folder.standardizedFileURL.path
        let makeOutput = { [weak self] () -> PreviewBuildOutput in
            PreviewBuildOutput { [weak self] progress in
                Task { await self?.previewBuildProgress(key, progress) }
            }
        }
        let box = unit.process
        let track: (ChildProcess?) -> Void = { process in box.process = process }
        var result = PreviewUnitBuild()
        let folder = unit.unit.folder
        let folderPath = folder.standardizedFileURL.path
        let files = Set(requests.keys)
        let context = await viewElementContext(folder: key)
        unit.elementContext = context
        func failAll(_ messages: [String]) {
            for file in files { result.fileFailures[file] = .messages(messages) }
        }
        func relative(_ file: String) -> String {
            file.hasPrefix(folderPath + "/") ? String(file.dropFirst(folderPath.count + 1)) : file
        }
        /// The platforms to build for a target: asked for, built for, and not current.
        func platforms(_ name: String, wanted: Set<PreviewPlatform>, supported: Set<PreviewPlatform>) -> [PreviewPlatform] {
            wanted.intersection(supported).filter { !previewBuildIsCurrent(unit, name, $0, generation) }.sorted()
        }
        /// The iOS Simulator SDK, or why the iOS builds fail.
        var iOSSDK: Result<String, PreviewSimulator.Failure>?
        func simulatorSDK() async -> Result<String, PreviewSimulator.Failure> {
            if let iOSSDK { return iOSSDK }
            let value: Result<String, PreviewSimulator.Failure>
            if (try? await PreviewSimulator.runtime(set: previewSimulatorSet, environment: environment)) == nil {
                value = .failure(PreviewSimulator.Failure(message: PreviewSimulator.noRuntimeMessage))
            } else if let path = await PreviewSimulator.sdkPath(environment: environment, directory: folder) {
                value = .success(path)
            } else {
                value = .failure(PreviewSimulator.Failure(message: "The iOS Simulator SDK of Xcode cannot be found."))
            }
            iOSSDK = value
            return value
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
            guard let described = await SwiftPackagePreviewBuild.describe(buildFolder: unit.buildFolder, environment: environment,
                                                                          output: describeOutput, track: track) else {
                failAll(describeOutput.lastLines.isEmpty ? ["swift package describe failed."] : describeOutput.lastLines)
                return result
            }
            var wanted: [String: PackageTarget] = [:]
            var wantedPlatforms: [String: Set<PreviewPlatform>] = [:]
            for file in files {
                guard let target = PackageTarget.target(of: relative(file), in: described.targets) else {
                    result.fileFailures[file] = .noTarget
                    continue
                }
                result.fileTargets[file] = target.name
                result.targetPlatforms[target.name] = described.platforms
                wanted[target.name] = target
                wantedPlatforms[target.name, default: []].formUnion(requests[file] ?? [])
            }
            var maps: [String: [String: PreviewSourceMap]] = [:]
            for target in wanted.values.sorted(by: { $0.name < $1.name }) {
                do {
                    maps[target.name] = try SwiftPackagePreviewBuild.mirror(target: target, package: folder, buildFolder: unit.buildFolder,
                                                                            context: context)
                    unit.mirrored[target.name] = target
                } catch {
                    let failure = PreviewUnitBuild.Outcome.failure(["The build folder cannot be written: \(error.localizedDescription)"])
                    for platform in platforms(target.name, wanted: wantedPlatforms[target.name] ?? [], supported: described.platforms) {
                        result.outcomes[target.name, default: [:]][platform] = failure
                    }
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
                for platform in platforms(target.name, wanted: wantedPlatforms[target.name] ?? [], supported: described.platforms) {
                    let output = makeOutput()
                    output.sourceMaps = maps[target.name] ?? [:]
                    var sdk: String?
                    if platform == .iOS {
                        switch await simulatorSDK() {
                        case .success(let path): sdk = path
                        case .failure(let failure):
                            result.outcomes[target.name, default: [:]][platform] = .failure([failure.message])
                            continue
                        }
                    }
                    guard let executable = await SwiftPackagePreviewBuild.build(target: target, buildFolder: unit.buildFolder, iOSSDK: sdk,
                                                                                environment: environment, output: output, track: track) else {
                        result.outcomes[target.name, default: [:]][platform] = .failure(output.failureMessages)
                        continue
                    }
                    if platform == .macOS {
                        result.outcomes[target.name, default: [:]][platform] = .success(product: executable, bundleID: nil)
                        continue
                    }
                    do {
                        let app = try SwiftPackagePreviewBuild.makeIOSApp(target: target, executable: executable, buildFolder: unit.buildFolder)
                        result.outcomes[target.name, default: [:]][platform] = .success(product: app.app, bundleID: app.bundleID)
                    } catch {
                        result.outcomes[target.name, default: [:]][platform] = .failure(["The app of the previews cannot be written: \(error.localizedDescription)"])
                    }
                }
            }
        case .xcodeProject(let projectURL):
            guard let project = XcodeProject.read(projectURL) else {
                failAll(["The project \(unit.unit.displayName) cannot be read."])
                return result
            }
            var wanted: [String: XcodeProject.Target] = [:]
            var wantedPlatforms: [String: Set<PreviewPlatform>] = [:]
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
                result.targetPlatforms[target.name] = target.platforms
                wanted[target.name] = target
                wantedPlatforms[target.name, default: []].formUnion(requests[file] ?? [])
            }
            for target in wanted.values.sorted(by: { $0.name < $1.name }) {
                let toBuild = platforms(target.name, wanted: wantedPlatforms[target.name] ?? [], supported: target.platforms)
                guard !toBuild.isEmpty else { continue }
                let schemeOutput = makeOutput()
                guard let scheme = await XcodePreviewBuild.scheme(for: target.name, project: projectURL, folder: folder,
                                                                  environment: environment, output: schemeOutput, track: track) else {
                    let messages = schemeOutput.lastLines.isEmpty ? ["No scheme of \(unit.unit.displayName) builds \(target.name)."] : schemeOutput.lastLines
                    for platform in toBuild { result.outcomes[target.name, default: [:]][platform] = .failure(messages) }
                    continue
                }
                do {
                    try XcodePreviewBuild.writeMarks(target: target, buildFolder: unit.buildFolder, context: context)
                } catch {
                    for platform in toBuild {
                        result.outcomes[target.name, default: [:]][platform] = .failure(["The build folder cannot be written: \(error.localizedDescription)"])
                    }
                    continue
                }
                for platform in toBuild {
                    if platform == .iOS, case .failure(let failure) = await simulatorSDK() {
                        result.outcomes[target.name, default: [:]][platform] = .failure([failure.message])
                        continue
                    }
                    result.outcomes[target.name, default: [:]][platform] = await buildXcodeTarget(
                        target, project: projectURL, scheme: scheme, platform: platform, unit: unit, environment: environment,
                        makeOutput: makeOutput, track: track)
                }
            }
        }
        return result
    }

    /// Builds an Xcode target for a platform, then its host, and for iOS its app.
    private func buildXcodeTarget(_ target: XcodeProject.Target, project: URL, scheme: String, platform: PreviewPlatform,
                                  unit: PreviewService.Unit, environment: [String: String], makeOutput: () -> PreviewBuildOutput,
                                  track: @escaping (ChildProcess?) -> Void) async -> PreviewUnitBuild.Outcome {
        let folder = unit.unit.folder
        let output = makeOutput()
        guard await XcodePreviewBuild.build(project: project, scheme: scheme, folder: folder, buildFolder: unit.buildFolder,
                                            platform: platform, environment: environment, output: output, track: track) else {
            return .failure(output.failureMessages)
        }
        let settingsOutput = makeOutput()
        guard let settings = await XcodePreviewBuild.settings(target: target.name, project: project, scheme: scheme, folder: folder,
                                                              buildFolder: unit.buildFolder, platform: platform, environment: environment,
                                                              output: settingsOutput, track: track) else {
            return .failure(settingsOutput.lastLines)
        }
        let hostOutput = makeOutput()
        guard let executable = await XcodePreviewBuild.compileHost(target: target, settings: settings, buildFolder: unit.buildFolder,
                                                                   platform: platform, environment: environment, output: hostOutput,
                                                                   track: track) else {
            return .failure(hostOutput.failureMessages)
        }
        guard platform == .iOS else { return .success(product: executable, bundleID: nil) }
        do {
            let app = try XcodePreviewBuild.makeIOSApp(target: target, settings: settings, executable: executable, buildFolder: unit.buildFolder)
            return .success(product: app.app, bundleID: app.bundleID)
        } catch {
            return .failure(["The app of the previews cannot be written: \(error.localizedDescription)"])
        }
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

    /// At shutdown: the builds and the hosts end, and the simulator devices shut down.
    func stopPreviews() async {
        previews.sweeper?.cancel()
        var processes: [ChildProcess] = []
        var usedSimulators = !previews.simulatorLeases.isEmpty
        for unit in previews.units.values {
            unit.build?.cancel()
            if let process = unit.process.process {
                process.signalGroup(SIGTERM)
                processes.append(process)
            }
            for target in unit.targets.values {
                for build in target.builds.values {
                    build.idleStop?.cancel()
                    if let host = build.host as? PreviewHost {
                        host.process.signalGroup(SIGTERM)
                        processes.append(host.process)
                    } else if let host = build.host {
                        host.stop()
                        usedSimulators = true
                    }
                    build.host = nil
                }
            }
        }
        previews.simulatorLeases.removeAll()
        for session in previews.sessions.values {
            let waiters = session.waiters.values
            session.waiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let requests = previews.selectRequests.values
        previews.selectRequests.removeAll()
        requests.forEach { $0.resume(returning: nil) }
        let deadline = ContinuousClock.now + .seconds(3)
        for process in processes {
            while !process.hasExited, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !process.hasExited { process.signalGroup(SIGKILL) }
        }
        if usedSimulators {
            let environment = ProcessEnvironment.withoutHephaestusVariables(ProcessInfo.processInfo.environment)
            await PreviewSimulator.shutdownAll(set: previewSimulatorSet, environment: environment)
        }
    }
}
