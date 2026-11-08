import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/builds.md › Visibility: when the Builds row shows and when a window leaves Builds.
@MainActor
@Suite("Builds visibility")
struct BuildsVisibilityTests {
    private static let created = Date(timeIntervalSince1970: 1_800_000_000)

    /// An offline workspace with the projects `PAGE` (GitHub page) and `NONE` (no page), both
    /// loaded unless `loaded` says otherwise.
    private func workspace(loaded: Set<String> = ["PAGE", "NONE"]) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.projects = [ProjectSummary(id: "PAGE", name: "Page", rootPath: "/Users/example/Page"),
                              ProjectSummary(id: "NONE", name: "None", rootPath: "/Users/example/None")]
        for id in loaded {
            setDetail(id, page: id == "PAGE" ? "https://github.com/example/page" : nil, in: workspace)
            workspace.loadedProjectIDs.insert(id)
        }
        return workspace
    }

    private func setDetail(_ id: String, page: String?, in workspace: DeviceWorkspace) {
        let project = Project(id: id, name: id.capitalized, created: Self.created)
        workspace.details[id] = ProjectDetail(project: project, rootPath: "/Users/example/\(id)", githubPage: page)
    }

    private func window(on projectID: String, section: ProjectSection) -> WindowState {
        let window = WindowState(deviceID: "device")
        window.projectID = projectID
        window.section = section
        return window
    }

    @Test("The row shows while the active project's detail has a GitHub page")
    func rowFollowsThePage() {
        let workspace = workspace(loaded: ["PAGE"])
        #expect(window(on: "PAGE", section: .dashboard).showsBuilds(in: workspace))
        #expect(!window(on: "NONE", section: .dashboard).showsBuilds(in: workspace))
        setDetail("NONE", page: "https://github.com/example/none", in: workspace)
        #expect(window(on: "NONE", section: .dashboard).showsBuilds(in: workspace))
    }

    @Test("Switching to a project without GitHub page while Builds is selected selects Dashboard")
    func switchToProjectWithoutPage() {
        let workspace = workspace()
        let window = window(on: "PAGE", section: .builds)
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .builds)
        window.activate(projectID: "NONE")
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .dashboard)
    }

    @Test("Builds waits for the new project's detail before it gives way")
    func switchToProjectNotLoaded() {
        let workspace = workspace(loaded: ["PAGE"])
        let window = window(on: "PAGE", section: .builds)
        window.activate(projectID: "NONE")
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .builds)
        setDetail("NONE", page: nil, in: workspace)
        workspace.loadedProjectIDs.insert("NONE")
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .dashboard)
    }

    @Test("Switching to a project with a GitHub page keeps Builds")
    func switchToProjectWithPage() {
        let workspace = workspace()
        let window = window(on: "NONE", section: .builds)
        window.activate(projectID: "PAGE")
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .builds)
    }

    @Test("A window that opens on Builds keeps it until its project has a page, then follows it")
    func openedOnBuilds() {
        let workspace = workspace(loaded: ["NONE"])
        let window = window(on: "NONE", section: .builds)
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .builds)
        // The page read from the origin arrives with project.updated.
        setDetail("NONE", page: "https://github.com/example/none", in: workspace)
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .builds)
        // The page is removed.
        setDetail("NONE", page: nil, in: workspace)
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .dashboard)
    }

    @Test("A page lost while another section is shown changes nothing")
    func pageLostElsewhere() {
        let workspace = workspace()
        let window = window(on: "PAGE", section: .docs)
        window.reconcileBuildsSection(with: workspace)
        setDetail("PAGE", page: nil, in: workspace)
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .docs)
        #expect(!window.showsBuilds(in: workspace))
    }

    @Test("Re-choosing the active project does not leave Builds")
    func sameProject() {
        let workspace = workspace(loaded: ["NONE"])
        let window = window(on: "NONE", section: .builds)
        window.activate(projectID: "NONE")
        window.reconcileBuildsSection(with: workspace)
        #expect(window.section == .builds)
    }

    @Test("Switching device to a project with the same id and without page selects Dashboard")
    func deviceSwitchToSameProject() {
        let other = DeviceWorkspace(deviceID: "other", connection: OfflineConnection(), isLocal: false)
        other.projects = [ProjectSummary(id: "NONE", name: "None", rootPath: "/Users/example/None")]
        setDetail("NONE", page: nil, in: other)
        other.loadedProjectIDs.insert("NONE")
        let window = window(on: "NONE", section: .builds)
        window.reconcileBuildsSection(with: workspace(loaded: ["NONE"]))
        #expect(window.section == .builds)
        // switchDevice: the window waits for the device's default project, then activates it.
        window.deviceID = "other"
        window.projectID = nil
        window.activate(projectID: "NONE")
        window.reconcileBuildsSection(with: other)
        #expect(window.section == .dashboard)
    }

    @Test("The tab and the selections of the Builds section are persisted")
    func persistedSelections() throws {
        let window = WindowState(deviceID: "device")
        window.projectID = "PAGE"
        window.section = .builds
        window.updateViewState {
            $0.buildsTab = .releases
            $0.selectedRunID = 42415910670
            $0.selectedReleaseTag = "v0.41.0"
        }
        let json = try #require(window.persistedJSON)
        let restored = try #require(WindowState.restored(fromJSON: json))
        #expect(restored.section == .builds)
        let state = try #require(restored.projectStates[ProjectKey(deviceID: "device", projectID: "PAGE")])
        #expect(state.buildsTab == .releases)
        #expect(state.selectedRunID == 42415910670)
        #expect(state.selectedReleaseTag == "v0.41.0")
        #expect(ProjectViewState().buildsTab == .runs)
    }
}

