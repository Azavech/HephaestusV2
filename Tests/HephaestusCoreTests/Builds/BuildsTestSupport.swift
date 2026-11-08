import Foundation
import Testing
@testable import HephaestusCore

/// The output of a gh capture of `Fixtures/gh/` (docs/development.md › gh captures).
func ghFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/gh"))
    return try Data(contentsOf: url)
}

/// A gh that never reaches GitHub: it records every run and answers with the outcome that
/// `answer` gives for the run's arguments; `download` runs before the answer of
/// `gh release download`, to write the asset into the `--dir` folder as gh does.
final class FakeGitHubCLI: GitHubCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GitHubCLIRun] = []
    private let answer: @Sendable (GitHubCLIRun) -> GitHubCLIOutcome
    private let download: (@Sendable (GitHubCLIRun) -> Void)?

    init(download: (@Sendable (GitHubCLIRun) -> Void)? = nil, answer: @escaping @Sendable (GitHubCLIRun) -> GitHubCLIOutcome) {
        self.answer = answer
        self.download = download
    }

    /// Answers every run with the output `data` and the exit status 0.
    convenience init(output data: Data) {
        self.init { _ in .finished(.ghResult(output: data)) }
    }

    var runs: [GitHubCLIRun] {
        lock.withLock { recorded }
    }

    func run(_ run: GitHubCLIRun, started: @escaping @Sendable (ChildProcess) -> Void) async -> GitHubCLIOutcome {
        lock.withLock { recorded.append(run) }
        if run.arguments.starts(with: ["release", "download"]) {
            download?(run)
        }
        return answer(run)
    }
}

extension ProcessResult {
    /// The result of a gh run: its exit status, standard output and standard error.
    static func ghResult(status: Int32 = 0, output: Data = Data(), error: String = "", timedOut: Bool = false) -> ProcessResult {
        ProcessResult(termination: .exited(status), standardOutput: output, standardError: Data(error.utf8), timedOut: timedOut)
    }
}

extension GitHubCLIRun {
    /// The value of an option written `--<name>=<value>`.
    func option(_ name: String) -> String? {
        let prefix = "--\(name)="
        return arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

/// `NoClaudeLauncher` whose captured login-shell environment also holds variables that gh must
/// not get: a `HEPHAESTUS_*` variable and those that change the output of gh.
struct GitHubProbeLauncher: ClaudeProcessLauncher {
    func captureEnvironment(processEnvironment: [String: String], log: LogSink?) async -> [String: String] {
        processEnvironment.merging(["HEPHAESTUS_PROBE": "1", "CLICOLOR_FORCE": "1", "GH_FORCE_TTY": "1", "GH_DEBUG": "api",
                                    "DEBUG": "1"]) { _, probe in probe }
    }
}

extension Engine {
    /// Turns the quarantine attributes of saved release assets off, so that a test adds nothing to
    /// the quarantine events of the user running it.
    func useReleaseQuarantine(_ on: Bool) {
        quarantinesReleaseDownloads = on
    }
}

/// The project `BLD` at `<temp>/Project`, with the GitHub page `https://github.com/example/name`
/// unless `page` is nil.
func createBuildsProject(_ connection: LocalEngineConnection, in folder: URL,
                         page: String? = "https://github.com/example/name") async throws -> URL {
    let root = folder.appendingPathComponent("Project", isDirectory: true)
    _ = try await connection.call(ProjectsCreate.self, .init(rootPath: root.path, name: "Builds", identifier: "BLD",
                                                             createDirectory: true))
    if let page {
        _ = try await connection.call(ProjectsUpdate.self, .init(projectID: "BLD", githubPage: .set(page)))
    }
    return root
}
