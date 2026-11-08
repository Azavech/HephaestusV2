import Foundation
import Testing
@testable import HephaestusCore

/// docs/memories.md › Memory files, › Writing a memory file, › MEMORY.md.
@Suite("Memory files")
struct MemoryFileTests {
    /// A memory as the CLI writes it, with keys the engine does not know.
    static let example = """
    ---
    name: answer-style
    description: Answer in short sentences
    metadata:
      node_type: memory
      type: feedback
      originSessionId: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
      modified: 2026-11-07T22:39:20Z
      count: '012'
    tags: [a, b]
    ---

    Answer in short sentences.

    **Why:** the user reads on a phone.

    """

    private func parse(_ text: String) throws -> MemoryDocument {
        try MemoryDocument.parse(Data(text.utf8))
    }

    @Test("A memory file reads as name, description, type, other keys and body")
    func reading() throws {
        let memory = try parse(Self.example).memory(file: "feedback_style.md")
        #expect(memory.name == "answer-style")
        #expect(memory.description == "Answer in short sentences")
        #expect(memory.type == "feedback")
        #expect(memory.body == "\nAnswer in short sentences.\n\n**Why:** the user reads on a phone.\n")
        #expect(memory.extraFrontmatter == [
            "metadata": .object(["node_type": .string("memory"), "originSessionId": .string("3F2504E0-4F89-11D3-9A0C-0305E82C3301"),
                                 "modified": .string("2026-11-07T22:39:20Z"), "count": .string("012")]),
            "tags": .array([.string("a"), .string("b")]),
        ])
    }

    @Test("A missing, empty or non-string name gives the file name; a top-level type counts when metadata has none")
    func fallbacks() throws {
        #expect(try parse("Just a body.\n").memory(file: "loose.md") == Memory(file: "loose.md", name: "loose", description: "",
                                                                                 body: "Just a body.\n"))
        #expect(try parse("---\nname: ''\n---\n").memory(file: "a.md").name == "a")
        #expect(try parse("---\nname: 12\ndescription: 3\n---\n").memory(file: "b.md").name == "b")
        #expect(try parse("---\nname: 12\ndescription: 3\n---\n").memory(file: "b.md").description == "")
        let old = try parse("---\nname: old\ntype: user\n---\nBody\n").memory(file: "old.md")
        #expect(old.type == "user")
        #expect(old.extraFrontmatter == ["type": .string("user")])
        #expect(try parse("---\ntype: user\nmetadata:\n  type: project\n---\n").memory(file: "c.md").type == "project")
        #expect(try parse("---\ntype: user\nmetadata:\n  type: 3\n---\n").memory(file: "c.md").type == nil)
        #expect(try parse("---\nmetadata:\n  type: Notes\n---\n").memory(file: "d.md").type == "Notes")
        #expect(try parse("---\nmetadata: plain\n---\n").memory(file: "e.md").extraFrontmatter == ["metadata": .string("plain")])
        #expect(try parse("---\n---\nBody").memory(file: "f.md").body == "Body")
    }

    @Test("Files that cannot be read are refused with their reason")
    func readErrors() throws {
        #expect(throws: MemoryDocument.ReadError.unclosedFrontmatter) { try MemoryDocument.parse(Data("---\nname: a\n".utf8)) }
        #expect(throws: MemoryDocument.ReadError.notUTF8) { try MemoryDocument.parse(Data([0xFF, 0xFE, 0x00])) }
        #expect(throws: MemoryDocument.ReadError.self) { try MemoryDocument.parse(Data("---\n- a\n- b\n---\n".utf8)) }
        #expect(throws: MemoryDocument.ReadError.tooLarge) {
            try MemoryDocument.parse(Data(count: MemoryFiles.maximumSize + 1))
        }
    }

    @Test("Setting keys keeps every other key, its place and its quotes; a body change keeps the frontmatter bytes")
    func writing() throws {
        var document = try parse(Self.example)
        document.body = "\nNew body.\n"
        let bodyOnly = try #require(String(data: try document.encoded(), encoding: .utf8))
        #expect(bodyOnly == Self.example.replacingOccurrences(of: "\nAnswer in short sentences.\n\n**Why:** the user reads on a phone.\n",
                                                                  with: "\nNew body.\n"))

        try document.setDescription("Answer briefly: one sentence")
        try document.setType("user")
        let text = try #require(String(data: try document.encoded(), encoding: .utf8))
        #expect(text == """
        ---
        name: answer-style
        description: 'Answer briefly: one sentence'
        metadata:
          node_type: memory
          type: user
          originSessionId: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
          modified: 2026-11-07T22:39:20Z
          count: '012'
        tags:
        - a
        - b
        ---

        New body.

        """)
    }

    @Test("Missing keys are added: name first, description after it, type at the end of metadata or in a new metadata")
    func addingKeys() throws {
        var document = try parse("---\nmetadata:\n  node_type: memory\nextra: true\n---\nBody\n")
        try document.setDescription("Two\nlines")
        try document.setName("new-name")
        try document.setType("project")
        #expect(String(data: try document.encoded(), encoding: .utf8) == """
        ---
        name: new-name
        description: |-
          Two
          lines
        metadata:
          node_type: memory
          type: project
        extra: true
        ---
        Body

        """)

        var plain = try parse("Plain body.\n")
        try plain.setType("reference")
        #expect(String(data: try plain.encoded(), encoding: .utf8) == "---\nmetadata:\n  type: reference\n---\nPlain body.\n")

        var created = MemoryDocument()
        try created.setName("user-role")
        try created.setDescription("yes")
        try created.setType("user")
        #expect(String(data: try created.encoded(), encoding: .utf8)
            == "---\nname: user-role\ndescription: 'yes'\nmetadata:\n  type: user\n---\n")

        var broken = try parse("---\nmetadata: plain\n---\n")
        #expect(throws: MemoryDocument.MetadataNotMapping.self) { try broken.setType("user") }
    }

    @Test("A body keeps its own line after a closing --- that ends the file, and a body that starts with --- stays a body")
    func bodyBoundaries() throws {
        var closed = try parse("---\nname: a\n---")
        closed.body = "x"
        #expect(String(data: try closed.encoded(), encoding: .utf8) == "---\nname: a\n---\nx")
        var plain = try parse("Notes\n")
        plain.body = "---\nAgenda\n---\nItems\n"
        let text = try #require(String(data: try plain.encoded(), encoding: .utf8))
        #expect(text == "---\n---\n---\nAgenda\n---\nItems\n")
        #expect(try MemoryDocument.parse(Data(text.utf8)).body == "---\nAgenda\n---\nItems\n")
    }

    @Test("MEMORY.md lines: append, retarget and remove the links to a file; [[name]] links follow a rename")
    func indexLines() {
        #expect(MemoryFiles.indexLine(name: "user-role", description: "Backend\r\ndeveloper\nnew to\rSwiftUI")
            == "- [user-role](user-role.md) — Backend developer new to SwiftUI")
        #expect(MemoryFiles.appending("- [a](a.md) — A", to: "") == "- [a](a.md) — A\n")
        #expect(MemoryFiles.appending("- [a](a.md) — A", to: "# Index\n") == "# Index\n- [a](a.md) — A\n")
        #expect(MemoryFiles.appending("- [a](a.md) — A", to: "# Index") == "# Index\n- [a](a.md) — A\n")
        #expect(MemoryFiles.appending("- [b](b.md) — B", to: "- [a](a.md) — A\r\n") == "- [a](a.md) — A\r\n- [b](b.md) — B\n")

        let index = "- [User role](user_role.md) — who the user is\n- [Style](./user_role.md) — again\n- [Other](other.md) — user_role.md stays\n"
        #expect(MemoryFiles.retargeting(index, from: "user_role.md", to: "user-role.md")
            == "- [User role](user-role.md) — who the user is\n- [Style](./user-role.md) — again\n- [Other](other.md) — user_role.md stays\n")
        #expect(MemoryFiles.removingLines(linkingTo: "user_role.md", from: index) == "- [Other](other.md) — user_role.md stays\n")
        #expect(MemoryFiles.removingLines(linkingTo: "missing.md", from: index) == index)
        #expect(MemoryFiles.removingLines(linkingTo: "other.md", from: "- [a](a.md)\r\n- [o](other.md)") == "- [a](a.md)\r\n")
        #expect(MemoryFiles.removingLines(linkingTo: "a.md", from: "- [a](a.md)\r\n- [o](other.md)\r\n") == "- [o](other.md)\r\n")

        #expect(MemoryFiles.relinking("See [[user-role]] and [[user-role-2]].", from: "user-role", to: "who")
            == "See [[who]] and [[user-role-2]].")
    }

    @Test("Memory file names end with .md, are not hidden and are not MEMORY.md in any case")
    func fileNames() {
        #expect(MemoryFiles.isMemoryFileName("user-role.md"))
        #expect(MemoryFiles.isMemoryFileName("user_role.md"))
        #expect(!MemoryFiles.isMemoryFileName("MEMORY.md"))
        #expect(!MemoryFiles.isMemoryFileName("Memory.md"))
        #expect(!MemoryFiles.isMemoryFileName(".hidden.md"))
        #expect(!MemoryFiles.isMemoryFileName("notes.txt"))
        #expect(!MemoryFiles.isMemoryFileName("a/b.md"))
        #expect(MemoryFiles.stem(of: "user-role.md") == "user-role")
    }
}