/// docs/builds.md › Status, › Durations: the icons, texts and durations of runs, jobs and steps.
@MainActor
@Suite("Builds formats")
struct BuildsFormatTests {
    @Test("Status kinds", arguments: [
        ("queued", nil, BuildStatusKind.queued), ("waiting", nil, .queued), ("requested", nil, .queued), ("pending", nil, .queued),
        ("in_progress", nil, .running), ("completed", "success", .success), ("completed", "failure", .failure),
        ("completed", "timed_out", .failure), ("completed", "startup_failure", .failure), ("completed", "cancelled", .other),
        ("completed", "skipped", .other), ("completed", "neutral", .other), ("completed", "action_required", .other),
        ("completed", nil, .other),
    ] as [(String, String?, BuildStatusKind)])
    func kinds(status: String, conclusion: String?, kind: BuildStatusKind) {
        #expect(BuildStatusKind(status: status, conclusion: conclusion) == kind)
    }

    @Test("The icons of the statuses")
    func icons() {
        #expect(BuildStatusKind.success.symbol?.name == "checkmark.circle.fill")
        #expect(BuildStatusKind.failure.symbol?.name == "xmark.octagon.fill")
        #expect(BuildStatusKind.other.symbol?.name == "slash.circle.fill")
        #expect(BuildStatusKind.queued.symbol?.name == "clock.fill")
        #expect(BuildStatusKind.running.symbol == nil)
    }

    @Test("Status texts")
    func texts() {
        #expect(BuildFormat.statusText(status: "completed", conclusion: "success") == "Success")
        #expect(BuildFormat.statusText(status: "completed", conclusion: "timed_out") == "Timed out")
        #expect(BuildFormat.statusText(status: "in_progress", conclusion: nil) == "In progress")
        #expect(BuildFormat.statusText(status: "queued", conclusion: nil) == "Queued")
        #expect(BuildFormat.statusText(status: "completed", conclusion: nil) == "Completed")
    }

