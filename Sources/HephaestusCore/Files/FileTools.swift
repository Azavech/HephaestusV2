import Darwin
import Foundation

/// The tools the files use on the main device: `git` for `FileEntry.isIgnored`, `gofmt` and
/// `swift-format` for format on save (docs/architecture.md › Child processes, rule 5), with the
/// environment the engine gives every child process.
struct FileTools: Sendable, Equatable {
    /// The login-shell environment captured at launch, without any `HEPHAESTUS_*` variable.
    var environment: [String: String]
    var git: String?
    var gofmt: String?
    var swiftFormat: String?

    init(environment: [String: String], git: String? = nil, gofmt: String? = nil, swiftFormat: String? = nil) {
        self.environment = ProcessEnvironment.withoutHephaestusVariables(environment)
        self.git = git
        self.gofmt = gofmt
        self.swiftFormat = swiftFormat
    }

    /// Before the lookup has run, no tool is known: nothing is formatted and `isIgnored` is
    /// absent, as when the tools are not found (docs/architecture.md › Child processes, rule 5).
    static let notLookedUp = FileTools(environment: [:])

    /// Timeout of `xcrun --find swift-format` and of `xcode-select -p`.
    static let lookupTimeout: Duration = .seconds(10)

    /// docs/architecture.md › Child processes, rule 5: the first executable file of each name in
    /// the `PATH` of `environment`; for `swift-format`, when `PATH` has none, the output of
    /// `/usr/bin/xcrun --find swift-format` (timeout 10 s). `git` is not used when it resolves to
    /// `/usr/bin/git` and `/usr/bin/xcode-select -p` exits with a non-zero status.
    static func lookUp(environment: [String: String], log: LogSink? = nil,
                       xcrun: String = "/usr/bin/xcrun", xcodeSelect: String = "/usr/bin/xcode-select") async -> FileTools {
        let childEnvironment = ProcessEnvironment.withoutHephaestusVariables(environment)
        let path = environment["PATH"]
        var git = executable(named: "git", inPATH: path)
        if git == "/usr/bin/git" {
            // docs/architecture.md › Child processes, rule 5 (timeout 10 s)
            let request = ChildProcessRequest(executable: xcodeSelect, arguments: ["-p"], environment: childEnvironment)
            let result = try? await ChildProcessRunner.run(request, timeout: lookupTimeout)
            if result == nil || result?.timedOut == true || result?.termination.isSuccess != true {
                git = nil
            }
        }
        let gofmt = executable(named: "gofmt", inPATH: path)
        var swiftFormat = executable(named: "swift-format", inPATH: path)
        if swiftFormat == nil {
            let request = ChildProcessRequest(executable: xcrun, arguments: ["--find", "swift-format"], environment: childEnvironment)
            if let result = try? await ChildProcessRunner.run(request, timeout: lookupTimeout),
               !result.timedOut, result.termination.isSuccess {
                let candidate = result.standardOutputText
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { !$0.isEmpty }
                if let candidate, candidate.hasPrefix("/"), isExecutableFile(candidate) {
                    swiftFormat = candidate
                }
            }
        }
        log?.info(.files, "tools: git \(git ?? "not found"), gofmt \(gofmt ?? "not found"), swift-format \(swiftFormat ?? "not found")")
        return FileTools(environment: environment, git: git, gofmt: gofmt, swiftFormat: swiftFormat)
    }

    /// The first executable file named `name` in the directories of a `PATH` value. Relative
    /// and empty entries are skipped.
    static func executable(named name: String, inPATH path: String?) -> String? {
        guard let path else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) where directory.hasPrefix("/") {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// True for a regular file (links followed) that the process may execute.
    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    // MARK: Format on save

    /// The formatter of a file, from its extension (compared case-insensitively, as language
    /// detection does in docs/code-editor.md › Language detection) and the settings: the
    /// executable and its arguments, or nil when the file is not formatted.
    func formatter(forFile absolutePath: String, settings: HostSettings) -> (executable: String, arguments: [String])? {
        let fileExtension = (absolutePath as NSString).pathExtension.lowercased()
        if fileExtension == "go", settings.formatGoOnSave, let gofmt {
            return (gofmt, [])
        }
        if fileExtension == "swift", settings.formatSwiftOnSave, let swiftFormat {
            return (swiftFormat, ["format", "--assume-filename", absolutePath])
        }
        return nil
    }

    /// docs/engine-api.md › files.write, step 2: pipes `text` through the formatter with the
    /// file's folder as working directory. A non-zero exit, a run longer than `timeout`, a
    /// failure to start or an output that is not UTF-8 gives nil: the text is written
    /// unformatted.
    func format(_ text: String, with formatter: (executable: String, arguments: [String]), folder: String,
                timeout: Duration, log: LogSink?) async -> String? {
        let request = ChildProcessRequest(executable: formatter.executable, arguments: formatter.arguments,
                                          environment: environment, currentDirectory: folder)
        let name = (formatter.executable as NSString).lastPathComponent
        let result: ProcessResult
        do {
            result = try await ChildProcessRunner.run(request, input: Data(text.utf8), timeout: timeout)
        } catch {
            log?.warn(.files, "\(name) could not start: \(error)")
            return nil
        }
        guard !result.timedOut else {
            log?.warn(.files, "\(name) ran longer than \(timeout); the file is written unformatted")
            return nil
        }
        guard result.termination.isSuccess else {
            log?.info(.files, "\(name) failed (\(result.termination)); the file is written unformatted")
            return nil
        }
        // An output that is not valid UTF-8 is not used (docs/engine-api.md › files.write, step 2).
        guard let formatted = String(validating: result.standardOutput, as: UTF8.self) else {
            log?.warn(.files, "\(name) wrote output that is not UTF-8; the file is written unformatted")
            return nil
        }
        return formatted
    }

    // MARK: git check-ignore

    /// Timeout of `git check-ignore`; a timed-out run leaves `isIgnored` absent
    /// (docs/engine-api.md › FileEntry).
    static let checkIgnoreTimeout: Duration = .seconds(10)

    /// The names of `folder` that git ignores (`git check-ignore -z --stdin`, run in `folder`,
    /// directories sent with a trailing `/`), or nil when git is not available, `folder` is not
    /// in a git work tree, or the command fails.
    func ignoredNames(in folder: String, names: [(name: String, isDirectory: Bool)]) async -> Set<String>? {
        guard let git, !names.isEmpty else { return nil }
        var input = Data()
        var nameOfQuery: [String: String] = [:]
        for entry in names {
            let query = entry.isDirectory ? entry.name + "/" : entry.name
            nameOfQuery[query] = entry.name
            input.append(Data(query.utf8))
            input.append(0)
        }
        let request = ChildProcessRequest(executable: git, arguments: ["check-ignore", "-z", "--stdin"],
                                          environment: environment, currentDirectory: folder)
        guard let result = try? await ChildProcessRunner.run(request, input: input, timeout: Self.checkIgnoreTimeout),
              !result.timedOut,
              result.termination == .exited(0) || result.termination == .exited(1)
        else { return nil }
        var ignored: Set<String> = []
        for part in result.standardOutput.split(separator: 0, omittingEmptySubsequences: true) {
            let query = String(decoding: part, as: UTF8.self)
            if let name = nameOfQuery[query] {
                ignored.insert(name)
            }
        }
        return ignored
    }
}
