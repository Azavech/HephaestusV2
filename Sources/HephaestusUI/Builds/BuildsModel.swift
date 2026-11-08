// OWNER: ui-builds — what the Builds section of one window and project read from the engine, its
// refreshes and its actions (docs/builds.md › Refresh, › Run details, › Downloads).
import Foundation
import HephaestusCore

/// The lists and details that the Builds section shows for one project in one window. They are
/// read with the `builds.*` methods and kept nowhere else: the section asks again at each refresh
/// (docs/builds.md › Refresh).
@MainActor @Observable
final class BuildsModel {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    /// The runs of `builds.listRuns`, nil before the first answer.
    private(set) var runs: [WorkflowRun]?
    /// The failure of the last `builds.listRuns`, shown in place of the list.
    private(set) var runsError: String?
    /// The releases of `builds.listReleases`, nil before the first answer.
    private(set) var releases: [GitHubRelease]?
    private(set) var releasesError: String?
    /// The details of the selected run, read with `builds.getRun`.
    private(set) var runDetail: WorkflowRun?
    private(set) var runDetailError: (runID: Int, message: String)?
    /// The details of the selected release, read with `builds.getRelease`.
    private(set) var releaseDetail: ReleaseDetail?
    private(set) var releaseDetailError: (tag: String, message: String)?
    /// True while a refresh runs; `Refresh` shows a spinner meanwhile.
    private(set) var isRefreshing = false
    /// True while `Re-run All Jobs`, `Re-run Failed Jobs` or `Cancel Run` runs.
    private(set) var isRunningAction = false
    /// When the last refresh ended; the next automatic one comes 30 s later.
    private(set) var lastRefreshEnd: Date?

    /// A refresh asked for while another one runs: it starts when that one ends, once.
    @ObservationIgnored private var refreshQueued = false
    /// The running refresh, which the refreshes asked for meanwhile wait for.
    @ObservationIgnored private var runningRefresh: Task<Void, Never>?
    /// The callers that wait for the running refresh.
    @ObservationIgnored private(set) var waitingRefreshes = 0
    /// Numbers the detail reads, so that an answer overtaken by a later read is dropped.
    @ObservationIgnored private var detailGeneration = 0

    /// The 30 seconds between two automatic refreshes (docs/builds.md › Refresh).
    static let refreshInterval: TimeInterval = 30

    init(window: WindowState, workspace: DeviceWorkspace, projectID: String) {
        self.window = window
        self.workspace = workspace
        self.projectID = projectID
    }

    /// The key of the project's view state in the window: the model's own device, which stays when
    /// the window switches device.
    private var stateKey: ProjectKey {
        ProjectKey(deviceID: workspace.deviceID, projectID: projectID)
    }

    private var viewState: ProjectViewState {
        window.projectStates[stateKey] ?? ProjectViewState()
    }

    /// The tab the section shows.
    var tab: BuildsTab { viewState.buildsTab }
    var selectedRunID: Int? { viewState.selectedRunID }
    var selectedReleaseTag: String? { viewState.selectedReleaseTag }

    /// When the next automatic refresh is due: 30 s after the end of the previous refresh.
    var nextAutomaticRefresh: Date {
        (lastRefreshEnd ?? .distantPast).addingTimeInterval(Self.refreshInterval)
    }

    // MARK: Refresh (docs/builds.md › Refresh)

    /// Reads the list of the shown tab, then the details of its selected run or release. A refresh
    /// asked for while another one runs starts when that one ends, once; every caller returns once
    /// the refreshes it waited for have ended.
    func refresh() async {
        if let runningRefresh {
            refreshQueued = true
            waitingRefreshes += 1
            await runningRefresh.value
            waitingRefreshes -= 1
            return
        }
        let task = Task { await runRefreshes() }
        runningRefresh = task
        await task.value
    }

    private func runRefreshes() async {
        isRefreshing = true
        repeat {
            refreshQueued = false
            await loadList()
            await loadDetail()
        } while refreshQueued
        isRefreshing = false
        lastRefreshEnd = Date()
        runningRefresh = nil
    }

    /// The list of the shown tab.
    private func loadList() async {
        let params = BuildsListRuns.Params(projectID: projectID)
        switch tab {
        case .runs:
            do {
                runs = try await workspace.call(BuildsListRuns.self, params)
                runsError = nil
            } catch {
                runsError = errorMessage(error)
            }
        case .releases:
            do {
                releases = try await workspace.call(BuildsListReleases.self, BuildsListReleases.Params(projectID: projectID))
                releasesError = nil
            } catch {
                releasesError = errorMessage(error)
            }
        }
    }

