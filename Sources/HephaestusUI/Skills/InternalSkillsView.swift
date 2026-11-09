// OWNER: ui-skills-feedback — the Internal Skills view (docs/skills.md › Internal Skills view).
import HephaestusCore
import SwiftUI

/// View ▸ Internal Skills: the header `Internal Skills`, then the list and the editor of the Skills
/// section restricted to the internal skills of the window's device, outside any project
/// (docs/skills.md › Internal Skills view).
struct InternalSkillsView: View {
    let window: WindowState
    let workspace: DeviceWorkspace

    var body: some View {
        VStack(spacing: 0) {
            // The view's pane header, 36 pt like every header of the centre column (docs/ui.md ›
            // Pane headers).
            HStack {
                Text("Internal Skills")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 12)
            .paneHeaderBar()
            Divider()
            SkillsSectionView(window: window, workspace: workspace, scope: .internalSkills)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension WindowState {
    /// View ▸ Internal Skills (⇧⌘I) is enabled in a main window whose device is connected, with or
    /// without project (docs/ui.md › Menus and keyboard shortcuts).
    var canShowInternalSkills: Bool {
        isConnected
    }

    /// Shows the Internal Skills view of the window's device, with an internal skill selected: the
    /// project and the section stay as they are. When the view's editor has unsaved changes on
    /// another skill, its prompt asks first; Cancel keeps that skill selected (docs/ui.md ›
    /// Resolving a target).
    func showInternalSkill(_ name: String, in workspace: DeviceWorkspace) async {
        showsInternalSkills = true
        await SkillActions.select(name, window: self, workspace: workspace, scope: .internalSkills)
    }
}
