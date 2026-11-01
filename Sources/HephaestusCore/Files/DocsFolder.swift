import Darwin
import Foundation

/// The docs of a docs folder (docs/documentation-viewer.md › Docs folder).
enum DocsFolder {
    /// True for a doc file name: it ends in `.md` or `.markdown`, in any case.
    static func isDocName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasSuffix(".md") || lowercased.hasSuffix(".markdown")
    }

    /// Adds the docs of `folder` and of its sub folders. Names starting with `.` are skipped.
    // DOC-GAP: docs/engine-api.md › docs.list does not say whether symbolic links to folders
    // are followed; they are not, so a link cycle cannot make the listing endless. Symbolic
    // links to files are listed like files.
    static func collect(folder: String, projectPath: String, into entries: inout [DocEntry]) {
        guard let names = try? FileSystemItems.names(in: folder) else { return }
        for name in names where !name.hasPrefix(".") {
            let absolute = folder + "/" + name
            let path = ProjectPaths.join(projectPath, name)
            guard let item = FileItem.at(absolute) else { continue }
            switch item.kind {
            case .directory:
                var link = stat()
                guard lstat(absolute, &link) == 0, link.st_mode & S_IFMT == S_IFDIR else { continue }
                collect(folder: absolute, projectPath: path, into: &entries)
            case .file where isDocName(name):
                entries.append(DocEntry(path: path, title: title(ofFile: absolute, name: name)))
            default:
                continue
            }
        }
    }

    /// The text after `# ` on the first line that starts with `# `, trimmed; without such a
    /// line, the file name without its extension.
    static func title(ofFile absolute: String, name: String) -> String {
        let fallback = (name as NSString).deletingPathExtension
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: absolute), options: .alwaysMapped) else {
            return fallback
        }
        return title(in: data) ?? fallback
    }

    /// The first `# ` heading of a doc's bytes, or nil. A leading byte order mark is skipped;
    /// lines end at LF, with a CR before it removed.
    static func title(in data: Data) -> String? {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var start = 0
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                start = 3
            }
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A {
                    end += 1
                }
                if end - start >= 2, bytes[start] == 0x23, bytes[start + 1] == 0x20 {
                    var lineEnd = end
                    if lineEnd > start + 2, bytes[lineEnd - 1] == 0x0D {
                        lineEnd -= 1
                    }
                    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[(start + 2)..<lineEnd]), as: UTF8.self)
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                start = end + 1
            }
            return nil
        }
    }
}
