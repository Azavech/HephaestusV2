// OWNER: ui-builds — when the Builds row shows and when a window leaves the Builds section
// (docs/builds.md › Visibility).
import Foundation
import HephaestusCore

/// The tab of the Builds section's list (docs/builds.md › Layout).
enum BuildsTab: String, Codable, CaseIterable, Sendable {
    case runs
    case releases
}

/// The active project of a window and whether its loaded detail had a GitHub page, as the window
/// last saw it.
struct ObservedGitHubPage: Equatable {
    var deviceID: String
    var projectID: String
    var hasPage: Bool
}

extension WindowState {
    /// The Builds row shows while the active project's detail in the workspace has a GitHub page;
    /// View ▸ Builds is enabled meanwhile (docs/builds.md › Visibility).
    func showsBuilds(in workspace: DeviceWorkspace) -> Bool {
        guard workspace.deviceID == deviceID, let projectID else { return false }
        return workspace.details[projectID]?.githubPage != nil
    }

    /// Selects Dashboard when the window shows Builds for a loaded project without GitHub page,
    /// after a switch of the active project or a navigation to Builds (`buildsCheckPending`), and
    /// when the project lost its page while the window looked. A window that opens on Builds keeps
    /// it: the page read from the origin may not be known yet (docs/builds.md › Visibility). Called
    /// whenever the active project, its load, its page or the section changes.
    func reconcileBuildsSection(with workspace: DeviceWorkspace) {
        guard workspace.deviceID == deviceID, let projectID, workspace.loadedProjectIDs.contains(projectID) else { return }
        let hasPage = workspace.details[projectID]?.githubPage != nil
        let previous = observedGitHubPage
        observedGitHubPage = ObservedGitHubPage(deviceID: deviceID, projectID: projectID, hasPage: hasPage)
        let pending = buildsCheckPending
        buildsCheckPending = false
        guard section == .builds, !hasPage else { return }
        let lostPage = previous == ObservedGitHubPage(deviceID: deviceID, projectID: projectID, hasPage: true)
        if pending || lostPage {
            section = .dashboard
        }
    }
}
