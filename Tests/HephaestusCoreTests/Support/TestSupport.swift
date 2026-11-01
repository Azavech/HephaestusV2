import Foundation

/// The repository root: the folder holding `Package.swift`, found by walking up from this file
/// (docs/ci.md › Docs conformance tests).
enum Repository {
    static func root(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        fatalError("No Package.swift above \(file)")
    }

    /// The text of `docs/<name>`.
    static func doc(_ name: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent("docs").appendingPathComponent(name), encoding: .utf8)
    }
}

/// A fenced code block of a Markdown file.
struct FencedBlock {
    /// The info string after the opening fence.
    var info: String
    /// The lines between the fences.
    var lines: [String]
    /// The line number of the opening fence, from 1.
    var line: Int
    /// The nearest heading above the block.
    var heading: String?

    var text: String { lines.joined(separator: "\n") }
}

enum MarkdownSource {
    /// Every fenced block (``` fences) of `text`, with the heading it is under.
    static func fencedBlocks(in text: String) -> [FencedBlock] {
        var blocks: [FencedBlock] = []
        var heading: String?
        var current: FencedBlock?
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if var block = current {
                if line == "```" {
                    blocks.append(block)
                    current = nil
                } else {
                    block.lines.append(line)
                    current = block
                }
            } else if line.hasPrefix("```") {
                current = FencedBlock(info: String(line.dropFirst(3)), lines: [], line: index + 1, heading: heading)
            } else if line.hasPrefix("#") {
                heading = line
            }
        }
        return blocks
    }
}

/// Creates a temporary directory, runs `body` with it and removes it.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

/// Creates a temporary directory, runs `body` with it and removes it.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}
