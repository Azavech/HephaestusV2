// OWNER: ui-skills-feedback — the New File sheet of a skill's extra files (docs/skills.md › Editor).
import HephaestusCore
import SwiftUI

/// A new extra file of a skill, created with `skills.writeFile`.
// STUB: ui-skills-feedback
struct NewSkillFileSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let skillName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "NewSkillFileSheet") { dismiss() }
    }
}
