import Darwin
import Foundation
import Yams

/// A memory file: its frontmatter, kept as a YAML node so that a write changes only the keys it
/// sets, and its Markdown body (docs/memories.md › Memory files, › Writing a memory file).
struct MemoryDocument {
    /// The frontmatter mapping; nil when the file has no frontmatter.
    private(set) var frontmatter: Node.Mapping?
    /// Everything after the closing `---` line, verbatim; the whole file without frontmatter.
    var body: String
    /// The text up to the closing `---` line included, as read; written again unchanged while no
    /// frontmatter key changes.
    private var head: String
    /// True once a frontmatter key was set.
    private(set) var frontmatterChanged = false

    /// Why a memory file cannot be read; it is skipped and logged.
    enum ReadError: Error, Equatable, CustomStringConvertible {
        case tooLarge
        case notUTF8
        case unclosedFrontmatter
        case invalidFrontmatter(String)

        var description: String {
            switch self {
            case .tooLarge: return "it is larger than 20 MiB"
            case .notUTF8: return "it is not valid UTF-8"
            case .unclosedFrontmatter: return "its frontmatter has no closing --- line"
            case .invalidFrontmatter(let reason): return "its frontmatter is invalid: \(reason)"
            }
        }
    }

    /// An empty file without frontmatter, for `memories.create`.
    init() {
        frontmatter = nil
        body = ""
        head = ""
    }

    private init(frontmatter: Node.Mapping?, body: String, head: String) {
        self.frontmatter = frontmatter
        self.body = body
        self.head = head
    }

