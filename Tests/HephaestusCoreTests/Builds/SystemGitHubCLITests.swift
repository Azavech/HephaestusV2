import Foundation
import Testing
@testable import HephaestusCore

/// docs/builds.md › gh calls, Lookup and Process: the system gh is the first `gh` of the `PATH`
/// of the run's environment, looked up at every run. A shell script stands for gh.
@Suite("System GitHub CLI")
struct SystemGitHubCLITests {
    private func run(in folder: URL, arguments: [String] = ["run", "list"], timeout: Duration = .seconds(60),
                     environment: [String: String] = [:]) async -> GitHubCLIOutcome {
        var environment = environment
        environment["PATH"] = environment["PATH"] ?? "/nonexistent:" + folder.appendingPathComponent("bin").path + ":/usr/bin:/bin"
        let request = GitHubCLIRun(arguments: arguments, environment: environment, directory: folder.path, timeout: timeout)
        return await SystemGitHubCLI().run(request) { _ in }
    }

    @Test("gh is looked up at every run: missing, then found once it is installed")
    func lookupAtEveryRun() async throws {
        try await withTemporaryDirectory { folder in
            guard case .notFound = await run(in: folder) else {
                Issue.record("gh was found before it existed")
                return
            }
            try writeScript(folder.appendingPathComponent("bin/gh"), #"printf '[]'"#)
            guard case .finished(let result) = await run(in: folder) else {
                Issue.record("gh was not found once installed")
                return
            }
            #expect(result.termination == .exited(0))
            #expect(result.standardOutputText == "[]")
        }
    }

    @Test("gh gets the arguments, the environment and the working directory of the run")
    func argumentsEnvironmentAndDirectory() async throws {
        try await withTemporaryDirectory { folder in
            try writeScript(folder.appendingPathComponent("bin/gh"), """
            for argument in "$@"; do printf '%s\\n' "$argument"; done
            printf 'pwd=%s\\n' "$(pwd -P)"
            printf 'prompt=%s\\n' "$GH_PROMPT_DISABLED"
            printf 'error\\n' >&2
            exit 3
            """)
            let outcome = await run(in: folder, arguments: ["release", "view", "--json=body", "--", "-v1 beta"],
                                    environment: ["GH_PROMPT_DISABLED": "1"])
            guard case .finished(let result) = outcome else {
                Issue.record("gh did not run")
                return
            }
            let real = try #require(realpath(folder.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            })
            #expect(result.standardOutputText == "release\nview\n--json=body\n--\n-v1 beta\npwd=\(real)\nprompt=1\n")
            #expect(result.standardErrorText == "error\n")
            #expect(result.termination == .exited(3))
        }
    }

    @Test("A gh that outlasts its timeout is ended")
    func timeout() async throws {
        try await withTemporaryDirectory { folder in
            try writeScript(folder.appendingPathComponent("bin/gh"), "exec sleep 600")
            guard case .finished(let result) = await run(in: folder, timeout: .seconds(1)) else {
                Issue.record("gh did not run")
                return
            }
            #expect(result.timedOut)
        }
    }
}
