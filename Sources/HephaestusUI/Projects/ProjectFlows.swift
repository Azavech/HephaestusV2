// OWNER: ui-shell — the Open Project and Remove Project flows (docs/projects.md › Opening an
// existing project, › Removing a project).
import Foundation

/// The project flows started from menus, the breadcrumb and the welcome view.
@MainActor
enum ProjectFlows {
    /// Open Project…: an `NSOpenPanel` as a sheet of the window on This Mac, the Choose Folder
    /// sheet (`WindowSheet.openProjectFolder`) on a remote device, then `projects.open`; the
    /// project becomes active in the window.
    // STUB: ui-shell
    static func openProject(window: WindowState, workspace: DeviceWorkspace) {}

    /// Remove Project…: the unsaved editors check of the project and its descendants, the
    /// confirmation alert, then `projects.remove`.
    // STUB: ui-shell
    static func removeProject(window: WindowState, workspace: DeviceWorkspace) {}
}
