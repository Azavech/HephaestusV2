import Foundation
import Testing
@testable import HephaestusCore

/// docs/data-model.md › SKILL.md format and › Skill file example; docs/skills.md › SKILL.md format.
@Suite("SKILL.md format")
struct SkillDocumentTests {
    static let example = """
    ---
    name: release-notes
    description: Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog.
    allowed-tools: Bash(git log:*), Read
    ---

    # Release notes

    1. Find the previous tag with `git describe --tags --abbrev=0`.
    2. List the commit subjects since that tag with `git log <tag>..HEAD --format=%s`.
    3. Group them by conventional commit type (feat, fix, others) and write one bullet per commit.

    """

    static let exampleBody = "\n# Release notes\n\n1. Find the previous tag with `git describe --tags --abbrev=0`.\n"
        + "2. List the commit subjects since that tag with `git log <tag>..HEAD --format=%s`.\n"
        + "3. Group them by conventional commit type (feat, fix, others) and write one bullet per commit.\n"

    @Test("The example of the docs reads as the Skill of docs/skills.md and writes back byte for byte")
    func example() throws {
        let document = try SkillDocument.parse(Data(Self.example.utf8), folderName: "release-notes")
        #expect(document.frontmatter.name == "release-notes")
        #expect(document.frontmatter.description
            == "Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog.")
        #expect(document.frontmatter.extraFrontmatter == ["allowed-tools": .string("Bash(git log:*), Read")])
        #expect(document.body == Self.exampleBody)
        #expect(String(decoding: try document.encoded(), as: UTF8.self) == Self.example)
    }

    @Test("A file whose first line is not --- is all body, with the folder name and an empty description")
    func noFrontmatter() throws {
        let text = "# Notes\n---\nname: other\n---\n"
        let document = try SkillDocument.parse(Data(text.utf8), folderName: "notes")
        #expect(document == SkillDocument(frontmatter: SkillFrontmatter(name: "notes"), body: text))
        let indented = try SkillDocument.parse(Data(" ---\nname: x\n---\n".utf8), folderName: "notes")
        #expect(indented.body == " ---\nname: x\n---\n")
    }

    @Test("The folder name replaces a missing or different name; a missing description reads as empty")
    func folderName() throws {
        let document = try SkillDocument.parse(Data("---\nname: other\n---\nBody".utf8), folderName: "mine")
        #expect(document.frontmatter.name == "mine")
        #expect(document.frontmatter.description == "")
        #expect(document.body == "Body")
        let encoded = String(decoding: try document.encoded(), as: UTF8.self)
        #expect(encoded == "---\nname: mine\ndescription: ''\n---\nBody")
    }

    @Test("A leading byte order mark is skipped and CR LF lines are accepted; the body stays verbatim")
    func bomAndCRLF() throws {
        let text = "\u{FEFF}---\r\nname: crlf\r\ndescription: Line endings\r\n---\r\nFirst\r\nSecond\r\n"
        let document = try SkillDocument.parse(Data(text.utf8), folderName: "crlf")
        #expect(document.frontmatter.description == "Line endings")
        #expect(document.body == "First\r\nSecond\r\n")
    }

    @Test("A closing line at the end of the file gives an empty body; an empty frontmatter is an empty mapping")
    func edges() throws {
        let closing = try SkillDocument.parse(Data("---\ndescription: d\n---".utf8), folderName: "a")
        #expect(closing.body == "")
        #expect(closing.frontmatter.description == "d")
        let empty = try SkillDocument.parse(Data("---\n---\nBody\n".utf8), folderName: "a")
        #expect(empty == SkillDocument(frontmatter: SkillFrontmatter(name: "a"), body: "Body\n"))
    }

    @Test("Unreadable files: not UTF-8, no closing line, not a mapping, duplicate keys")
    func invalid() throws {
        #expect(throws: SkillDocument.ReadError.notUTF8) {
            try SkillDocument.parse(Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE]), folderName: "a")
        }
        #expect(throws: SkillDocument.ReadError.unclosedFrontmatter) {
            try SkillDocument.parse(Data("---\nname: a\ndescription: b\n".utf8), folderName: "a")
        }
        #expect(throws: SkillDocument.ReadError.unclosedFrontmatter) {
            try SkillDocument.parse(Data("---".utf8), folderName: "a")
        }
        for frontmatter in ["- a\n- b\n", "just text\n", "description: [unclosed\n", "description: a\ndescription: b\n",
                            "description: {nested: map}\n"] {
            #expect(throws: SkillDocument.ReadError.self) {
                try SkillDocument.parse(Data("---\n\(frontmatter)---\nBody".utf8), folderName: "a")
            }
        }
    }

    @Test("Extra keys are written after name and description, sorted by key; multi-line values use a block")
    func writing() throws {
        let frontmatter = SkillFrontmatter(name: "a", description: "Two\nlines", extraFrontmatter: [
            "model": .string("haiku"), "allowed-tools": .string("Read"), "disable-model-invocation": .bool(true),
        ])
        let text = String(decoding: try SkillDocument(frontmatter: frontmatter, body: "Body\n").encoded(), as: UTF8.self)
        #expect(text == "---\nname: a\ndescription: |-\n  Two\n  lines\nallowed-tools: Read\ndisable-model-invocation: true\nmodel: haiku\n---\nBody\n")
        let read = try SkillDocument.parse(Data(text.utf8), folderName: "a")
        #expect(read.frontmatter == frontmatter)
        #expect(read.body == "Body\n")
    }
}
