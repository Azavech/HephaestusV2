import Foundation
import Testing
@testable import HephaestusText

/// docs/code-editor.md › Conformance: the keyword, type, builtin and contextual word lists of the
/// document are compared with the tokenizers' lists.
@Suite("Word lists conformance")
struct WordListConformanceTests {
    /// The rows of the first table under `heading` whose first column is `Group`: the group cell
    /// and the words cell.
    static func groupRows(under heading: String) throws -> [(group: String, words: String)] {
        let doc = try FixtureSupport.read(FixtureSupport.repositoryRoot().appendingPathComponent("docs/code-editor.md"))
        let section = try #require(doc.components(separatedBy: heading + "\n").dropFirst().first)
        let body = section.components(separatedBy: "\n#").first ?? section
        let lines = body.components(separatedBy: "\n")
        let headerIndex = try #require(lines.firstIndex { $0.hasPrefix("| Group") })
        return lines[(headerIndex + 2)...].prefix { $0.hasPrefix("|") }.map { line in
            let cells = splitRow(line)
            return (cells[0], cells[1])
        }
    }

    /// The cells of a table row; `\|` inside a cell is a pipe.
    static func splitRow(_ line: String) -> [String] {
        let placeholder = "\u{1}"
        return line.replacingOccurrences(of: "\\|", with: placeholder)
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: placeholder, with: "|") }
    }

    /// The backticked words of a cell that are words (no punctuation other than `[` and `]`).
    static func words(_ cell: String) -> [String] {
        backticked(cell).filter { word in
            word.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "[" || $0 == "]" }
        }
    }

    static func backticked(_ cell: String) -> [String] {
        let parts = cell.components(separatedBy: "`")
        return stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
    }

    static func row(_ rows: [(group: String, words: String)], _ group: String) throws -> String {
        try #require(rows.first { $0.group == group }?.words, "no row \(group)")
    }

    @Test("Go word lists")
    func go() throws {
        let rows = try Self.groupRows(under: "### Go identifiers")
        #expect(Set(Self.words(try Self.row(rows, "Keywords"))) == GoTokenizer.keywords)
        #expect(Self.words(try Self.row(rows, "Keywords")).count == 25)
        #expect(Set(Self.words(try Self.row(rows, "Predeclared types"))) == GoTokenizer.predeclaredTypes)
        #expect(Set(Self.words(try Self.row(rows, "Predeclared constants"))) == GoTokenizer.predeclaredConstants)
        #expect(Set(Self.words(try Self.row(rows, "Builtin functions"))) == GoTokenizer.builtinFunctions)
    }

    @Test("Swift word lists")
    func swift() throws {
        let rows = try Self.groupRows(under: "### Swift identifiers")
        #expect(Set(Self.words(try Self.row(rows, "Keywords"))) == SwiftTokenizer.keywords)
        let except = Set(Self.words(try Self.row(rows, "Label list (row 3)")))
        #expect(except == SwiftTokenizer.nonLabelKeywords)
        #expect(SwiftTokenizer.labelWords == SwiftTokenizer.keywords.subtracting(except))

        let contextualRows = rows.filter { $0.group.hasPrefix("Contextual") }
        #expect(contextualRows.count == SwiftTokenizer.contextualGroups.count)
        for (row, group) in zip(contextualRows, SwiftTokenizer.contextualGroups) {
            #expect(Set(Self.words(row.words)) == group.words, "\(row.group)")
            let followers = Set(Self.backticked(row.group).compactMap { $0.unicodeScalars.first?.value })
            #expect(followers == group.followers, "\(row.group)")
            #expect(row.group.contains("followed by an identifier"))
        }
    }

    @Test("Shell word lists")
    func shell() throws {
        let rows = try Self.groupRows(under: "### Shell")
        #expect(Set(Self.words(try Self.row(rows, "Keywords"))) == ShellTokenizer.keywords)
        #expect(Set(Self.words(try Self.row(rows, "Builtins"))) == ShellTokenizer.builtins)
    }

    @Test("JSON and YAML literals")
    func literals() throws {
        let doc = try FixtureSupport.read(FixtureSupport.repositoryRoot().appendingPathComponent("docs/code-editor.md"))
        let jsonRow = try #require(doc.components(separatedBy: "\n").first { $0.hasPrefix("| 4     | Literal ") })
        #expect(Set(Self.backticked(Self.splitRow(jsonRow)[2])) == JSONTokenizer.literals)
        let yamlRow = try #require(doc.components(separatedBy: "\n").first { $0.hasPrefix("| 10    | Literal value ") })
        let cell = try #require(Self.splitRow(yamlRow)[2].components(separatedBy: "equal to").last)
        #expect(Set(Self.backticked(cell)) == YAMLTokenizer.literals)
    }
}
