import Foundation

/// A `SKILL.md` file: its frontmatter and its Markdown body (docs/data-model.md › SKILL.md
/// format, docs/skills.md › SKILL.md format).
struct SkillDocument: Hashable, Sendable {
    var frontmatter: SkillFrontmatter
    /// Everything after the closing `---` line, verbatim; the whole file without frontmatter.
    var body: String

    /// Why a SKILL.md cannot be read; the folder is skipped and logged.
    enum ReadError: Error, Equatable, CustomStringConvertible {
        case notUTF8
        case unclosedFrontmatter
        case invalidFrontmatter(String)

        var description: String {
            switch self {
            case .notUTF8: return "SKILL.md is not valid UTF-8"
            case .unclosedFrontmatter: return "the frontmatter of SKILL.md has no closing --- line"
            case .invalidFrontmatter(let reason): return "the frontmatter of SKILL.md is invalid: \(reason)"
            }
        }
    }

    private static let delimiter = Array("---".utf8)

    /// Reads a SKILL.md: when the first line is exactly `---`, the lines up to the next line that
    /// is exactly `---` are the frontmatter, a YAML mapping, and the body is everything after
    /// that closing line; otherwise the whole file is the body. A leading byte order mark is
    /// skipped and a line may end with CR LF. The folder name replaces a frontmatter `name` that
    /// is missing or differs; a missing `description` reads as `""`.
    static func parse(_ data: Data, folderName: String) throws -> SkillDocument {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        guard let text = String(validating: bytes, as: UTF8.self) else {
            throw ReadError.notUTF8
        }
        guard let firstEnd = bytes.firstIndex(of: 0x0A), isDelimiter(bytes[0..<firstEnd]) else {
            if isDelimiter(bytes[...]) {
                throw ReadError.unclosedFrontmatter
            }
            return SkillDocument(frontmatter: SkillFrontmatter(name: folderName), body: text)
        }
        var lineStart = firstEnd + 1
        while lineStart <= bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.count
            if isDelimiter(bytes[lineStart..<lineEnd]) {
                let yaml = String(decoding: bytes[(firstEnd + 1)..<lineStart], as: UTF8.self)
                let bodyStart = min(lineEnd + 1, bytes.count)
                let body = String(decoding: bytes[bodyStart...], as: UTF8.self)
                return SkillDocument(frontmatter: try frontmatter(yaml, folderName: folderName), body: body)
            }
            lineStart = lineEnd + 1
        }
        throw ReadError.unclosedFrontmatter
    }

    /// The bytes the engine writes: the line `---`, the frontmatter (`name`, `description`, then
    /// the extra keys sorted by key), the line `---`, then the body verbatim.
    func encoded() throws -> Data {
        var yaml = try YAMLCoding.encode(frontmatter)
        if !yaml.hasSuffix("\n") {
            yaml += "\n"
        }
        return Data(("---\n" + yaml + "---\n" + body).utf8)
    }

    /// A line that is exactly `---`, with or without a final CR.
    private static func isDelimiter(_ line: ArraySlice<UInt8>) -> Bool {
        var line = line
        if line.last == 0x0D {
            line = line.dropLast()
        }
        return line.elementsEqual(delimiter)
    }

    private static func frontmatter(_ yaml: String, folderName: String) throws -> SkillFrontmatter {
        // An empty frontmatter, or one of white space only, is an empty mapping
        // (docs/data-model.md › SKILL.md format, rule 1).
        guard !yaml.allSatisfy({ $0.isWhitespace }) else {
            return SkillFrontmatter(name: folderName)
        }
        do {
            return try YAMLCoding.decode(SkillFrontmatter.self, from: yaml, userInfo: [ModelCoding.skillFolderNameKey: folderName])
        } catch {
            throw ReadError.invalidFrontmatter(FormatError.describe(error))
        }
    }
}
