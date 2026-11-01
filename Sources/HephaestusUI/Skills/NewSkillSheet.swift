// OWNER: ui-skills-feedback — the New Skill sheet (docs/skills.md › New Skill sheet).
import HephaestusCore
import SwiftUI

/// New Skill; Create calls `skills.create`, then `skills.setEnabled`.
// STUB: ui-skills-feedback
struct NewSkillSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "NewSkillSheet") { dismiss() }
    }
}
