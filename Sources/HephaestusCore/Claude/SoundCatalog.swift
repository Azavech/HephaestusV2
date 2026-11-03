import Darwin
import Foundation

/// The sound catalogue of a project on the main device and its search (docs/chats.md › Sound
/// catalogue, › Sound search): the macOS sounds, the sounds of the installed Simulator runtimes
/// and the sound files of the project. The engine checks the suggestions of `chats.postSound`
/// with it and answers `sounds.list` and `sounds.read` from it.
public struct SoundCatalog: Sendable {
    /// The extensions of a sound file, lowercased.
    public static let extensions: Set<String> = ["caf", "aiff", "wav", "mp3"]
    /// The source of the macOS sounds.
    public static let macOSSource = "macOS"
    /// The source of the project's sound files.
    public static let projectSource = "Project"
    /// The folder of the macOS sounds.
    public static let macOSFolder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    /// The folder of a Simulator runtime's sounds, relative to its root.
    public static let runtimeSoundsFolder = "System/Library/Audio/UISounds"
    /// Timeout of `xcrun simctl list runtimes --json` (docs/architecture.md › Child processes).
    static let simctlTimeout: Duration = .seconds(30)

    /// An installed Simulator runtime: its name, `<platform> <version>`, and its root folder.
    public struct Runtime: Sendable, Hashable {
        public var name: String
        public var root: URL

        public init(name: String, root: URL) {
            self.name = name
            self.root = root
        }
    }

    /// The macOS and Simulator runtime sounds, read once (docs/chats.md › Sound catalogue).
    public struct SystemSounds: Sendable {
        /// The names in catalogue order: the macOS sounds, then each runtime's sounds.
        public let names: [String]
        /// The file of each name.
        public let files: [String: URL]
        /// What could not be read, for `engine.log`; empty when everything was read.
        public let problems: [String]

        public static let none = SystemSounds(names: [], files: [:], problems: [])

        init(names: [String], files: [String: URL], problems: [String]) {
            self.names = names
            self.files = files
            self.problems = problems
        }

        /// The sounds of `macOSFolder` and of the runtimes, in the order of their names; a runtime
        /// whose name was already read is skipped.
        public static func read(macOSFolder: URL, runtimes: [Runtime], problems: [String] = []) -> SystemSounds {
            var names: [String] = []
            var files: [String: URL] = [:]
            func add(source: String, paths: [String], folder: URL) {
                for path in paths {
                    let name = "\(source)/\(path)"
                    guard files[name] == nil else { continue }
                    names.append(name)
                    files[name] = folder.appendingPathComponent(path)
                }
            }
            add(source: SoundCatalog.macOSSource, paths: SoundCatalog.soundFiles(in: macOSFolder, recursive: false), folder: macOSFolder)
            var seen = Set<String>()
            var ordered: [Runtime] = []
            for runtime in runtimes where seen.insert(runtime.name).inserted {
                ordered.append(runtime)
            }
            ordered.sort { SoundCatalog.finderOrder($0.name, $1.name) }
            for runtime in ordered {
                let folder = runtime.root.appendingPathComponent(SoundCatalog.runtimeSoundsFolder, isDirectory: true)
                add(source: runtime.name, paths: SoundCatalog.soundFiles(in: folder, recursive: true), folder: folder)
            }
            return SystemSounds(names: names, files: files, problems: problems)
        }

        /// The sounds of this Mac: `/System/Library/Sounds` and the runtimes that
        /// `xcrun simctl list runtimes --json` lists, run with `environment` (timeout 30 s).
        public static func load(environment: [String: String], xcrun: String = "/usr/bin/xcrun") async -> SystemSounds {
            var problems: [String] = []
            var runtimes: [Runtime] = []
            let request = ChildProcessRequest(executable: xcrun, arguments: ["simctl", "list", "runtimes", "--json"],
                                              environment: ProcessEnvironment.withoutHephaestusVariables(environment))
            do {
                let result = try await ChildProcessRunner.run(request, timeout: SoundCatalog.simctlTimeout)
                if result.timedOut {
                    problems.append("xcrun simctl list runtimes timed out")
                } else if !result.termination.isSuccess {
                    problems.append("xcrun simctl list runtimes failed: \(result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))")
                } else if let listed = SoundCatalog.runtimes(fromSimctlJSON: result.standardOutput) {
                    runtimes = listed
                } else {
                    problems.append("xcrun simctl list runtimes printed no readable JSON")
                }
            } catch {
                problems.append("xcrun cannot be started: \(error.localizedDescription)")
            }
            return read(macOSFolder: SoundCatalog.macOSFolder, runtimes: runtimes, problems: problems)
        }
    }

