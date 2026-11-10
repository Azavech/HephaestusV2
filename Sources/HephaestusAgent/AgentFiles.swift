import Darwin
import Foundation

/// The methods `stat`, `list`, `makeDirectory`, `readFile` and `writeFile`: the files of the guest,
/// as the account (docs/virtual-machines.md › Methods).
enum AgentFiles {
    /// The most bytes one `readFile` returns.
    static let maximumRead = 8_388_608

    /// An absolute path, or one starting with `~/`, the account's home folder.
    static func path(_ params: AgentParams) throws -> String {
        let path = try params.string("path")
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + "/" + path.dropFirst(2) }
        guard path.hasPrefix("/") else { throw AgentError("path: use an absolute path or a path starting with ~/.") }
        return path
    }

    private static func reason(_ error: Error) -> String {
        var text = error.localizedDescription
        while text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    private static func entry(_ path: String) -> [String: Any]? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return [
            "isDirectory": status.st_mode & S_IFMT == S_IFDIR,
            "size": Int(status.st_size),
            "mode": Int(status.st_mode & 0o7777),
        ]
    }

    static func status(_ params: AgentParams) throws -> AgentResult {
        let path = try path(params)
        guard var entry = entry(path) else {
            return AgentResult(json: ["exists": false, "isDirectory": false, "size": 0, "mode": 0])
        }
        entry["exists"] = true
        return AgentResult(json: entry)
    }

    static func list(_ params: AgentParams) throws -> AgentResult {
        let path = try path(params)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        } catch {
            throw AgentError("\(path) cannot be listed: \(reason(error)).")
        }
        let entries: [[String: Any]] = names.map { name in
            var entry = self.entry(path + "/" + name) ?? ["isDirectory": false, "size": 0, "mode": 0]
            entry["name"] = name
            return entry
        }
        return AgentResult(json: ["entries": entries])
    }

    static func makeDirectory(_ params: AgentParams) throws -> AgentResult {
        let path = try path(params)
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw AgentError("\(path) cannot be created: \(reason(error)).")
        }
        return AgentResult()
    }

    static func readFile(_ params: AgentParams) throws -> AgentResult {
        let path = try path(params)
        let offset = try params.integer("offset", default: 0, in: 0...Int.max)
        let length = try params.integer("length", default: maximumRead, in: 0...maximumRead)
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentError("\(path) cannot be read: \(String(cString: strerror(errno))).") }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw AgentError("\(path) cannot be read: it is not a file.")
        }
        var data = Data(count: length)
        var total = 0
        while total < length {
            let count = data.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress!.advanced(by: total), length - total, off_t(offset + total))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentError("\(path) cannot be read: \(String(cString: strerror(errno))).")
            }
            if count == 0 { break }
            total += count
        }
        data.count = total
        let size = Int(status.st_size)
        return AgentResult(json: ["size": size, "eof": offset + total >= size], data: data)
    }

    static func writeFile(_ params: AgentParams, _ data: Data) throws -> AgentResult {
        let path = try path(params)
        let offset = try params.integer("offset", default: 0, in: 0...Int.max)
        let truncate = try params.bool("truncate", default: false)
        let mode = try params.optionalNumber("mode").map { _ in try params.integer("mode", default: 0o644, in: 0...0o7777) }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        } catch {
            throw AgentError("\(path) cannot be written: \(reason(error)).")
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | (truncate ? O_TRUNC : 0), 0o644)
        guard descriptor >= 0 else { throw AgentError("\(path) cannot be written: \(String(cString: strerror(errno))).") }
        defer { close(descriptor) }
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { buffer in
                pwrite(descriptor, buffer.baseAddress!.advanced(by: written), data.count - written, off_t(offset + written))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentError("\(path) cannot be written: \(String(cString: strerror(errno))).")
            }
            written += count
        }
        if let mode, fchmod(descriptor, mode_t(mode)) != 0 {
            throw AgentError("\(path) cannot be written: \(String(cString: strerror(errno))).")
        }
        return AgentResult()
    }
}
