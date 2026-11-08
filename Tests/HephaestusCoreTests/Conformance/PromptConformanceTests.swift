import Foundation
import Testing
@testable import HephaestusCore

/// Docs conformance test 3 (docs/ci.md › Docs conformance tests): the `Filled in` column of the
/// table of docs/chats.md › Placeholders gives the placeholder set of each system prompt skill, and
/// every placeholder that a default SKILL.md uses is in its skill's set.
@Suite("Prompt placeholders")
struct PromptConformanceTests {
    /// The placeholder names of the table by skill, from its `Filled in` column.
    static func documentedSets() throws -> [String: Set<String>] {
        var sets: [String: Set<String>] = [:]
        for line in try Repository.doc("chats.md").components(separatedBy: "\n") where line.hasPrefix("| `{{") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4 else { continue }
            let name = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`{}"))
            for skill in cells[3].split(separator: ",") {
                sets[skill.trimmingCharacters(in: .whitespaces), default: []].insert(name)
            }
        }
        return sets
    }

    @Test("Each skill's set in the code equals the skills the column lists for it")
    func sets() throws {
        let documented = try Self.documentedSets()
        #expect(!documented.isEmpty)
        #expect(Set(documented.keys).isSubset(of: Set(PromptSkill.allCases.map(\.rawValue))))
        for skill in PromptSkill.allCases {
            #expect(documented[skill.rawValue, default: []] == Set(skill.placeholders), "\(skill.rawValue)")
            #expect(skill.placeholders.count == Set(skill.placeholders).count, "\(skill.rawValue)")
        }
    }

    @Test("Every placeholder that a default uses is in its skill's set")
    func defaultsUseTheirSets() throws {
        let folder = Repository.root().appendingPathComponent("Sources/HephaestusCore/Resources/skills", isDirectory: true)
        for skill in PromptSkill.allCases {
            let text = try String(contentsOf: folder.appendingPathComponent("\(skill.rawValue)/SKILL.md"), encoding: .utf8)
            for name in Prompts.placeholderNames(in: text) {
                #expect(skill.placeholders.contains(name), "{{\(name)}} in \(skill.rawValue)")
            }
        }
    }
}
