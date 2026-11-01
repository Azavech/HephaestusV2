import Foundation
import Testing

/// Docs conformance test 5 (docs/ci.md › Docs conformance tests): every fenced block of
/// docs/ci.md whose preceding non-blank line is ``Contents of `<path>`:`` equals the file `<path>`,
/// relative to the repository root, byte for byte, with one final newline.
@Suite("Repository files conformance")
struct RepositoryFilesConformanceTests {
    struct ReproducedFile {
        var path: String
        var content: String
        var line: Int
    }

    /// The blocks of docs/ci.md that reproduce a repository file.
    static func reproducedFiles() throws -> [ReproducedFile] {
        let lines = try Repository.doc("ci.md").components(separatedBy: "\n")
        var files: [ReproducedFile] = []
        var previous: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("```") else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    previous = line
                }
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, lines[end] != "```" {
                end += 1
            }
            if let path = previous.flatMap(Self.reproducedPath) {
                files.append(ReproducedFile(path: path, content: lines[(index + 1)..<min(end, lines.count)].joined(separator: "\n") + "\n",
                                            line: index + 1))
            }
            previous = nil
            index = end + 1
        }
        return files
    }

    /// `<path>` of a line ``Contents of `<path>`:``.
    static func reproducedPath(_ line: String) -> String? {
        let prefix = "Contents of `"
        let suffix = "`:"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { return nil }
        let path = String(line.dropFirst(prefix.count).dropLast(suffix.count))
        return path.contains("`") ? nil : path
    }

    @Test("The reproduced files are the five of docs/ci.md")
    func coverage() throws {
        #expect(try Self.reproducedFiles().map(\.path).sorted() == [
            ".github/workflows/ci.yml", ".github/workflows/release.yml", "Resources/HephaestusV2.entitlements",
            "Resources/Info.plist", "Resources/Updater-Info.plist",
        ])
    }

    @Test("Each reproduced file equals its block byte for byte")
    func contents() throws {
        let root = Repository.root()
        for file in try Self.reproducedFiles() {
            let url = root.appendingPathComponent(file.path)
            let data = FileManager.default.contents(atPath: url.path)
            #expect(data != nil, "\(file.path) is missing (docs/ci.md line \(file.line))")
            guard let data else { continue }
            #expect(data == Data(file.content.utf8), "\(file.path) differs from its block at docs/ci.md line \(file.line)")
        }
    }
}
