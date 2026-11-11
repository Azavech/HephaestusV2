// OWNER: ui-views — the state of the Views section: its list of views, the folders collapsed, the
// view selected, the preview settings and the session of the previews shown (docs/views.md).
import AppKit
import HephaestusCore
import Observation

/// The state of a project's Views section in one window (`ProjectViewState.viewsState`): created
/// when the section first shows; never encoded.
@MainActor @Observable
final class ViewsSectionState {
    /// The last list read; nil before the first read ends.
    private(set) var views: [ProjectView]?
    /// The message of the last read when it failed.
    private(set) var listError: String?
    private(set) var isLoading = false
    /// Folders collapsed, by project path.
    var collapsed: Set<String> = []
    var selection: ViewSelection?
    var settings: PreviewSettings
    /// The names of the devices checked in the devices popover, kept by name
    /// (docs/views.md › Preview settings).
    private(set) var checkedDevices: Set<String> = []
    /// The width of the list, which its divider changes (docs/views.md › Layout).
    var listWidth: Double = 260
    /// The session of the previews of the selected view.
    private(set) var session: PreviewSessionModel?

    @ObservationIgnored private weak var workspace: DeviceWorkspace?
    @ObservationIgnored private var projectID: String?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var reloadRequested = false
    /// True once the first iPhone of the list was checked by default.
    @ObservationIgnored private var defaultDeviceChosen = false

    init(appearance: PreviewAppearance) {
        settings = PreviewSettings(appearance: appearance)
    }

    /// The appearance of the app, for the settings of a new state.
    static var currentAppearance: PreviewAppearance {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// The selected view as the list has it.
    var selectedView: ProjectView? {
        guard let selection else { return nil }
        return views?.first { ViewSelection($0) == selection }
    }

    var tree: [ViewTreeNode] {
        ViewTree.build(views ?? [])
    }

    // MARK: Following the engine

    /// Reads the list and follows `files.changed` and reconnections while the section shows.
    func appear(workspace: DeviceWorkspace, projectID: String) {
        disappear()
        self.workspace = workspace
        self.projectID = projectID
        reload()
        let events = workspace.events()
        tasks.append(Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                if case .filesChanged(let payload) = event.event, payload.projectID == projectID,
                   ViewTree.shouldReload(changed: payload.paths) {
                    self.reload()
                }
            }
        })
        let start = workspace.connectionGeneration
        let generations = Observations { [weak workspace] in workspace?.connectionGeneration ?? start }
        tasks.append(Task { @MainActor [weak self] in
            for await generation in generations where generation > start {
                self?.reload()
            }
        })
        updateSession()
    }

    /// Stops following the engine and ends the session of the previews.
    func disappear() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        session?.stop()
        session = nil
    }

    /// Reads the list again; a read asked for while one runs runs after it.
    func reload() {
        guard let workspace, let projectID else { return }
        guard !isLoading else {
            reloadRequested = true
            return
        }
        isLoading = true
        Task { @MainActor [weak self] in
            do {
                let views = try await workspace.call(ViewsList.self, ViewsList.Params(projectID: projectID))
                self?.views = views
                self?.listError = nil
            } catch {
                if self?.views == nil { self?.listError = errorMessage(error) }
            }
            guard let self else { return }
            self.isLoading = false
            if self.reloadRequested {
                self.reloadRequested = false
                self.reload()
            } else {
                self.selectionChanged()
            }
        }
    }

    /// Try Again of a failed first read.
    func retry() {
        listError = nil
        reload()
    }

    // MARK: Selection and previews

    func select(_ view: ProjectView) {
        selection = ViewSelection(view)
        updateSession()
    }

    func toggle(folder path: String) {
        if collapsed.contains(path) {
            collapsed.remove(path)
        } else {
            collapsed.insert(path)
        }
    }

    /// After a read: a selected view that is gone is no longer selected; a view whose previews
    /// changed starts a new session.
    private func selectionChanged() {
        if selection != nil, views != nil, selectedView == nil {
            selection = nil
        }
        updateSession()
    }

    /// Starts or stops the session of the selected view's previews. A new read that moves the
    /// view's lines keeps its session; one that changes its previews starts another.
    private func updateSession() {
        guard !tasks.isEmpty, let workspace, let projectID, let view = selectedView, !view.previews.isEmpty else {
            session?.stop()
            session = nil
            return
        }
        if let session, ViewSelection(session.view) == ViewSelection(view),
           session.view.previews.map(\.name) == view.previews.map(\.name) {
            return
        }
        session?.stop()
        let model = PreviewSessionModel(workspace: workspace, projectID: projectID, view: view, settings: settings)
        session = model
        model.start()
    }

    /// A change of the preview settings, for the previews shown.
    func settingsChanged() {
        session?.update(settings)
    }

    // MARK: Devices

    /// Follows the devices of `devices.json`: at first the first device of the iPhone family is
    /// checked; a device the file no longer lists is no longer checked; the settings get the
    /// checked devices with their values, in the order of the file (docs/views.md › Preview
    /// settings).
    func syncDevices(_ available: [PreviewDevice]) {
        if !defaultDeviceChosen, !available.isEmpty {
            defaultDeviceChosen = true
            if let first = available.first(where: { $0.family == .iPhone }) ?? available.first {
                checkedDevices.insert(first.name)
            }
        }
        let names = Set(available.map(\.name))
        if !checkedDevices.isSubset(of: names) {
            checkedDevices.formIntersection(names)
        }
        let devices = PreviewDeviceCatalog.grouped(available).flatMap(\.devices).filter { checkedDevices.contains($0.name) }
        if settings.devices != devices {
            settings.devices = devices
            settingsChanged()
        }
    }

    func isChecked(_ device: PreviewDevice) -> Bool {
        checkedDevices.contains(device.name)
    }

    /// Checks or unchecks a device of the list.
    func setChecked(_ device: PreviewDevice, _ checked: Bool, available: [PreviewDevice]) {
        defaultDeviceChosen = true
        if checked {
            checkedDevices.insert(device.name)
        } else {
            checkedDevices.remove(device.name)
        }
        syncDevices(available)
    }
}

