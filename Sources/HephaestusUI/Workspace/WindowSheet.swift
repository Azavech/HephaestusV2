// OWNER: ui-shell — WindowSheet, one case per sheet that a document attaches to a main window
// (docs/ui.md › WindowState), and the view that presents it.
import Foundation
import HephaestusCore
import SwiftUI

/// The sheet shown on a main window (docs/ui.md › WindowState). Each sheet's view belongs to the
/// folder of its document; setting `WindowState.sheet` to nil closes it. The cases and their
/// values are those of docs/ui.md › WindowState.
public enum WindowSheet: Codable, Hashable, Sendable, Identifiable {
    /// New Project sheet (docs/projects.md › Creating a project).
    case newProject
    /// New Project sheet in Existing Folder mode with a folder, opened by `Create Project Here…`
    /// (docs/projects.md › Opening an existing project).
    case newProjectInFolder(path: String)
    /// New Sub Project sheet, opened for an active project (docs/projects.md › Sub projects).
    case newSubProject(parentID: String)
    /// Choose Folder sheet of Open Project… on a remote device
    /// (docs/projects.md › Picking a folder on a remote device).
    case openProjectFolder
    /// New Ticket sheet (docs/tickets.md › New Ticket sheet).
    case newTicket(projectID: String)
    /// Ticket picker sheet of New Bundle, Create Bundle from Selection or Add Tickets… of a bundle
    /// (docs/tickets.md › Ticket picker sheet).
    case ticketPicker(projectID: String, use: TicketPickerUse)
    /// Implement sheet of a ticket (docs/tickets.md › Implement sheet).
    case implementTicket(ticketID: String)
    /// Implement sheet of Implement All (docs/tickets.md › Implement sheet).
    case implementBundle(bundleID: String)
    /// Add Link sheet of a ticket (docs/tickets.md › Add Link sheet).
    case addLink(ticketID: String)
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
    /// New Memory sheet (docs/memories.md › New Memory sheet); without `projectID` for the global
    /// memories folder.
    case newMemory(projectID: String?)
    /// New Doc sheet (docs/documentation-viewer.md › New Doc).
    case newDoc(projectID: String, folder: String)
    /// Rename sheet of the docs tree (docs/documentation-viewer.md › Rename).
    case renameDoc(projectID: String, path: String)
    /// New File or New Folder sheet of the file tree (docs/code-editor.md › New File and New Folder).
    case newFile(projectID: String, folder: String, isFolder: Bool)
    /// Rename sheet of the file tree (docs/code-editor.md › Rename).
    case renameFile(projectID: String, path: String)
    /// New View sheet of the Views section, with the folder it first holds (docs/views.md › New
    /// View sheet).
    case newView(projectID: String, folder: String)
    /// A JavaScript `alert`, `confirm` or `prompt` of a web tab (docs/web-tabs.md › Page permissions
    /// and dialogs).
    case webPageDialog(tabID: String)
    /// New VM sheet, opened by `New VM…` of the Virtual Machines popover (docs/ui.md › Virtual
    /// Machines, docs/virtual-machines.md › Buttons).
    case newVM
    /// Add Image sheet, opened by `Add Image…` of the Virtual Machines popover (docs/ui.md ›
    /// Virtual Machines, docs/virtual-machines.md › Buttons).
    case addImage
    /// Edit VM sheet of a stopped virtual machine, opened by `Edit…` of the Virtual Machines
    /// popover (docs/ui.md › Virtual Machines, docs/virtual-machines.md › Editing).
    case editVM(vmID: UUID)

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
        case .newProjectInFolder(let path):
            NewProjectSheet(window: window, workspace: workspace, parentID: nil, existingFolder: path)
        case .newSubProject(let parentID):
            NewProjectSheet(window: window, workspace: workspace, parentID: parentID)
        case .openProjectFolder:
            ChooseFolderSheet(window: window, workspace: workspace, purpose: .openProject)
        case .newTicket(let projectID):
            NewTicketSheet(window: window, workspace: workspace, projectID: projectID)
        case .ticketPicker(let projectID, let use):
            TicketPickerSheet(window: window, workspace: workspace, projectID: projectID, use: use)
        case .implementTicket(let ticketID):
            ImplementSheet(window: window, workspace: workspace, owner: .ticket(ticketID))
        case .implementBundle(let bundleID):
            ImplementSheet(window: window, workspace: workspace, owner: .bundle(bundleID))
        case .addLink(let ticketID):
            AddLinkSheet(window: window, workspace: workspace, ticketID: ticketID)
        case .addDevice(let deviceID):
            AddDeviceSheet(preselectedDeviceID: deviceID, window: window)
        case .feedback(let previewID):
            FeedbackSheet(previewID: previewID, source: .main(window))
        case .newSkill(let projectID):
            NewSkillSheet(window: window, workspace: workspace, projectID: projectID)
        case .newSkillFile(let skillName):
            NewSkillFileSheet(window: window, workspace: workspace, skillName: skillName)
        case .newMemory(let projectID):
            NewMemorySheet(window: window, workspace: workspace, scope: MemoryScope(projectID: projectID))
        case .newDoc(let projectID, let folder):
            NewDocSheet(window: window, workspace: workspace, projectID: projectID, folder: folder)
        case .renameDoc(let projectID, let path):
            RenameDocSheet(window: window, workspace: workspace, projectID: projectID, path: path)
        case .newFile(let projectID, let folder, let isFolder):
            NewFileSheet(window: window, workspace: workspace, projectID: projectID, folder: folder, isFolder: isFolder)
        case .renameFile(let projectID, let path):
            RenameFileSheet(window: window, workspace: workspace, projectID: projectID, path: path)
        case .newView(let projectID, let folder):
            NewViewSheet(window: window, workspace: workspace, projectID: projectID, folder: folder)
        case .webPageDialog(let tabID):
            WebPageDialogSheet(window: window, tabID: tabID)
        case .newVM:
            // A main window has no table under which to show a failed start: it shows the alert.
            NewVMSheet { message in
                window.alert = WindowAlert(title: "Start failed", message: message)
            }
        case .addImage:
            AddImageSheet()
        case .editVM(let vmID):
            EditVMSheet(vmID: vmID)
        }
    }
}
