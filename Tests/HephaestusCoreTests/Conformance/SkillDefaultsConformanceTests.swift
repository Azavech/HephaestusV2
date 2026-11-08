import Foundation
import Testing
@testable import HephaestusCore

/// Docs conformance test 7 (docs/ci.md › Docs conformance tests): the `markdown` block of every
/// `#### Default: <name>` section of docs/skills.md equals
/// `Sources/HephaestusCore/Resources/skills/<name>/SKILL.md` followed by one newline, byte for byte.
@Suite("Default skills")
struct SkillDefaultsConformanceTests {
    /// The default SKILL.md blocks of docs/skills.md by name.
    static func documentedDefaults() throws -> [String: String] {
        var defaults: [String: String] = [:]
        for block in MarkdownSource.fencedBlocks(in: try Repository.doc("skills.md")) {
            guard let heading = block.heading, heading.hasPrefix("#### Default: "), block.info == "markdown" else { continue }
            let name = String(heading.dropFirst("#### Default: ".count))
            #expect(defaults[name] == nil, "two markdown blocks under \(heading)")
            defaults[name] = block.text
        }
        return defaults
    }

    static var skillsFolder: URL {
        Repository.root().appendingPathComponent("Sources/HephaestusCore/Resources/skills", isDirectory: true)
    }

    @Test("The documented defaults, the resource folders and InternalSkills.names are the same skills: the called ones and the system prompt skills")
    func names() throws {
        let documented = try Self.documentedDefaults()
        let folders = try FileManager.default.contentsOfDirectory(atPath: Self.skillsFolder.path).filter { !$0.hasPrefix(".") }
        #expect(Set(documented.keys) == Set(InternalSkills.names))
        #expect(Set(folders) == Set(InternalSkills.names))
        #expect(InternalSkills.names == InternalSkills.names.sorted())
        #expect(Set(InternalSkills.names) == Set(InternalSkills.calledNames + PromptSkill.allCases.map(\.rawValue)))
        #expect(InternalSkills.names.count == 14)
    }

    @Test("Each default SKILL.md equals its block followed by one newline")
    func contents() throws {
        for (name, text) in try Self.documentedDefaults() {
            let file = Self.skillsFolder.appendingPathComponent("\(name)/SKILL.md")
            #expect(try Data(contentsOf: file) == Data((text + "\n").utf8), "skills/\(name)/SKILL.md differs from docs/skills.md")
            #expect(InternalSkills.defaultContent(name) == Data((text + "\n").utf8), "the resource of \(name) in the bundle")
        }
    }

    @Test("Each default is a valid SKILL.md named after its folder, with a description the engine can write")
    func validSkillFiles() throws {
        for name in InternalSkills.names {
            let data = try #require(InternalSkills.defaultContent(name))
            let document = try SkillDocument.parse(data, folderName: name)
            #expect(String(decoding: data, as: UTF8.self).hasPrefix("---\nname: \(name)\ndescription: "))
            #expect(try SkillsLibrary.checkedDescription(document.frontmatter.description) == document.frontmatter.description)
            #expect(document.frontmatter.extraFrontmatter.isEmpty)
            // The default skills read their arguments with $ARGUMENTS only (docs/skills.md › Calls).
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("$1") && !text.contains("$0"), "\(name)")
        }
        for name in ["implement-ticket", "implement-bundle", "feedback"] {
            #expect(String(decoding: try #require(InternalSkills.defaultContent(name)), as: UTF8.self).contains("$ARGUMENTS"))
        }
    }
}