    public let system: SystemSounds
    /// The project's sound files, as project paths, in Finder order.
    public let projectPaths: [String]
    /// The project's root folder on the main device.
    public let projectRoot: URL
    private let projectSet: Set<String>

    public init(system: SystemSounds, projectRoot: URL, projectPaths: [String]) {
        self.system = system
        self.projectRoot = projectRoot
        let paths = projectPaths.filter { Self.isSoundFile($0) && Self.canBeMarked("\(Self.projectSource)/\($0)") }
            .sorted(by: Self.finderOrder)
        self.projectPaths = paths
        projectSet = Set(paths)
    }

    /// Every name, in catalogue order: the macOS sounds, each runtime's sounds, then the
    /// project's sounds.
    public var names: [String] {
        system.names + projectPaths.map { "\(Self.projectSource)/\($0)" }
    }

    public func contains(_ name: String) -> Bool {
        file(for: name) != nil
    }

    /// The file of a sound of the catalogue; nil for another name.
    public func file(for name: String) -> URL? {
        if let file = system.files[name] { return file }
        let prefix = Self.projectSource + "/"
        guard name.hasPrefix(prefix) else { return nil }
        let path = String(name.dropFirst(prefix.count))
        guard projectSet.contains(path) else { return nil }
        return projectRoot.appendingPathComponent(path)
    }

    // MARK: Names

    /// The source of a name, the part before its first `/`: `macOS`, a runtime's name or `Project`.
    public static func source(of name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[..<slash])
    }

    /// The file of a name, the part after its first `/`.
    public static func file(of name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// A path whose extension is `.caf`, `.aiff`, `.wav` or `.mp3`, in any letter case.
    public static func isSoundFile(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// A name that a sound marker can carry: no line break, balanced parentheses, and no white
    /// space at either end.
    public static func canBeMarked(_ name: String) -> Bool {
        guard let first = name.first, let last = name.last, !first.isWhitespace, !last.isWhitespace,
              !name.contains(where: \.isNewline) else { return false }
        var depth = 0
        for character in name {
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    /// Finder order (`localizedStandardCompare`).
    static func finderOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    // MARK: Search (docs/chats.md › Sound search)

    /// The names that contain every word of the trimmed, lowercased query, in the order of
    /// `names`, without `excluded`; nothing for an empty query.
    public static func search(_ query: String, in names: [String], excluding excluded: Set<String> = []) -> [String] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return names.filter { name in
            guard !excluded.contains(name) else { return false }
            let lowercased = name.lowercased()
            return words.allSatisfy { lowercased.contains($0) }
        }
    }

    // MARK: Reading

    /// The sound files of a folder, as paths relative to it, in Finder order: regular files with
    /// a sound extension, names starting with `.` and symbolic links skipped; at any depth when
    /// `recursive`.
    static func soundFiles(in folder: URL, recursive: Bool) -> [String] {
        var paths: [String] = []
        func visit(_ directory: URL, prefix: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let url = directory.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    if isSoundFile(name) { paths.append(path) }
                case S_IFDIR:
                    if recursive { visit(url, prefix: path) }
                default:
                    continue
                }
            }
        }
        visit(folder, prefix: "")
        return paths.filter { canBeMarked("x/\($0)") }.sorted(by: finderOrder)
    }

    /// The runtimes of the output of `xcrun simctl list runtimes --json`: the `name` and the
    /// `runtimeRoot` of each entry of `runtimes`, in the order listed; nil for output that is
    /// not that JSON.
    static func runtimes(fromSimctlJSON data: Data) -> [Runtime]? {
        struct Output: Decodable {
            struct Entry: Decodable {
                var name: String?
                var runtimeRoot: String?
            }
            var runtimes: [Entry]
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else { return nil }
        return output.runtimes.compactMap { entry in
            guard let name = entry.name, !name.isEmpty, !name.contains("/"), let root = entry.runtimeRoot, root.hasPrefix("/") else {
                return nil
            }
            return Runtime(name: name, root: URL(fileURLWithPath: root, isDirectory: true))
        }
    }
}