    /// The details of the run or release selected in the shown tab; nothing without a selection.
    func loadDetail() async {
        detailGeneration += 1
        let generation = detailGeneration
        switch tab {
        case .runs:
            guard let runID = selectedRunID else { return }
            do {
                let run = try await workspace.call(BuildsGetRun.self, BuildsGetRun.Params(projectID: projectID, runID: runID))
                guard generation == detailGeneration else { return }
                runDetail = run
                runDetailError = nil
            } catch {
                guard generation == detailGeneration else { return }
                runDetailError = (runID, errorMessage(error))
            }
        case .releases:
            guard let tag = selectedReleaseTag else { return }
            do {
                let release = try await workspace.call(BuildsGetRelease.self, BuildsGetRelease.Params(projectID: projectID, tag: tag))
                guard generation == detailGeneration else { return }
                releaseDetail = release
                releaseDetailError = nil
            } catch {
                guard generation == detailGeneration else { return }
                releaseDetailError = (tag, errorMessage(error))
            }
        }
    }

    /// The details of the selected run, when they are the selected run's.
    var shownRunDetail: WorkflowRun? {
        guard let runID = selectedRunID, runDetail?.id == runID else { return nil }
        return runDetail
    }

    /// The failure of the selected run's details, when it is the selected run's.
    var shownRunError: String? {
        guard let runID = selectedRunID, let error = runDetailError, error.runID == runID else { return nil }
        return error.message
    }

    var shownReleaseDetail: ReleaseDetail? {
        guard let tag = selectedReleaseTag, releaseDetail?.tag == tag else { return nil }
        return releaseDetail
    }

    var shownReleaseError: String? {
        guard let tag = selectedReleaseTag, let error = releaseDetailError, error.tag == tag else { return nil }
        return error.message
    }

    // MARK: Selection

    func selectRun(_ runID: Int) {
        guard selectedRunID != runID else { return }
        window.projectStates[stateKey, default: ProjectViewState()].selectedRunID = runID
        Task { await loadDetail() }
    }

    func selectRelease(_ tag: String) {
        guard selectedReleaseTag != tag else { return }
        window.projectStates[stateKey, default: ProjectViewState()].selectedReleaseTag = tag
        Task { await loadDetail() }
    }

    func selectTab(_ tab: BuildsTab) {
        guard self.tab != tab else { return }
        window.projectStates[stateKey, default: ProjectViewState()].buildsTab = tab
        Task { await refresh() }
    }

    // MARK: Run actions (docs/builds.md › Run details)

    /// `Re-run All Jobs` and `Re-run Failed Jobs`.
    func rerun(_ runID: Int, failedOnly: Bool) async {
        let title = failedOnly ? "Re-run Failed Jobs" : "Re-run All Jobs"
        await runAction(title) {
            _ = try await self.workspace.call(BuildsRerunRun.self,
                                              BuildsRerunRun.Params(projectID: self.projectID, runID: runID,
                                                                    failedOnly: failedOnly ? true : nil))
        }
    }

    /// `Cancel Run`.
    func cancel(_ runID: Int) async {
        await runAction("Cancel Run") {
            _ = try await self.workspace.call(BuildsCancelRun.self, BuildsCancelRun.Params(projectID: self.projectID, runID: runID))
        }
    }

    /// Runs an action of the buttons: the buttons are disabled meanwhile; a success refreshes at
    /// once, a failure shows the alert `<button title> failed`.
    private func runAction(_ title: String, _ action: @escaping () async throws -> Void) async {
        guard !isRunningAction else { return }
        isRunningAction = true
        do {
            try await action()
            isRunningAction = false
            await refresh()
        } catch {
            isRunningAction = false
            window.alert = .failure(title, error)
        }
    }

    // MARK: Downloads (docs/builds.md › Downloads)

    /// The downloads of release assets of the project in this window, by `DownloadKey`; they stay
    /// in the window's view state, so that a download that runs keeps its spinner when the section
    /// is shown again.
    var downloads: BuildsDownloads {
        viewState.buildsDownloads
    }

    private func setDownload(_ key: DownloadKey, _ state: AssetDownloadState?) {
        window.projectStates[stateKey, default: ProjectViewState()].buildsDownloads[key] = state
    }

    /// A new appearance of the section: the saved assets lose `Show in Finder`, the downloads that
    /// run keep their spinner (docs/builds.md › Downloads).
    func sectionAppeared() {
        let running = viewState.buildsDownloads.filter { $0.value == .running }
        window.projectStates[stateKey]?.buildsDownloads = running
    }

    /// `Download`: saves the asset with `builds.downloadAsset`; the row then shows
    /// `Show in Finder`, a failure the alert `Download failed`.
    func download(tag: String, asset: String) async {
        let key = DownloadKey(tag: tag, asset: asset)
        guard downloads[key] != .running else { return }
        setDownload(key, .running)
        do {
            let saved = try await workspace.call(BuildsDownloadAsset.self,
                                                 BuildsDownloadAsset.Params(projectID: projectID, tag: tag, asset: asset))
            setDownload(key, .saved(path: saved.path))
        } catch {
            setDownload(key, nil)
            window.alert = .failure("Download", error)
        }
    }
}

/// The release asset downloads of a project in a window (`ProjectViewState.buildsDownloads`).
typealias BuildsDownloads = [DownloadKey: AssetDownloadState]

/// An asset of a release, the key of its download.
struct DownloadKey: Hashable {
    var tag: String
    var asset: String
}

/// The state of an asset's download in the section.
enum AssetDownloadState: Equatable {
    case running
    case saved(path: String)
}