    /// Reads a memory file with the frontmatter rules of SKILL.md: when the first line is exactly
    /// `---`, the lines up to the next line that is exactly `---` are the frontmatter, a YAML
    /// mapping, and the body is everything after that closing line; otherwise the whole file is
    /// the body. A leading byte order mark is skipped and a line may end with CR LF.
    static func parse(_ data: Data) throws -> MemoryDocument {
        guard data.count <= MemoryFiles.maximumSize else {
            throw ReadError.tooLarge
        }
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
            return MemoryDocument(frontmatter: nil, body: text, head: "")
        }
        var lineStart = firstEnd + 1
        while lineStart <= bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.count
            if isDelimiter(bytes[lineStart..<lineEnd]) {
                let yaml = String(decoding: bytes[(firstEnd + 1)..<lineStart], as: UTF8.self)
                let bodyStart = min(lineEnd + 1, bytes.count)
                return MemoryDocument(frontmatter: try mapping(yaml),
                                      body: String(decoding: bytes[bodyStart...], as: UTF8.self),
                                      head: String(decoding: bytes[..<bodyStart], as: UTF8.self))
            }
            lineStart = lineEnd + 1
        }
        throw ReadError.unclosedFrontmatter
    }

    /// The bytes to write: the frontmatter as read while no key changed, else the line `---`, the
    /// frontmatter written by the YAML emitter and the line `---`; then the body. A closing line
    /// that ends the file gets its line break before a body, and a file without frontmatter whose
    /// body starts with a `---` line gets an empty frontmatter, so that the body stays the body.
    func encoded() throws -> Data {
        guard frontmatterChanged, let frontmatter else {
            if head.isEmpty {
                return Data(((Self.startsWithDelimiterLine(body) ? "---\n---\n" : "") + body).utf8)
            }
            let separator = body.isEmpty || head.utf8.last == 0x0A ? "" : "\n"
            return Data((head + separator + body).utf8)
        }
        var yaml = frontmatter.isEmpty ? "" : try Yams.serialize(node: .mapping(frontmatter), indent: 2, width: -1,
                                                                 allowUnicode: true, lineBreak: .ln)
        if !yaml.isEmpty, !yaml.hasSuffix("\n") {
            yaml += "\n"
        }
        return Data(("---\n" + yaml + "---\n" + body).utf8)
    }

    // MARK: Reading the keys (docs/memories.md › Memory files)

    /// The memory of this file: its name (the file name without `.md` when the frontmatter has
    /// none), description, type and other keys.
    func memory(file: String) -> Memory {
        Memory(file: file, name: name(file: file), description: description, type: type, extraFrontmatter: extraFrontmatter,
               body: body)
    }

    /// The frontmatter `name` when it is a non-empty string, else the file name without `.md`.
    func name(file: String) -> String {
        if let value = string(frontmatter?[Self.nameKey]), !value.isEmpty {
            return value
        }
        return MemoryFiles.stem(of: file)
    }

    /// The frontmatter `description` when it is a string, else `""`.
    var description: String {
        string(frontmatter?[Self.descriptionKey]) ?? ""
    }

    /// `metadata.type` when `metadata` is a mapping with the key `type`, else a top-level `type`,
    /// as the CLI reads them; nil when it is not a string.
    var type: String? {
        if case .mapping(let metadata)? = frontmatter?[Self.metadataKey], let value = metadata[Self.typeKey] {
            return string(value)
        }
        return string(frontmatter?[Self.typeKey])
    }

    /// The frontmatter keys other than `name` and `description`, with `metadata` without its
    /// `type`; a `metadata` left empty is left out.
    var extraFrontmatter: [String: JSONValue] {
        guard let frontmatter else { return [:] }
        var result: [String: JSONValue] = [:]
        for (key, value) in frontmatter {
            let name = key.string ?? ""
            guard name != Self.nameKey, name != Self.descriptionKey else { continue }
            if name == Self.metadataKey, case .mapping(var metadata) = value {
                metadata[Self.typeKey] = nil
                if !metadata.isEmpty {
                    result[name] = YAMLCoding.jsonValue(of: .mapping(metadata))
                }
                continue
            }
            result[name] = YAMLCoding.jsonValue(of: value)
        }
        return result
    }

    private func string(_ node: Node?) -> String? {
        guard let node, case .string(let value) = YAMLCoding.jsonValue(of: node) else { return nil }
        return value
    }

    // MARK: Writing the keys (docs/memories.md › Writing a memory file, rule 1)

    /// Replaces the value of `name`, or adds `name` before the other keys.
    mutating func setName(_ name: String) throws {
        try set(Self.nameKey, to: name, insertAt: 0)
    }

    /// Replaces the value of `description`, or adds it before the other keys, after a first
    /// `name`.
    mutating func setDescription(_ description: String) throws {
        let first = frontmatter?.first?.key.string
        try set(Self.descriptionKey, to: description, insertAt: first == Self.nameKey ? 1 : 0)
    }

    /// Replaces the value of `metadata.type`, adds `type` as the last key of `metadata`, or adds a
    /// `metadata` mapping after the last key. Fails when `metadata` is not a mapping.
    mutating func setType(_ type: String) throws {
        var mapping = frontmatter ?? Node.Mapping([])
        let value = try Self.scalar(type)
        if let metadata = mapping[Self.metadataKey] {
            guard case .mapping(var inner) = metadata else {
                throw MetadataNotMapping()
            }
            inner[Self.typeKey] = value
            mapping[Self.metadataKey] = .mapping(inner)
        } else {
            mapping[Self.metadataKey] = .mapping(Node.Mapping([(Node(Self.typeKey), value)]))
        }
        frontmatter = mapping
        frontmatterChanged = true
    }

    /// `metadata` is not a mapping, so no `type` can be set in it.
    struct MetadataNotMapping: Error {}

    private mutating func set(_ key: String, to text: String, insertAt index: Int) throws {
        var mapping = frontmatter ?? Node.Mapping([])
        let value = try Self.scalar(text)
        if mapping[key] != nil {
            mapping[key] = value
        } else {
            var pairs = mapping.map { ($0.key, $0.value) }
            pairs.insert((Node(key), value), at: min(index, pairs.count))
            mapping = Node.Mapping(pairs)
        }
        frontmatter = mapping
        frontmatterChanged = true
    }

    /// The YAML node of a string as the writing rules of docs/data-model.md › Keys and values
    /// write it: quoted when YAML would read it as another type, in literal block style when it
    /// holds a line break.
    static func scalar(_ text: String) throws -> Node {
        let yaml = try YAMLCoding.encode([scalarKey: text])
        guard case .mapping(let mapping)? = try Yams.compose(yaml: yaml), let value = mapping[scalarKey] else {
            return Node(text, Tag(.str), .doubleQuoted)
        }
        return value
    }

    private static let scalarKey = "value"
    static let nameKey = "name"
    static let descriptionKey = "description"
    static let metadataKey = "metadata"
    static let typeKey = "type"

    // MARK: Parsing helpers

    private static let delimiter = Array("---".utf8)

    /// True when the text's first line is exactly `---`, with or without a final CR.
    static func startsWithDelimiterLine(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let end = bytes.firstIndex(of: 0x0A) ?? bytes.count
        return isDelimiter(bytes[0..<end])
    }

    /// A line that is exactly `---`, with or without a final CR.
    private static func isDelimiter(_ line: ArraySlice<UInt8>) -> Bool {
        var line = line
        if line.last == 0x0D {
            line = line.dropLast()
        }
        return line.elementsEqual(delimiter)
    }

    /// The frontmatter mapping; an empty frontmatter, or one of white space only, is an empty
    /// mapping.
    private static func mapping(_ yaml: String) throws -> Node.Mapping {
        guard !yaml.allSatisfy({ $0.isWhitespace }) else {
            return Node.Mapping([])
        }
        do {
            guard case .mapping(let mapping) = try YAMLCoding.parseMapping(yaml) else {
                throw ReadError.invalidFrontmatter("the root of the document is not a mapping")
            }
            return mapping
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.invalidFrontmatter(FormatError.describe(error))
        }
    }
}

