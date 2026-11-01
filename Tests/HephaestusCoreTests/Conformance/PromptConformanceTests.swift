import Foundation
import Testing

/// Docs conformance test 3 (docs/ci.md › Docs conformance tests): the `text` block of every
/// `### Prompt: <name>` section of docs/chats.md equals
/// `Sources/HephaestusCore/Resources/prompts/<name>.md` followed by one newline, byte for byte.
@Suite("Prompts")
struct PromptConformanceTests {
    /// The prompt blocks of docs/chats.md by name.
    static func documentedPrompts() throws -> [String: String] {
        var prompts: [String: String] = [:]
        for block in MarkdownSource.fencedBlocks(in: try Repository.doc("chats.md")) {
            guard let heading = block.heading, heading.hasPrefix("### Prompt: "), block.info == "text" else { continue }
            let name = String(heading.dropFirst("### Prompt: ".count))
            #expect(prompts[name] == nil, "two text blocks under \(heading)")
            prompts[name] = block.text
        }
        return prompts
    }

    static var promptsFolder: URL {
        Repository.root().appendingPathComponent("Sources/HephaestusCore/Resources/prompts", isDirectory: true)
    }

    static func promptFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: promptsFolder.path) where name.hasSuffix(".md") {
            files[String(name.dropLast(3))] = try Data(contentsOf: promptsFolder.appendingPathComponent(name))
        }
        return files
    }

    @Test("The sets of prompt names are equal")
    func names() throws {
        let documented = try Self.documentedPrompts()
        #expect(!documented.isEmpty)
        #expect(Set(documented.keys) == Set(try Self.promptFiles().keys))
    }

    @Test("Each prompt file equals its block followed by one newline")
    func contents() throws {
        let files = try Self.promptFiles()
        for (name, text) in try Self.documentedPrompts() {
            #expect(files[name] == Data((text + "\n").utf8), "prompts/\(name).md differs from docs/chats.md")
        }
    }

    /// docs/chats.md › Placeholders: every placeholder a prompt uses is listed, with that
    /// prompt in its "Used in" column.
    @Test("Every placeholder used is listed for its prompt")
    func placeholders() throws {
        let chats = try Repository.doc("chats.md")
        var usedIn: [String: Set<String>] = [:]
        for line in chats.components(separatedBy: "\n") where line.hasPrefix("| `{{") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4 else { continue }
            let placeholder = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            usedIn[placeholder] = Set(cells[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        #expect(!usedIn.isEmpty)
        let pattern = try NSRegularExpression(pattern: "\\{\\{[A-Za-z]+\\}\\}")
        for (name, data) in try Self.promptFiles() {
            let text = String(decoding: data, as: UTF8.self)
            let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                let placeholder = String(text[Range(match.range, in: text)!])
                #expect(usedIn[placeholder]?.contains(name) == true, "\(placeholder) in \(name).md is not listed for \(name)")
            }
        }
    }
}
