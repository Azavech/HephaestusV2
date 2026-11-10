// OWNER: ui-code-docs — the API Explorer section: the Contract view of a Go service's
// `openapi/contract.yaml`, without file tree, editor tabs or mode bar (docs/openapi.md › API
// Explorer).
import AppKit
import HephaestusCore
import SwiftUI

/// The API Explorer of the active project: the Contract view of its contract as it is on disk,
/// with the section's title row above its list; the notice of the buffer's state until the buffer
/// has text; a spinner while the first read of the contract runs (docs/openapi.md › Explorer view).
struct APIExplorerView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        let isShown = workspace.showsAPIExplorer(projectID) == true
        let buffer = isShown ? currentBuffer : nil
        Group {
            if let buffer, buffer.content == .text {
                OpenAPIContractView(model: buffer.contractModel, text: buffer.text, showsTitleRow: true)
            } else if let buffer {
                CodeEditorView(buffer: buffer, workspace: workspace)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // A buffer dropped after its file was deleted is created again once the row shows again.
        .task(id: BufferNeed(isShown: isShown, hasBuffer: buffer != nil)) {
            if isShown {
                openBuffer()
            }
        }
    }

    /// What makes the view create and read the section's buffer.
    private struct BufferNeed: Hashable {
        var isShown: Bool
        var hasBuffer: Bool
    }

    /// The section's buffer, when it follows the file through the window's workspace. A buffer
    /// kept from a workspace that was closed meanwhile (a remote device shown again) missed the
    /// changes of the file: it is replaced.
    private var currentBuffer: EditorBuffer? {
        guard let buffer = FileActions.viewState(window, projectID).apiExplorerBuffer, buffer.workspace === workspace else { return nil }
        return buffer
    }

    /// Creates the section's buffer of the contract for this window and project when it has none,
    /// and reads it; a buffer kept from before goes on following the file.
    private func openBuffer() {
        if let kept = FileActions.viewState(window, projectID).apiExplorerBuffer, kept.workspace !== workspace {
            kept.detach()
            window.updateViewState(of: projectID) { $0.apiExplorerBuffer = nil }
        }
        let buffer = FileActions.viewState(window, projectID).apiExplorerBuffer
            ?? EditorBuffer(path: DeviceWorkspace.apiContractPath, role: .apiExplorer)
        if FileActions.viewState(window, projectID).apiExplorerBuffer !== buffer {
            window.updateViewState(of: projectID) { $0.apiExplorerBuffer = buffer }
        }
        buffer.load(workspace: workspace, projectID: projectID, window: window)
    }
}

extension WindowState {
    /// True while the active project's sidebar shows the API Explorer row: View ▸ API Explorer is
    /// enabled (docs/openapi.md › Availability).
    var showsAPIExplorer: Bool {
        guard let projectID, let workspace else { return false }
        return workspace.showsAPIExplorer(projectID) == true
    }

    /// Selects Dashboard when the section is the API Explorer while the active project's row is not
    /// shown; the section stays while the first read of the contract runs (docs/openapi.md ›
    /// Availability).
    func leaveHiddenAPIExplorer(in workspace: DeviceWorkspace) {
        guard section == .apiExplorer, workspace.deviceID == deviceID, let projectID,
              workspace.showsAPIExplorer(projectID) == false else { return }
        section = .dashboard
    }
}