    @Test("Durations leave out the units at 0")
    func durations() {
        #expect(BuildFormat.duration(0) == "0s")
        #expect(BuildFormat.duration(42.9) == "42s")
        #expect(BuildFormat.duration(857) == "14m 17s")
        #expect(BuildFormat.duration(3605) == "1h 5s")
        #expect(BuildFormat.duration(3600) == "1h")
        #expect(BuildFormat.duration(-5) == "0s")
    }

    @Test("A completed run lasts until its last update, a running one until now")
    func runDurations() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var run = WorkflowRun(id: 1, workflowName: "CI", title: "t", branch: "main", commit: "abc", event: "push",
                              status: "completed", conclusion: "success", createdAt: start.addingTimeInterval(-10),
                              startedAt: start, updatedAt: start.addingTimeInterval(857))
        #expect(BuildFormat.runDuration(run, now: start.addingTimeInterval(5000)) == 857)
        run.status = "in_progress"
        #expect(BuildFormat.runDuration(run, now: start.addingTimeInterval(60)) == 60)
        run.startedAt = nil
        #expect(BuildFormat.runDuration(run, now: start.addingTimeInterval(60)) == 70)
    }

    @Test("A job or step has a duration once started")
    func itemDurations() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(BuildFormat.itemDuration(status: "queued", startedAt: nil, completedAt: nil, now: start) == nil)
        #expect(BuildFormat.itemDuration(status: "in_progress", startedAt: start, completedAt: nil, now: start.addingTimeInterval(9)) == 9)
        #expect(BuildFormat.itemDuration(status: "completed", startedAt: start, completedAt: start.addingTimeInterval(3), now: start) == 3)
        #expect(BuildFormat.failed("failure") && BuildFormat.failed("timed_out") && BuildFormat.failed("startup_failure"))
        #expect(!BuildFormat.failed("cancelled") && !BuildFormat.failed(nil))
    }

    @Test("The badge of a release")
    func badges() {
        #expect(ReleaseBadge.badge(isLatest: true, isPrerelease: false)?.0 == "Latest")
        #expect(ReleaseBadge.badge(isLatest: false, isPrerelease: true)?.0 == "Pre-release")
        #expect(ReleaseBadge.badge(isLatest: false, isPrerelease: false) == nil)
    }
}

/// docs/builds.md › Refresh, › Run details, › Downloads: what the section reads and when.
@MainActor
@Suite("Builds model")
struct BuildsModelTests {
    /// A connection that answers the builds methods and counts the calls.
    final class BuildsConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        private var listGate: AsyncStream<Void>?
        var runsResult: Result<[WorkflowRun], EngineError> = .success([])

