// OWNER: ui-skills-feedback — the Skills section: library list and editor (docs/skills.md › Skills section).
import HephaestusCore
import SwiftUI

/// The skills library with the active project's enablement (`ProjectViewState.selectedSkillName`, `skillEditor`); a selected skill that does not exist shows `NotFoundView(kind: "Skill", id:)`.
// STUB: ui-skills-feedback
struct SkillsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "SkillsSectionView")
    }
}
