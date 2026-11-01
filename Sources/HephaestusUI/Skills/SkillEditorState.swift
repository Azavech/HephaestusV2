// OWNER: ui-skills-feedback — the skill form and the open extra file of the Skills section, kept per
// window and project (docs/skills.md › Editor, › Saving).
import Foundation
import Observation

/// The edited skill of a window (`ProjectViewState.skillEditor`): the form (name, description,
/// body) and the open extra file, with their unsaved changes.
// STUB: ui-skills-feedback
@MainActor @Observable
final class SkillEditorState {
    /// The skill the form shows.
    var skillName: String

    init(skillName: String) {
        self.skillName = skillName
    }

    /// The form, then the open extra file, when they have unsaved changes; each prompts
    /// `Do you want to save the changes to “<name>”?` (docs/skills.md › Saving).
    var unsavedEditors: [any UnsavedEditor] {
        []
    }
}