        /// The next `builds.listRuns` waits for an element of `gate`.
        func holdNextList(until gate: AsyncStream<Void>) {
            lock.withLock { listGate = gate }
        }

        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connected }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        var calls: [String] { lock.withLock { names } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            let gate = lock.withLock { () -> AsyncStream<Void>? in
                names.append(M.name)
                guard M.self == BuildsListRuns.self else { return nil }
                defer { listGate = nil }
                return listGate
            }
            if let gate {
                for await _ in gate { break }
            }
            switch M.self {
            case is BuildsListRuns.Type:
                return try runsResult.get() as! M.Result
            case is BuildsGetRun.Type:
                let id = (params as! BuildsGetRun.Params).runID
                return WorkflowRun(id: id, workflowName: "CI", title: "Run \(id)", branch: "main", commit: "abc", event: "push",
                                   status: "completed", conclusion: "failure", createdAt: Date(), updatedAt: Date(), jobs: []) as! M.Result
            case is BuildsRerunRun.Type, is BuildsCancelRun.Type:
                throw EngineError(.unavailable, "gh run rerun failed: HTTP 403: Forbidden.")
            case is BuildsDownloadAsset.Type:
                return DownloadedAsset(path: "/Users/example/Downloads/App.zip") as! M.Result
            default:
                throw EngineError(.unavailable, "Offline.")
            }
        }

        func close() {}
    }

    private func model(_ connection: BuildsConnection) -> (BuildsModel, WindowState) {
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        let window = WindowState(deviceID: "device")
        window.projectID = "PAGE"
        return (BuildsModel(window: window, workspace: workspace, projectID: "PAGE"), window)
    }

    @Test("A refresh reads the list of the shown tab, then the details of its selection")
    func refreshReadsListThenDetails() async {
        let connection = BuildsConnection()
        let (model, window) = model(connection)
        window.updateViewState { $0.selectedRunID = 7 }
        await model.refresh()
        #expect(connection.calls == ["builds.listRuns", "builds.getRun"])
        #expect(model.runs == [])
        #expect(model.shownRunDetail?.id == 7)
        #expect(model.lastRefreshEnd != nil)
        #expect(!model.isRefreshing)
    }

    @Test("A failed list shows its message and the next refresh replaces it")
    func failedList() async {
        let connection = BuildsConnection()
        connection.runsResult = .failure(EngineError(.unavailable, "Install the GitHub CLI (gh) to see runs and releases."))
        let (model, _) = model(connection)
        await model.refresh()
        #expect(model.runsError == "Install the GitHub CLI (gh) to see runs and releases.")
        connection.runsResult = .success([])
        await model.refresh()
        #expect(model.runsError == nil)
        #expect(model.runs == [])
    }

    @Test("Refreshes asked for while another one runs start once when that one ends, and wait for it")
    func coalescedRefresh() async throws {
        let connection = BuildsConnection()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        connection.holdNextList(until: stream)
        let (model, _) = model(connection)
        let deadline = ContinuousClock.now + .seconds(60)
        let first = Task { await model.refresh() }
        while connection.calls.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(!connection.calls.isEmpty)
        let second = Task { await model.refresh() }
        let third = Task { await model.refresh() }
        while model.waitingRefreshes < 2, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(model.waitingRefreshes == 2)
        #expect(model.isRefreshing)
        continuation.yield()
        continuation.finish()
        await first.value
        await second.value
        await third.value
        #expect(connection.calls == ["builds.listRuns", "builds.listRuns"])
        #expect(!model.isRefreshing)
        #expect(model.waitingRefreshes == 0)
    }

    @Test("A failed re-run shows the alert of its button")
    func failedRerun() async {
        let connection = BuildsConnection()
        let (model, window) = model(connection)
        await model.rerun(7, failedOnly: true)
        #expect(window.alert?.title == "Re-run Failed Jobs failed")
        #expect(window.alert?.message == "gh run rerun failed: HTTP 403: Forbidden.")
        #expect(!model.isRunningAction)
        await model.cancel(7)
        #expect(window.alert?.title == "Cancel Run failed")
    }

    @Test("A saved asset offers Show in Finder until the section is shown again")
    func download() async {
        let connection = BuildsConnection()
        let (model, window) = model(connection)
        await model.download(tag: "v1.0", asset: "App.zip")
        let key = DownloadKey(tag: "v1.0", asset: "App.zip")
        #expect(model.downloads[key] == .saved(path: "/Users/example/Downloads/App.zip"))
        let shownAgain = BuildsModel(window: window, workspace: model.workspace, projectID: "PAGE")
        shownAgain.sectionAppeared()
        #expect(shownAgain.downloads[key] == nil)
    }

    @Test("A download that runs keeps its spinner when the section is shown again")
    func runningDownload() async {
        let connection = BuildsConnection()
        let (model, window) = model(connection)
        let key = DownloadKey(tag: "v1.0", asset: "App.zip")
        window.projectStates[ProjectKey(deviceID: "device", projectID: "PAGE"), default: ProjectViewState()].buildsDownloads[key] = .running
        let shownAgain = BuildsModel(window: window, workspace: model.workspace, projectID: "PAGE")
        shownAgain.sectionAppeared()
        #expect(shownAgain.downloads[key] == .running)
        await shownAgain.download(tag: "v1.0", asset: "App.zip")
        #expect(!connection.calls.contains("builds.downloadAsset"))
    }
}