/// Names, limits and the text operations on memory files and `MEMORY.md`
/// (docs/memories.md › Memory files, › MEMORY.md, › Rename, create and delete).
enum MemoryFiles {
    /// The index file of a memory folder.
    static let indexFileName = "MEMORY.md"
    /// The largest memory file or `MEMORY.md` the engine reads or writes: 20 MiB.
    static let maximumSize = 20 * 1024 * 1024

    /// The file name without `.md`.
    static func stem(of file: String) -> String {
        file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    }

    /// True for `MEMORY.md` in any letter case.
    static func isIndex(_ file: String) -> Bool {
        file.lowercased() == indexFileName.lowercased()
    }

    /// True for a name a memory file can have: it ends with `.md`, does not start with `.`, holds
    /// no `/` or NUL, and is not `MEMORY.md`.
    static func isMemoryFileName(_ file: String) -> Bool {
        file.hasSuffix(".md") && !file.hasPrefix(".") && !file.contains("/") && !file.contains("\0") && !isIndex(file)
    }

    // MARK: MEMORY.md lines (docs/memories.md › MEMORY.md)

    /// The line `memories.create` appends: `- [<name>](<name>.md) — <description>`, every line
    /// break of the description replaced with a space.
    static func indexLine(name: String, description: String) -> String {
        let oneLine = description
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "- [\(name)](\(name).md) — \(oneLine)"
    }

    /// The text with the line appended; a text that does not end with a line break gets one first.
    static func appending(_ line: String, to text: String) -> String {
        if text.isEmpty {
            return line + "\n"
        }
        // The last byte, not the last Character: CR LF is one Character.
        return text + (text.utf8.last == 0x0A ? "" : "\n") + line + "\n"
    }

    /// A Markdown link whose target is the file, written `<file>` or `./<file>`.
    private static func linkPattern(_ file: String) -> NSRegularExpression {
        // The pattern is built from an escaped file name, so it always compiles.
        try! NSRegularExpression(pattern: "\\]\\((\\./)?" + NSRegularExpression.escapedPattern(for: file) + "\\)")
    }

    /// True when the line holds a link to the file.
    static func linksTo(_ file: String, line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return linkPattern(file).firstMatch(in: line, range: range) != nil
    }

    /// Every link target `<old file>`, or `./<old file>`, becomes `<new file>`, or `./<new file>`.
    static func retargeting(_ text: String, from oldFile: String, to newFile: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let template = "]($1" + NSRegularExpression.escapedTemplate(for: newFile) + ")"
        return linkPattern(oldFile).stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// The text without the lines that link to the file, each removed with its line break; the
    /// lines are split at LF, so a CR LF stays with its line.
    static func removingLines(linkingTo file: String, from text: String) -> String {
        let bytes = Array(text.utf8)
        var kept: [UInt8] = []
        var removed = false
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 0x0A {
                end += 1
            }
            end = min(end + 1, bytes.count)
            let line = bytes[start..<end]
            if linksTo(file, line: String(decoding: line, as: UTF8.self)) {
                removed = true
            } else {
                kept += line
            }
            start = end
        }
        return removed ? String(decoding: kept, as: UTF8.self) : text
    }

    /// Every `[[<old name>]]` replaced with `[[<new name>]]`.
    static func relinking(_ text: String, from oldName: String, to newName: String) -> String {
        text.replacingOccurrences(of: "[[\(oldName)]]", with: "[[\(newName)]]")
    }
}
