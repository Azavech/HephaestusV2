import Darwin
import Foundation

/// What a path of the file system holds, read with `stat` (links followed) and `lstat`.
struct FileItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        case directory
        /// A FIFO, socket or device: listed as a file, never read.
        case special
        /// A symbolic link whose target does not exist.
        case brokenLink
    }

    var kind: Kind
    /// Size in bytes; 0 for a directory and a broken link.
    var size: Int
    /// Modification time in whole milliseconds since 1970 (truncated).
    var modifiedMilliseconds: Int64
    /// Device and inode of the item itself (not followed), to recognize the same item.
    var device: Int32
    var inode: UInt64

    var isDirectory: Bool { kind == .directory }

    /// The modification date with millisecond precision (docs/engine-api.md › FileEntry).
    var modified: Date { Date(timeIntervalSince1970: Double(modifiedMilliseconds) / 1000) }

    /// The item at `path`, or nil when nothing exists there (not even a broken link). A
    /// symbolic link is described by its target; a broken link is a file of size 0 with the
    /// link's own modification date (docs/engine-api.md › files.list).
    static func at(_ path: String) -> FileItem? {
        var link = stat()
        guard lstat(path, &link) == 0 else { return nil }
        var target = stat()
        guard stat(path, &target) == 0 else {
            return FileItem(kind: .brokenLink, size: 0, modifiedMilliseconds: milliseconds(link.st_mtimespec),
                            device: link.st_dev, inode: link.st_ino)
        }
        let type = target.st_mode & S_IFMT
        let kind: Kind = type == S_IFDIR ? .directory : (type == S_IFREG ? .file : .special)
        return FileItem(kind: kind, size: kind == .directory ? 0 : Int(target.st_size),
                        modifiedMilliseconds: milliseconds(target.st_mtimespec), device: link.st_dev, inode: link.st_ino)
    }

    /// `expectedModified` compared with a modification date truncated to milliseconds: the
    /// date decoded from the API is rounded to the nearest millisecond first.
    static func milliseconds(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func milliseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
    }
}

/// Reading and listing for `files.*`, `docs.list` and `fs.browse`.
enum FileSystemItems {
    /// docs/engine-api.md › Limits: content returned by files.read.
    static let maximumContentSize = 20 * 1024 * 1024
    /// docs/engine-api.md › Limits: entries returned by files.list.
    static let maximumListedEntries = 10_000
    /// Names files.list never returns (docs/engine-api.md › files.list).
    static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    /// Finder order: `localizedStandardCompare`.
    static func finderOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    /// The names inside a directory, unsorted.
    static func names(in directory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory)
    }

    /// The content of a file for `FileContent`: `text` when the bytes are valid UTF-8 without
    /// NUL bytes, `dataBase64` otherwise, neither when the file is larger than 20 MiB.
    static func content(of url: URL, size: Int) throws -> (text: String?, dataBase64: String?) {
        guard size <= maximumContentSize else { return (nil, nil) }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumContentSize else { return (nil, nil) }
        return content(of: data)
    }

    /// `text` or `dataBase64` for bytes already read.
    static func content(of data: Data) -> (text: String?, dataBase64: String?) {
        if !data.contains(0), let text = String(validating: data, as: UTF8.self) {
            return (text, nil)
        }
        return (nil, data.base64EncodedString())
    }

    /// Absolute paths (docs/engine-api.md › Paths): `.` components removed, `..` resolved,
    /// repeated and trailing `/` removed; symbolic links are not resolved. Nil when `path` does
    /// not start with `/`.
    static func standardizedAbsolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The path of `path` with every symbolic link resolved (`realpath`), for the longest part
    /// that exists; the rest is appended as given. FSEvents reports resolved paths.
    static func resolvedPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty else { return path }
        let resolvedParent = resolvedPath(parent)
        return (resolvedParent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