/// One preview shown: its title, its device, nil for the Mac, and its last image.
struct PreviewImage: Identifiable {
    var index: Int
    var title: String
    var device: String?
    var image: NSImage?
    var id: String { "\(index)/\(device ?? "")" }
}

/// A preview session followed by the window (docs/views.md › Showing a view): started with
/// `previews.start`, polled with `previews.poll` until it is stopped, its inputs sent in order with
/// `previews.input`.
@MainActor @Observable
final class PreviewSessionModel {
    let view: ProjectView
    /// nil until the first status.
    private(set) var state: PreviewState?
    private(set) var progress: String?
    private(set) var builtAt: Date?
    private(set) var messages: [String] = []
    /// The failure of `previews.start`.
    private(set) var startError: String?
    private(set) var previews: [PreviewImage]

    @ObservationIgnored private weak var workspace: DeviceWorkspace?
    @ObservationIgnored private let projectID: String
    @ObservationIgnored private var settings: PreviewSettings
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: [(preview: Int, device: String?, event: PreviewInputEvent)] = []
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var stopped = false

    init(workspace: DeviceWorkspace, projectID: String, view: ProjectView, settings: PreviewSettings) {
        self.workspace = workspace
        self.projectID = projectID
        self.view = view
        self.settings = settings
        previews = view.previews.enumerated().map { PreviewImage(index: $0, title: $1.name ?? "Preview \($0 + 1)") }
    }

    func start() {
        task = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    /// Starts a session, then polls it; a session the engine no longer knows, after a disconnection
    /// for example, is started again.
    private func run() async {
        while !Task.isCancelled, !stopped {
            guard let workspace else { return }
            let params = PreviewsStart.Params(projectID: projectID, path: view.path, name: view.name, settings: settings)
            let id: UUID
            do {
                id = try await workspace.call(PreviewsStart.self, params).sessionID
            } catch {
                if Task.isCancelled || stopped { return }
                startError = errorMessage(error)
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            if Task.isCancelled || stopped {
                Task { try? await workspace.call(PreviewsStop.self, PreviewsStop.Params(sessionID: id)) }
                return
            }
            startError = nil
            sessionID = id
            var after = 0
            while !Task.isCancelled, !stopped {
                do {
                    let status = try await workspace.call(PreviewsPoll.self, PreviewsPoll.Params(sessionID: id, after: after))
                    if Task.isCancelled || stopped { return }
                    apply(status)
                    after = status.sequence
                } catch let error as EngineError where error.code == .notFound {
                    break
                } catch {
                    if Task.isCancelled || stopped { return }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            sessionID = nil
        }
    }

    /// The status's previews, in its order, the Mac's then each device's, with their last images.
    private func apply(_ status: PreviewStatus) {
        state = status.state
        progress = status.progress
        builtAt = status.builtAt
        messages = status.messages
        var known: [String: NSImage] = [:]
        for preview in previews {
            if let image = preview.image { known[preview.id] = image }
        }
        previews = status.previews.map { frame in
            var preview = PreviewImage(index: frame.index, title: frame.title, device: frame.device)
            preview.image = known[preview.id]
            if let base64 = frame.pngBase64, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                image.size = NSSize(width: CGFloat(frame.width) / 2, height: CGFloat(frame.height) / 2)
                preview.image = image
            }
            return preview
        }
    }

    /// Ends the session.
    func stop() {
        stopped = true
        task?.cancel()
        if let sessionID, let workspace {
            Task { try? await workspace.call(PreviewsStop.self, PreviewsStop.Params(sessionID: sessionID)) }
        }
        sessionID = nil
    }

    func update(_ settings: PreviewSettings) {
        self.settings = settings
        guard let sessionID, let workspace else { return }
        Task { try? await workspace.call(PreviewsUpdate.self, PreviewsUpdate.Params(sessionID: sessionID, settings: settings)) }
    }

    /// Sends an input after those before it; moves and scrolls that wait are merged.
    func send(preview: Int, device: String? = nil, _ event: PreviewInputEvent) {
        if let last = pending.last, last.preview == preview, last.device == device {
            if event.kind == .scroll, last.event.kind == .scroll {
                var merged = event
                merged.deltaX = (last.event.deltaX ?? 0) + (event.deltaX ?? 0)
                merged.deltaY = (last.event.deltaY ?? 0) + (event.deltaY ?? 0)
                pending[pending.count - 1].event = merged
                return
            }
            if event.kind == last.event.kind, event.kind == .mouseMoved || event.kind == .mouseDragged {
                pending[pending.count - 1].event = event
                return
            }
        }
        pending.append((preview, device, event))
        drain()
    }

    private func drain() {
        guard !sending, !pending.isEmpty, let sessionID, let workspace else {
            if sessionID == nil { pending.removeAll() }
            return
        }
        sending = true
        let next = pending.removeFirst()
        Task { @MainActor [weak self] in
            _ = try? await workspace.call(PreviewsInput.self, PreviewsInput.Params(sessionID: sessionID, preview: next.preview, device: next.device,
                                                                                  event: next.event))
            guard let self else { return }
            self.sending = false
            self.drain()
        }
    }
}
