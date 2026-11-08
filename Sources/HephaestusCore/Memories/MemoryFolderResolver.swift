import Darwin
import Foundation

/// Gives the memory folder of a project root: the folder the Claude CLI uses for the chats that
/// run there (docs/memories.md › Resolution). The engine's configuration holds one, so that tests
/// use temporary folders in place of `~/.claude` (docs/architecture.md › Engine configuration).
public protocol MemoryFolderResolving: Sendable {
    /// The memory folder of `projectRoot`, an absolute path, standardized and without final `/`.
    /// `environment` is the login-shell environment that chat processes get
    /// (docs/chats.md › Environment).
    func memoryFolder(projectRoot: String, environment: [String: String]) -> String

    /// The device's global memories folder, `<config folder>/memory`, absolute, standardized and
    /// without final `/` (docs/memories.md › Global memories).
    func globalMemoryFolder(environment: [String: String]) -> String
}

/// The resolution of the Claude CLI, checked with Claude Code 2.1.309.
public struct ClaudeMemoryFolderResolver: MemoryFolderResolving {
    /// The managed settings file of the CLI on macOS.
    public static let managedSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
    /// The longest folder name the CLI writes before it appends a hash.
    static let maximumFolderNameLength = 200

    /// The home folder: `~/.claude` and the `~/` of `autoMemoryDirectory`.
    public var homeDirectory: String
    /// Replaces the config folder (`CLAUDE_CONFIG_DIR`, `~/.claude`); tests give a temporary
    /// folder.
    public var configDirectory: String?
    /// The managed settings file; nil reads none.
    public var managedSettingsPath: String?

    public init(homeDirectory: String, configDirectory: String? = nil,
                managedSettingsPath: String? = ClaudeMemoryFolderResolver.managedSettingsPath) {
        self.homeDirectory = homeDirectory
        self.configDirectory = configDirectory
        self.managedSettingsPath = managedSettingsPath
    }

    public func memoryFolder(projectRoot: String, environment: [String: String]) -> String {
        // Step 1: the project root with its links resolved, in normalization form C.
        let start = Self.nfc(Self.realPath(projectRoot))
        // Steps 2 and 3: the main working tree of the repository, or the start path.
        let repositoryRoot = Self.repositoryRoot(containing: start)
        let base = repositoryRoot.map { Self.nfc(Self.mainWorkingTree(ofRoot: $0)) } ?? start
        // Step 5: the config folder.
        let config = configFolder(environment: environment, projectRoot: start)
        // Steps 6 and 7.
        if let folder = autoMemoryDirectory(projectRoot: start, mainWorkingTree: repositoryRoot == nil ? nil : base, configFolder: config) {
            return folder
        }
        return Self.nfc(Self.join(config, "projects", Self.folderName(of: base), "memory"))
    }

    /// `<config folder>/memory`. A relative `CLAUDE_CONFIG_DIR` is relative to the home folder, since
    /// the folder belongs to no project root; `autoMemoryDirectory` does not move it.
    public func globalMemoryFolder(environment: [String: String]) -> String {
        let home = Self.standardized(homeDirectory)
        return Self.nfc(Self.standardized(Self.join(configFolder(environment: environment, projectRoot: home), "memory")))
    }

    /// `CLAUDE_CONFIG_DIR` when it is set and not empty, used as written (a relative value is
    /// relative to the project root, the chat's working directory), otherwise `~/.claude`.
    func configFolder(environment: [String: String], projectRoot: String) -> String {
        if let configDirectory {
            return Self.standardized(configDirectory)
        }
        if let value = environment["CLAUDE_CONFIG_DIR"], !value.isEmpty {
            let path = value.hasPrefix("/") ? value : Self.join(projectRoot, value)
            return Self.nfc(Self.standardized(path))
        }
        return Self.nfc(Self.join(homeDirectory, ".claude"))
    }

    // MARK: autoMemoryDirectory (docs/memories.md › Resolution, step 6)

    /// What a settings source holds for `autoMemoryDirectory`.
    enum SettingValue: Equatable {
        /// The source has no value: no file, a file that is not JSON, no key, or a value that is
        /// not a string, which makes the CLI drop the whole file.
        case absent
        case null
        case string(String)
    }

    /// The folder named by the first settings source whose `autoMemoryDirectory` is a string: the
    /// managed settings, the local settings, the project's settings, then the user settings; nil
    /// when none is, or when the CLI refuses the value, which then gives the default folder.
    func autoMemoryDirectory(projectRoot: String, mainWorkingTree: String?, configFolder: String) -> String? {
        let sources = [
            managedValue(),
            localValue(projectRoot: projectRoot, mainWorkingTree: mainWorkingTree),
            Self.settingValue(in: Self.join(projectRoot, ".claude", "settings.json")),
            Self.settingValue(in: Self.join(configFolder, "settings.json")),
        ]
        for case .string(let value) in sources {
            return Self.memoryDirectory(value, homeDirectory: homeDirectory)
        }
        return nil
    }

