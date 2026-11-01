import Darwin
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

/// A free port below the system's ephemeral range (49152-65535), for a server that binds it
/// later, or whose port must stay unused once it stops. A port of the ephemeral range, once
/// released, can be given at any time to another test's listener that asks for port 0: a server
/// binding 127.0.0.1 on it then receives the loopback connections meant for that listener, and
/// a check that the old port refuses connections reaches that listener. Each call returns another
/// port.
func unusedTestPort() throws -> Int {
    for _ in 0..<200 {
        let candidate = Int.random(in: 20_000..<45_000)
        guard TestPorts.claim(candidate) else { continue }
        if TestPorts.canBind(candidate, family: AF_INET) && TestPorts.canBind(candidate, family: AF_INET6) {
            return candidate
        }
    }
    throw TestPorts.NoFreePort()
}

private enum TestPorts {
    struct NoFreePort: Error {}

    private static let lock = NSLock()
    /// The ports `unusedTestPort` returned during this run.
    nonisolated(unsafe) private static var claimed: Set<Int> = []

    static func claim(_ port: Int) -> Bool {
        lock.withLock { claimed.insert(port).inserted }
    }

    /// Whether 127.0.0.1 (IPv4) or the IPv6 wildcard address can be bound on `port` now.
    static func canBind(_ port: Int, family: Int32) -> Bool {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port).bigEndian)
        address.sin6_addr = in6addr_any
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
        }
    }
}
