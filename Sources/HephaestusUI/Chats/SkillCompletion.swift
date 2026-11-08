// OWNER: ui-chats — the skill completion of the composer (docs/chats.md › Skill completion).
import Foundation
import HephaestusCore
import Observation

/// The skill completion of a chat composer (docs/chats.md › Skill completion): the skills a chat's
/// project can use, the text typed after a `/` at the start of the message, the skills that match
/// it and the call that a chosen skill inserts.
enum SkillCompletion {
    /// The skills the project's generated plugin links (docs/skills.md › Generation): the skills of
    /// the library named in the project's `skills` list, and the internal skills, sorted by name.
    /// Names of the list that are missing from the library are left out.
    static func skills(library: [SkillSummary], enabled: [String]) -> [SkillSummary] {
        let names = Set(enabled).union(InternalSkills.names)
        return library.filter { names.contains($0.name) }.sorted { $0.name < $1.name }
    }

    /// The typed text: the characters between a `/` at the start of `text` and the insertion point
    /// `caret` (a UTF-16 offset), when the insertion point is in that first word, that is when
    /// they hold no white space or line break; nil otherwise.
    static func query(in text: String, caret: Int) -> String? {
        let string = text as NSString
        guard caret >= 1, caret <= string.length, string.hasPrefix("/") else { return nil }
        let typed = string.substring(with: NSRange(location: 1, length: caret - 1))
        guard typed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return typed
    }

    /// The skills whose name contains `query` in any letter case: the names that start with it,
    /// then the other ones, each group sorted by name. An empty query matches every skill.
    static func matches(_ skills: [SkillSummary], query: String) -> [SkillSummary] {
        let typed = query.lowercased()
        var starting: [SkillSummary] = []
        var containing: [SkillSummary] = []
        for skill in skills {
            let name = skill.name.lowercased()
            if name.hasPrefix(typed) {
                starting.append(skill)
            } else if name.contains(typed) {
                containing.append(skill)
            }
        }
        let byName: (SkillSummary, SkillSummary) -> Bool = { $0.name < $1.name }
        return starting.sorted(by: byName) + containing.sorted(by: byName)
    }

    /// The text that replaces the `/` and the typed text: `/hephaestus-skills:<name> `
    /// (docs/skills.md › Calls).
    static func completion(_ name: String) -> String {
        "/\(SkillsPluginGenerator.pluginName):\(name) "
    }
}

/// The skill list of a chat composer: its rows, empty while it is closed, and the selected row.
/// The composer's text field fills it and handles its keys; the composer draws it.
@MainActor @Observable
final class SkillCompletionList {
    private(set) var rows: [SkillSummary] = []
    private(set) var selection = 0
    /// Inserts the call of the skill of a row: set by the text field.
    @ObservationIgnored var choose: (Int) -> Void = { _ in }

    var isShown: Bool {
        !rows.isEmpty
    }

    /// Shows `rows`, or closes the list when it is empty. Each change of the rows selects the
    /// first row again.
    func show(_ newRows: [SkillSummary]) {
        guard newRows != rows else { return }
        rows = newRows
        selection = 0
    }

    /// ↑ and ↓: the selection stops at the first and the last rows.
    func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + offset, 0), rows.count - 1)
    }
}
