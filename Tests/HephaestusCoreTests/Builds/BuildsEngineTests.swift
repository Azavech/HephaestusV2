import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › Builds and docs/builds.md › gh calls, › Failures, › Downloads, through
/// `LocalEngineConnection`, with a fake gh that never reaches GitHub.
@Suite("Builds methods")
struct BuildsEngineTests {
    @Test("builds.listRuns runs gh run list on the repository of the GitHub page, in the project root")
    func listRuns() async throws {
        let gh = FakeGitHubCLI(output: try ghFixture("run-list"))
        try await withTestEngine(githubCLI: gh, claudeLauncher: GitHubProbeLauncher()) { _, connection, folder in
            let root = try await createBuildsProject(connection, in: folder)
            let runs = try await connection.call(BuildsListRuns.self, .init(projectID: "bld"))
            #expect(runs.map(\.id) == [42415910670, 42408559069, 42396389751])
            let run = try #require(gh.runs.first)
            #expect(gh.runs.count == 1)
            #expect(run.arguments == ["run", "list", "--repo=github.com/example/name", "--limit=50",
                                      "--json=conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,startedAt,status,updatedAt,workflowName"])
            #expect(URL(fileURLWithPath: run.directory).standardizedFileURL == root.standardizedFileURL)
            #expect(run.timeout == .seconds(30))
            #expect(run.environment["GH_PROMPT_DISABLED"] == "1")
            #expect(run.environment["GH_NO_UPDATE_NOTIFIER"] == "1")
            #expect(!run.environment.keys.contains { $0.hasPrefix("HEPHAESTUS_") })
            for name in ["CLICOLOR_FORCE", "GH_FORCE_TTY", "GH_DEBUG", "DEBUG"] {
                #expect(run.environment[name] == nil, "\(name)")
            }
        }
    }

    @Test("builds.getRun, builds.rerunRun and builds.cancelRun pass the run id after --")
    func runCommands() async throws {
        let view = try ghFixture("run-view")
        let gh = FakeGitHubCLI { run in
            .finished(.ghResult(output: run.arguments.starts(with: ["run", "view"]) ? view : Data()))
        }
        try await withTestEngine(githubCLI: gh) { _, connection, folder in
            _ = try await createBuildsProject(connection, in: folder)
            let run = try await connection.call(BuildsGetRun.self, .init(projectID: "BLD", runID: 42415910670))
            #expect(run.jobs?.first?.steps.count == 16)
            _ = try await connection.call(BuildsRerunRun.self, .init(projectID: "BLD", runID: 12))
            _ = try await connection.call(BuildsRerunRun.self, .init(projectID: "BLD", runID: 12, failedOnly: true))
            _ = try await connection.call(BuildsCancelRun.self, .init(projectID: "BLD", runID: 13))
            #expect(gh.runs.map(\.arguments) == [
                ["run", "view", "--repo=github.com/example/name",
                 "--json=conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,jobs,startedAt,status,updatedAt,workflowName",
                 "--", "42415910670"],
                ["run", "rerun", "--repo=github.com/example/name", "--", "12"],
                ["run", "rerun", "--repo=github.com/example/name", "--failed", "--", "12"],
                ["run", "cancel", "--repo=github.com/example/name", "--", "13"],
            ])
        }
    }

    @Test("builds.listReleases leaves the drafts out and builds.getRelease passes the tag after --")
    func releases() async throws {
        let list = try ghFixture("release-list")
        let view = try ghFixture("release-view")
        let gh = FakeGitHubCLI { run in
            .finished(.ghResult(output: run.arguments.starts(with: ["release", "list"]) ? list : view))
        }
        try await withTestEngine(githubCLI: gh) { _, connection, folder in
            _ = try await createBuildsProject(connection, in: folder)
            let releases = try await connection.call(BuildsListReleases.self, .init(projectID: "BLD"))
            #expect(releases.first?.isLatest == true)
            let release = try await connection.call(BuildsGetRelease.self, .init(projectID: "BLD", tag: "-v0.41.0"))
            #expect(release.assets.count == 2)
            #expect(gh.runs.map(\.arguments) == [
                ["release", "list", "--repo=github.com/example/name", "--limit=50", "--exclude-drafts",
                 "--json=createdAt,isLatest,isPrerelease,name,publishedAt,tagName"],
                ["release", "view", "--repo=github.com/example/name", "--json=assets,body,createdAt,isPrerelease,name,publishedAt,tagName",
                 "--", "-v0.41.0"],
            ])
        }
    }

    @Test("Without gh in the PATH: Install the GitHub CLI (gh) to see runs and releases.")
    func ghMissing() async throws {
        try await withTestEngine { _, connection, folder in
            _ = try await createBuildsProject(connection, in: folder)
            let error = await engineError { try await connection.call(BuildsListRuns.self, .init(projectID: "BLD")) }
            #expect(error == EngineError(.unavailable, "Install the GitHub CLI (gh) to see runs and releases."))
            let releases = await engineError { try await connection.call(BuildsListReleases.self, .init(projectID: "BLD")) }
            #expect(releases == EngineError(.unavailable, "Install the GitHub CLI (gh) to see runs and releases."))
        }
    }

    @Test("gh exits with status 4: Run gh auth login in Terminal to see runs and releases.")
    func loggedOut() async throws {
        let gh = FakeGitHubCLI { _ in
            .finished(.ghResult(status: 4, error: "To get started with GitHub CLI, please run:  gh auth login\n"))
        }
        try await withTestEngine(githubCLI: gh) { _, connection, folder in
            _ = try await createBuildsProject(connection, in: folder)
            let error = await engineError { try await connection.call(BuildsListRuns.self, .init(projectID: "BLD")) }
            #expect(error == EngineError(.unavailable, "Run gh auth login in Terminal to see runs and releases."))
        }
    }

    @Test("Another failure of gh gives its message", arguments: [
        (GitHubCLIOutcome.finished(.ghResult(status: 1, error: "\n  failed to get run: HTTP 404: Not Found (https://api.github.com/repos/example/name/actions/runs/1).\nmore\n")),
         "gh run view failed: failed to get run: HTTP 404: Not Found (https://api.github.com/repos/example/name/actions/runs/1)."),
        (GitHubCLIOutcome.finished(.ghResult(status: 1)), "gh run view failed: exit code 1."),
        (GitHubCLIOutcome.finished(ProcessResult(termination: .signaled(9), standardOutput: Data(), standardError: Data(), timedOut: false)),
         "gh run view failed: exit code 137."),
        (GitHubCLIOutcome.finished(.ghResult(status: 1, error: "slow\n", timedOut: true)), "gh run view failed: timeout."),
        (GitHubCLIOutcome.notStarted("cannot start /opt/gh: Permission denied"), "gh run view failed: cannot start /opt/gh: Permission denied."),
    ])
    func failures(outcome: GitHubCLIOutcome, message: String) async throws {
        let gh = FakeGitHubCLI { _ in outcome }
        try await withTestEngine(githubCLI: gh) { _, connection, folder in
            _ = try await createBuildsProject(connection, in: folder)
            let error = await engineError { try await connection.call(BuildsGetRun.self, .init(projectID: "BLD", runID: 1)) }
            #expect(error == EngineError(.unavailable, message))
        }
    }

    @Test("Output that is not the JSON of the call is internal")
    func unexpectedOutput() async throws {
        let gh = FakeGitHubCLI(output: Data(#"[{"databaseId": "x"}]"#.utf8))
        try await withTestEngine(githubCLI: gh) { _, connection, folder in
            _ = try await createBuildsProject(connection, in: folder)
            let error = await engineError { try await connection.call(BuildsListRuns.self, .init(projectID: "BLD")) }
            #expect(error?.code == .internal)
            #expect(error?.message.hasPrefix("gh run list returned unexpected output: [0].") == true)
        }
    }

    @Test("A project without GitHub page runs no gh")
    func noGitHubPage() async throws {
        let gh = FakeGitHubCLI(output: Data("[]".utf8))
        try await withTestEngine(githubCLI: gh) { _, connection, folder in
            _ = try await createBuildsProject(connection, in: folder, page: nil)
            let error = await engineError { try await connection.call(BuildsListRuns.self, .init(projectID: "BLD")) }
            #expect(error == EngineError(.unavailable, "Project BLD has no GitHub page."))
            #expect(gh.runs.isEmpty)
        }
    }

    @Test("The params are checked before gh runs")
    func invalidParams() async throws {
        let gh = FakeGitHubCLI(output: Data("[]".utf8))
        try await withTestEngine(githubCLI: gh) { _, connection, folder in
            _ = try await createBuildsProject(connection, in: folder)
            #expect(await engineError { try await connection.call(BuildsListRuns.self, .init(projectID: "B1")) }
                    == EngineError(.invalid, "projectID: use 2 to 8 letters A–Z."))
            #expect(await engineError { try await connection.call(BuildsListRuns.self, .init(projectID: "NOPE")) }
                    == EngineError(.notFound, "Project NOPE not found."))
            #expect(await engineError { try await connection.call(BuildsGetRun.self, .init(projectID: "BLD", runID: 0)) }
                    == EngineError(.invalid, "runID: use a run id of at least 1."))
            #expect(await engineError { try await connection.call(BuildsCancelRun.self, .init(projectID: "BLD", runID: -2)) }
                    == EngineError(.invalid, "runID: use a run id of at least 1."))
            #expect(await engineError { try await connection.call(BuildsGetRelease.self, .init(projectID: "BLD", tag: "")) }
                    == EngineError(.invalid, "tag: use at least 1 character."))
            #expect(await engineError { try await connection.call(BuildsDownloadAsset.self, .init(projectID: "BLD", tag: "v1", asset: "")) }
                    == EngineError(.invalid, "asset: use at least 1 character."))
            #expect(gh.runs.isEmpty)
        }
    }

    @Test("Only the user calls the builds methods")
    func claudeIsRefused() async throws {
        let gh = FakeGitHubCLI(output: Data("[]".utf8))
        try await withTestEngine(githubCLI: gh) { engine, connection, folder in
            _ = try await createBuildsProject(connection, in: folder)
            let error = await engineError {
                try await engine.call(BuildsListRuns.self, .init(projectID: "BLD"), actor: .claude(chatID: "external"))
            }
            #expect(error == EngineError(.forbidden, "builds.listRuns is not available to claude."))
        }
    }

    @Test("builds.downloadAsset saves the asset in the Downloads folder under a free name")
    func downloadAsset() async throws {
        let gh = FakeGitHubCLI(download: { run in
            // gh saves the asset with its name in the --dir folder.
            guard let directory = run.option("dir") else { return }
            try? Data("asset".utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("App*1.zip"))
        }, answer: { _ in .finished(.ghResult()) })
        try await withTestEngine(githubCLI: gh) { engine, connection, folder in
            await engine.useReleaseQuarantine(false)
            _ = try await createBuildsProject(connection, in: folder)
            let downloads = folder.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let first = try await connection.call(BuildsDownloadAsset.self, .init(projectID: "BLD", tag: "v1.0", asset: "App*1.zip"))
            let second = try await connection.call(BuildsDownloadAsset.self, .init(projectID: "BLD", tag: "v1.0", asset: "App*1.zip"))
            #expect(URL(fileURLWithPath: first.path).standardizedFileURL == downloads.appendingPathComponent("App*1.zip").standardizedFileURL)
            #expect(URL(fileURLWithPath: second.path).lastPathComponent == "App*1 (1).zip")
            #expect(try String(contentsOfFile: second.path, encoding: .utf8) == "asset")
            let run = try #require(gh.runs.first)
            #expect(run.arguments.prefix(3) == ["release", "download", "--repo=github.com/example/name"])
            #expect(run.option("pattern") == #"App\*1.zip"#)
            #expect(Array(run.arguments.suffix(2)) == ["--", "v1.0"])
            #expect(run.timeout == .seconds(1800))
            // The temporary folders are new folders of Runtime/downloads/, removed after the call.
            let runtime = engine.dataDirectory.downloadsFolder.path + "/"
            #expect(gh.runs.count == 2)
            for run in gh.runs {
                let directory = try #require(run.option("dir"))
                #expect(directory.hasPrefix(runtime))
                #expect(!FileManager.default.fileExists(atPath: directory))
            }
        }
    }

    @Test("A name taken by a symbolic link that leads nowhere is skipped")
    func downloadOverDanglingLink() async throws {
        let gh = FakeGitHubCLI(download: { run in
            guard let directory = run.option("dir") else { return }
            try? Data("asset".utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("App.zip"))
        }, answer: { _ in .finished(.ghResult()) })
        try await withTestEngine(githubCLI: gh) { engine, connection, folder in
            await engine.useReleaseQuarantine(false)
            _ = try await createBuildsProject(connection, in: folder)
            let downloads = folder.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: downloads.appendingPathComponent("App.zip").path,
                                                       withDestinationPath: folder.appendingPathComponent("Gone/App.zip").path)
            let saved = try await connection.call(BuildsDownloadAsset.self, .init(projectID: "BLD", tag: "v1.0", asset: "App.zip"))
            #expect(URL(fileURLWithPath: saved.path).lastPathComponent == "App (1).zip")
        }
    }

    @Test("A download whose gh saves no file fails and leaves no temporary folder")
    func downloadWithoutFile() async throws {
        let gh = FakeGitHubCLI { _ in .finished(.ghResult()) }
        try await withTestEngine(githubCLI: gh) { engine, connection, folder in
            await engine.useReleaseQuarantine(false)
            _ = try await createBuildsProject(connection, in: folder)
            let downloads = folder.appendingPathComponent("Downloads", isDirectory: true)
            let error = await engineError {
                try await connection.call(BuildsDownloadAsset.self, .init(projectID: "BLD", tag: "v1.0", asset: "App.zip"))
            }
            #expect(error == EngineError(.internal, "App.zip cannot be saved in \(downloads.path): gh saved no file."))
            let directory = try #require(gh.runs.first?.option("dir"))
            #expect(directory.hasPrefix(engine.dataDirectory.downloadsFolder.path + "/"))
            #expect(!FileManager.default.fileExists(atPath: directory))
        }
    }
}