    /// The managed settings file, then the `.json` files of `managed-settings.d` next to it,
    /// sorted by name, merged in this order: the last file that holds the key gives the value.
    func managedValue() -> SettingValue {
        guard let managedSettingsPath else { return .absent }
        var files = [managedSettingsPath]
        let dropIns = Self.join((managedSettingsPath as NSString).deletingLastPathComponent, "managed-settings.d")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dropIns) {
            files += names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().map { Self.join(dropIns, $0) }
        }
        var value = SettingValue.absent
        for file in files {
            let fileValue = Self.settingValue(in: file)
            if fileValue != .absent {
                value = fileValue
            }
        }
        return value
    }

    /// The local settings `.claude/settings.local.json` of the main working tree, whose keys win
    /// over those of the project root's own file.
    func localValue(projectRoot: String, mainWorkingTree: String?) -> SettingValue {
        let own = Self.settingValue(in: Self.join(projectRoot, ".claude", "settings.local.json"))
        guard let mainWorkingTree, mainWorkingTree != projectRoot else { return own }
        let main = Self.settingValue(in: Self.join(mainWorkingTree, ".claude", "settings.local.json"))
        return main == .absent ? own : main
    }

    /// The `autoMemoryDirectory` of a settings file, read as strict JSON after a leading byte
    /// order mark, as the CLI reads it.
    static func settingValue(in file: String) -> SettingValue {
        guard var data = FileManager.default.contents(atPath: file) else { return .absent }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = data.dropFirst(3)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["autoMemoryDirectory"] else { return .absent }
        if value is NSNull { return .null }
        guard let text = value as? String else { return .absent }
        return .string(text)
    }

    /// The folder of an `autoMemoryDirectory` value, as the CLI accepts it: a `~/` or `~\`
    /// prefix is the home folder, then the path is normalized, its final `/` and `\\` removed, and
    /// checked; nil for a value the CLI refuses.
    static func memoryDirectory(_ text: String, homeDirectory: String) -> String? {
        guard !text.isEmpty else { return nil }
        var path = text
        if text.hasPrefix("~/") || text.hasPrefix("~\\") {
            let rest = String(text.dropFirst(2))
            let normalized = normalize(rest.isEmpty ? "." : rest)
            if normalized == "." || normalized == ".." || normalized.hasPrefix("../") || normalized.hasPrefix("..\\") {
                return nil
            }
            path = normalize(homeDirectory + "/" + rest)
        }
        var folder = normalize(path)
        while let last = folder.last, last == "/" || last == "\\" {
            folder.removeLast()
        }
        guard folder.hasPrefix("/"), folder.utf16.count >= 3, !folder.contains("\0"), !isSpecialPath(folder) else {
            return nil
        }
        return nfc(folder)
    }

    /// The paths the CLI refuses because they could reach a network mount: two leading
    /// separators or a `/??/` device path, `/net/<host>` and `/Network/Servers/<name>`, any path
    /// under `/Network`, and the folders `/.vol`, `/.file`, `/.nofollow` and `/.resolve`.
    static func isSpecialPath(_ path: String) -> Bool {
        if path.range(of: #"^[\\/]{2}"#, options: .regularExpression) != nil
            || path.range(of: #"^[\\/]\?\?[\\/]"#, options: .regularExpression) != nil {
            return true
        }
        guard path.hasPrefix("/") else { return false }
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
            let first = automountName(components[0])
            if components.count == 2, first == "net" { return true }
            if components.count == 3, first == "network", automountName(components[1]) == "servers" { return true }
            if components.count == 1 {
                if components[0].lowercased() == "network" { return true }
                if components[0].range(of: #"^\.(vol|file|nofollow|resolve)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// A component without the invisible format characters the CLI drops, in lowercase.
    private static func automountName(_ component: String) -> String {
        String(component.unicodeScalars.filter { scalar in
            !((0x200C...0x200F).contains(scalar.value) || (0x202A...0x202E).contains(scalar.value)
                || (0x206A...0x206F).contains(scalar.value) || scalar.value == 0xFEFF)
        }).lowercased()
    }

    // MARK: Repository (steps 2 and 3)

    /// The first folder, from `path` up to `/`, that holds a `.git` folder or file.
    static func repositoryRoot(containing path: String) -> String? {
        var folder = path
        while true {
            if isFolderOrFile(join(folder, ".git")) {
                return folder
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != folder else { return nil }
            folder = parent
        }
    }

    /// The main working tree of a linked worktree whose `.git` file points to
    /// `<common>/worktrees/<name>` with a `commondir` file and a `gitdir` file pointing back;
    /// the root itself in every other case (a `.git` folder, a submodule, a broken link).
    static func mainWorkingTree(ofRoot root: String) -> String {
        // `.git` is read through a symbolic link; `commondir` and `gitdir` are not.
        guard let content = textOfRegularFile(join(root, ".git"), followingLinks: true) else { return root }
        let line = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir:") else { return root }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return root }
        let gitFolder = resolve(target, from: root)
        guard let commonText = textOfRegularFile(join(gitFolder, "commondir"))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !commonText.isEmpty else { return root }
        let common = resolve(commonText, from: gitFolder)
        guard (gitFolder as NSString).deletingLastPathComponent == join(common, "worktrees") else { return root }
        guard let backText = textOfRegularFile(join(gitFolder, "gitdir"))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !backText.isEmpty else { return root }
        // As the CLI: paths with a backslash, and git files that lead to a network path, are not
        // followed.
        guard ![root, gitFolder, backText, common].contains(where: { $0.contains("\\") }),
              ![gitFolder, common, resolve(backText, from: gitFolder)].contains(where: isSpecialPath) else { return root }
        guard realPath(resolve(backText, from: gitFolder)) == join(realPath(root), ".git") else { return root }
        if (common as NSString).lastPathComponent != ".git" {
            // A bare repository: the common folder itself, unless it holds a `.git`.
            return isFolderOrFile(join(common, ".git")) ? root : common
        }
        return (common as NSString).deletingLastPathComponent
    }

    // MARK: Folder name (step 4)

    /// Every UTF-16 code unit other than an ASCII letter or digit replaced with `-`; a name longer
    /// than 200 units keeps its first 200, then `-` and the base-36 absolute value of the Java
    /// `String.hashCode` of the path.
    public static func folderName(of path: String) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(path.utf16.count)
        for unit in path.utf16 {
            let isLetterOrDigit = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            units.append(isLetterOrDigit ? unit : 0x2D)
        }
        let name = String(decoding: units, as: UTF16.self)
        guard units.count > maximumFolderNameLength else { return name }
        let hash = abs(Int64(javaHashCode(path)))
        return String(decoding: units.prefix(maximumFolderNameLength), as: UTF16.self) + "-" + String(hash, radix: 36)
    }

    /// Java's `String.hashCode`: `h = 31 * h + unit` over the UTF-16 code units, in 32 bits.
    static func javaHashCode(_ text: String) -> Int32 {
        var hash: Int32 = 0
        for unit in text.utf16 {
            hash = (hash &<< 5) &- hash &+ Int32(unit)
        }
        return hash
    }

    // MARK: Paths

    /// The path with its symbolic links resolved by `realpath(3)`; the deepest existing ancestor
    /// is resolved and the missing components follow unchanged.
    static func realPath(_ path: String) -> String {
        var existing = standardized(path)
        var missing: [String] = []
        while true {
            if let real = realpath(existing, nil) {
                defer { free(real) }
                return missing.reversed().reduce(String(cString: real)) { ($0 as NSString).appendingPathComponent($1) }
            }
            let parent = (existing as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != existing else { return standardized(path) }
            missing.append((existing as NSString).lastPathComponent)
            existing = parent
        }
    }

    /// The path with `.` and `..` resolved, repeated `/` merged and the final `/` removed, as
    /// Node's `path.resolve` does; unlike `NSString.standardizingPath`, `/private` stays.
    static func standardized(_ path: String) -> String {
        var result = normalize(path)
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// `path.normalize` of Node.js for an absolute or relative path: `.` and `..` resolved
    /// lexically, repeated `/` merged.
    static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !isAbsolute {
                    parts.append(component)
                }
                continue
            }
            parts.append(component)
        }
        let joined = parts.joined(separator: "/")
        let trailing = path.hasSuffix("/") ? "/" : ""
        if isAbsolute {
            return "/" + joined + (joined.isEmpty ? "" : trailing)
        }
        return joined.isEmpty ? "." + trailing : joined + trailing
    }

    static func join(_ base: String, _ components: String...) -> String {
        components.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func resolve(_ target: String, from folder: String) -> String {
        standardized(target.hasPrefix("/") ? target : join(folder, target))
    }

    static func nfc(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    /// A folder or a file, symbolic links followed.
    static func isFolderOrFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        let kind = info.st_mode & S_IFMT
        return kind == S_IFDIR || kind == S_IFREG
    }

    /// The text of a regular file; nil for anything else, a symbolic link included unless
    /// `followingLinks` is true.
    static func textOfRegularFile(_ path: String, followingLinks: Bool = false) -> String? {
        var info = stat()
        let status = followingLinks ? stat(path, &info) : lstat(path, &info)
        guard status == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
