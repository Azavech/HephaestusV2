// OWNER: ui-shell — WindowSheet, one case per sheet that a document attaches to a main window
// (docs/ui.md › WindowState), and the view that presents it.
import Foundation
import HephaestusCore
import SwiftUI

/// The sheet shown on a main window (docs/ui.md › WindowState). Each sheet's view belongs to the
/// folder of its document; setting `WindowState.sheet` to nil closes it.
// DOC-GAP: docs/ui.md › WindowState defines WindowSheet only as "one case per sheet that a
// document attaches to a main window"; the cases and their associated values below are the sheets
// of those documents, with the values each sheet needs to open.
public enum WindowSheet: Codable, Hashable, Sendable, Identifiable {
    /// New Project sheet (docs/projects.md › Creating a project).
    case newProject
    /// New Sub Project sheet, opened for an active project (docs/projects.md › Sub projects).
    case newSubProject(parentID: String)
    /// Choose Folder sheet of Open Project… on a remote device
    /// (docs/projects.md › Picking a folder on a remote device).
    case openProjectFolder
    /// Project Settings sheet (docs/projects.md › Project settings).
    case projectSettings(projectID: String)
    /// New Ticket sheet (docs/tickets.md › New Ticket sheet).
    case newTicket(projectID: String)
    /// Ticket picker sheet: Create Bundle from Selection, or Add Tickets of a bundle
    /// (docs/tickets.md › Ticket picker sheet).
    case ticketPicker(projectID: String, bundleID: String?, checkedTicketIDs: [String])
    /// Add Device sheet, with a device preselected by Enter Pairing Code… (docs/remote.md ›
    /// Adding a device, › Entering a new code).
    case addDevice(deviceID: String?)
    /// Feedback sheet; `previewID` names the screenshot `AppModel` keeps (docs/feedback.md ›
    /// Feedback sheet).
    case feedback(previewID: UUID)
    /// New Skill sheet (docs/skills.md › New Skill sheet).
    case newSkill(projectID: String)
    /// New File sheet of a skill's extra files (docs/skills.md › Editor).
    case newSkillFile(skillName: String)
    /// New Doc sheet (docs/documentation-viewer.md › New Doc).
    case newDoc(projectID: String, folder: String)
    /// Rename sheet of the docs tree (docs/documentation-viewer.md › Rename).
    case renameDoc(projectID: String, path: String)
    /// New File or New Folder sheet of the file tree (docs/code-editor.md › New File and New Folder).
    case newFile(projectID: String, folder: String, isFolder: Bool)
    /// Rename sheet of the file tree (docs/code-editor.md › Rename).
    case renameFile(projectID: String, path: String)
    /// A JavaScript `alert`, `confirm` or `prompt` of a web tab (docs/web-tabs.md › Page permissions
    /// and dialogs).
    case webPageDialog(tabID: String)

    public var id: Self { self }
}

/// The content of a main window's sheet.
struct WindowSheetView: View {
    let sheet: WindowSheet
    let window: WindowState
    let workspace: DeviceWorkspace

    var body: some View {
        switch sheet {
        case .newProject:
            NewProjectSheet(window: window, workspace: workspace, parentID: nil)
        case .newSubProject(let parentID):
            NewProjectSheet(window: window, workspace: workspace, parentID: parentID)
        case .openProjectFolder:
            ChooseFolderSheet(window: window, workspace: workspace, purpose: .openProject)
        case .projectSettings(let projectID):
            ProjectSettingsSheet(window: window, workspace: workspace, projectID: projectID)
        case .newTicket(let projectID):
            NewTicketSheet(window: window, workspace: workspace, projectID: projectID)
        case .ticketPicker(let projectID, let bundleID, let checked):
            TicketPickerSheet(window: window, workspace: workspace, projectID: projectID, bundleID: bundleID,
                              checkedTicketIDs: checked)
        case .addDevice(let deviceID):
            AddDeviceSheet(preselectedDeviceID: deviceID, window: window)
        case .feedback(let previewID):
            FeedbackSheet(previewID: previewID, source: .main(window))
        case .newSkill(let projectID):
            NewSkillSheet(window: window, workspace: workspace, projectID: projectID)
        case .newSkillFile(let skillName):
            NewSkillFileSheet(window: window, workspace: workspace, skillName: skillName)
        case .newDoc(let projectID, let folder):
            NewDocSheet(window: window, workspace: workspace, projectID: projectID, folder: folder)
        case .renameDoc(let projectID, let path):
            RenameDocSheet(window: window, workspace: workspace, projectID: projectID, path: path)
        case .newFile(let projectID, let folder, let isFolder):
            NewFileSheet(window: window, workspace: workspace, projectID: projectID, folder: folder, isFolder: isFolder)
        case .renameFile(let projectID, let path):
            RenameFileSheet(window: window, workspace: workspace, projectID: projectID, path: path)
        case .webPageDialog(let tabID):
            WebPageDialogSheet(window: window, tabID: tabID)
        }
    }
}
