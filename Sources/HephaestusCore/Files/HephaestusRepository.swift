import Foundation

/// The app's own repository and the recognition of its clones (docs/projects.md › HephaestusV2
/// project, › Recognition). The URL is hardcoded; the Info.plist key
/// `HephaestusReleaseRepository` belongs to the Updater only.
public enum HephaestusRepository {
    /// The repository URL that the engine clones.
    public static let url = "https://github.com/Azavech/HephaestusV2"
    /// The `<owner>/<repo>` path a remote URL must name.
    public static let path = "Azavech/HephaestusV2"
    /// The identifier reserved for the HephaestusV2 project.
    public static let identifier: ProjectID = "HEPH"
    /// The name of the project.yml the engine creates in its clone.
    public static let name = "HephaestusV2"

    /// True when a remote URL names `Azavech/HephaestusV2`, on any host.
    public static func names(_ remoteURL: String) -> Bool {
        guard let path = repositoryPath(of: remoteURL) else { return false }
        return path.caseInsensitiveCompare(Self.path) == .orderedSame
    }

    /// The path of a remote URL without the leading `/`, a trailing `/` and a trailing `.git`,
    /// whatever its host: `https://`, `http://`, `ssh://` and `git://` URLs, with or without user
    /// info and port, and the scp-like form `[<user>@]<host>:<path>`, whose host may be an SSH
    /// host alias. nil for another form, a local path included.
    public static func repositoryPath(of remoteURL: String) -> String? {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: String
        if let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git"].contains(scheme), let components = URLComponents(string: text),
                  let host = components.host, !host.isEmpty else { return nil }
            path = components.path
        } else {
            // The scp-like form: the part before the first `:` is `[<user>@]<host>` and holds no `/`
            // (git reads a `/` before the colon as a local path).
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let userAndHost = text[..<colon]
            guard !userAndHost.contains("/") else { return nil }
            let host = userAndHost.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
            guard !host.isEmpty else { return nil }
            path = String(text[text.index(after: colon)...])
        }
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        if path.hasSuffix("/") {
            path.removeLast()
        }
        if path.lowercased().hasSuffix(".git") {
            path.removeLast(4)
        }
        return path.isEmpty ? nil : path
    }

    /// True when the origin of the repository that holds `root` names `Azavech/HephaestusV2`.
    static func isClone(root: String) -> Bool {
        GitConfigFile.originURL(root: root).map(names) ?? false
    }
}

/// Reads the `origin` URL of a repository from its configuration file, without running git
/// (docs/projects.md › Recognition).
enum GitConfigFile {
    /// The last `url` of `[remote "origin"]` in the configuration of the repository that holds
    /// `root`: the `.git` folder of `root` or of its nearest parent folder that has one, a `.git`
    /// file (`gitdir: <path>`) and the `commondir` of a linked worktree followed. nil without a
    /// repository, without an origin or when the file cannot be read.
    static func originURL(root: String) -> String? {
        guard let gitDirectory = gitDirectory(containing: root) else { return nil }
        let configDirectory = commonDirectory(of: gitDirectory) ?? gitDirectory
        guard let text = try? String(contentsOfFile: (configDirectory as NSString).appendingPathComponent("config"), encoding: .utf8)
        else { return nil }
        return originURL(inConfig: text)
    }

    /// The git directory of the repository whose work tree holds `path`.
    private static func gitDirectory(containing path: String) -> String? {
        let manager = FileManager.default
        var folder = (path as NSString).standardizingPath
        while true {
            let dotGit = (folder as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return dotGit
                }
                // A worktree or a submodule: `gitdir: <path>`, relative to the folder.
                guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
                let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                return resolved(target, from: folder)
            }
            guard folder != "/" else { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// The folder named by `<gitDirectory>/commondir`, when it exists.
    private static func commonDirectory(of gitDirectory: String) -> String? {
        let file = (gitDirectory as NSString).appendingPathComponent("commondir")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : resolved(target, from: gitDirectory)
    }

    private static func resolved(_ target: String, from folder: String) -> String {
        let path = target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target)
        return (path as NSString).standardizingPath
    }

    /// The last `url` of the section `[remote "origin"]` of a git configuration text. Section
    /// names and keys are compared case-insensitively, the subsection exactly; comments (`#`,
    /// `;`) outside quotes are dropped and a quoted value is unquoted.
    static func originURL(inConfig text: String) -> String? {
        var inOrigin = false
        var url: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = isOriginHeader(line)
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare("url") == .orderedSame else { continue }
            url = value(String(line[line.index(after: equals)...]))
        }
        return url?.isEmpty == false ? url : nil
    }

    /// True for `[remote "origin"]`, spaces allowed around the parts.
    private static func isOriginHeader(_ line: String) -> Bool {
        guard let end = line.firstIndex(of: "]") else { return false }
        let inner = line[line.index(after: line.startIndex)..<end].trimmingCharacters(in: .whitespaces)
        guard let quote = inner.firstIndex(of: "\"") else { return false }
        let section = inner[..<quote].trimmingCharacters(in: .whitespaces)
        let subsection = inner[inner.index(after: quote)...].trimmingCharacters(in: .whitespaces)
        return section.caseInsensitiveCompare("remote") == .orderedSame && subsection == "origin\""
    }

    /// A value with its comment dropped and its quotes and escapes removed, trimmed.
    private static func value(_ raw: String) -> String {
        var result = ""
        var quoted = false
        var escaped = false
        for character in raw {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted, character == "#" || character == ";" {
                break
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
