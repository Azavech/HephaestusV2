import Foundation

extension Engine {
    /// docs/engine-api.md › Builds, served by the configuration's `GitHubCLIRunning`. Only the
    /// user actor calls these methods.
    func registerBuildHandlers() {
        register(BuildsListRuns.self, actors: [.user]) { [unowned self] params, actor in
            try await self.buildsListRuns(params, actor)
        }
        register(BuildsGetRun.self, actors: [.user]) { [unowned self] params, actor in
            try await self.buildsGetRun(params, actor)
        }
        register(BuildsRerunRun.self, actors: [.user]) { [unowned self] params, actor in
            try await self.buildsRerunRun(params, actor)
        }
        register(BuildsCancelRun.self, actors: [.user]) { [unowned self] params, actor in
            try await self.buildsCancelRun(params, actor)
        }
        register(BuildsListReleases.self, actors: [.user]) { [unowned self] params, actor in
            try await self.buildsListReleases(params, actor)
        }
        register(BuildsGetRelease.self, actors: [.user]) { [unowned self] params, actor in
            try await self.buildsGetRelease(params, actor)
        }
        register(BuildsDownloadAsset.self, actors: [.user]) { [unowned self] params, actor in
            try await self.buildsDownloadAsset(params, actor)
        }
    }

    /// The variables of the login-shell environment that gh does not get: they would make it
    /// write colours into its JSON or debug lines into its standard error (docs/builds.md › gh
    /// calls).
    static let githubCLIRemovedVariables = ["CLICOLOR_FORCE", "GH_FORCE_TTY", "GH_DEBUG", "DEBUG"]

    /// The timeout of the gh runs other than `gh release download` (docs/builds.md › gh calls).
    static let githubCLITimeout: Duration = .seconds(30)
    /// The timeout of `gh release download`.
    static let githubDownloadTimeout: Duration = .seconds(30 * 60)

    /// `builds.listRuns`.
    func buildsListRuns(_ params: BuildsListRuns.Params, _ actor: Actor) async throws -> [WorkflowRun] {
        let context = try await buildsContext(params.projectID)
        let output = try await runGitHubCLI(["run", "list", context.repoOption, "--limit=50", "--json=" + BuildsJSON.runListFields],
                                            command: "run list", context: context)
        return try decodeGitHubOutput(command: "run list") { try BuildsJSON.runs(from: output) }
    }

    /// `builds.getRun`.
    func buildsGetRun(_ params: BuildsGetRun.Params, _ actor: Actor) async throws -> WorkflowRun {
        _ = try normalizedProjectID(params.projectID)
        let runID = try Self.checkedRunID(params.runID)
        let context = try await buildsContext(params.projectID)
        let output = try await runGitHubCLI(["run", "view", context.repoOption, "--json=" + BuildsJSON.runViewFields, "--", runID],
                                            command: "run view", context: context)
        return try decodeGitHubOutput(command: "run view") { try BuildsJSON.run(from: output) }
    }

    /// `builds.rerunRun`: `gh run rerun`, with `--failed` for the failed jobs only.
    func buildsRerunRun(_ params: BuildsRerunRun.Params, _ actor: Actor) async throws -> Empty {
        _ = try normalizedProjectID(params.projectID)
        let runID = try Self.checkedRunID(params.runID)
        let context = try await buildsContext(params.projectID)
        var arguments = ["run", "rerun", context.repoOption]
        if params.failedOnly == true {
            arguments.append("--failed")
        }
        _ = try await runGitHubCLI(arguments + ["--", runID], command: "run rerun", context: context)
        return Empty()
    }

    /// `builds.cancelRun`.
    func buildsCancelRun(_ params: BuildsCancelRun.Params, _ actor: Actor) async throws -> Empty {
        _ = try normalizedProjectID(params.projectID)
        let runID = try Self.checkedRunID(params.runID)
        let context = try await buildsContext(params.projectID)
        _ = try await runGitHubCLI(["run", "cancel", context.repoOption, "--", runID], command: "run cancel", context: context)
        return Empty()
    }

    /// `builds.listReleases`: the published releases, drafts left out.
    func buildsListReleases(_ params: BuildsListReleases.Params, _ actor: Actor) async throws -> [GitHubRelease] {
        let context = try await buildsContext(params.projectID)
        let output = try await runGitHubCLI(["release", "list", context.repoOption, "--limit=50", "--exclude-drafts",
                                             "--json=" + BuildsJSON.releaseListFields],
                                            command: "release list", context: context)
        return try decodeGitHubOutput(command: "release list") { try BuildsJSON.releases(from: output) }
    }

    /// `builds.getRelease`.
    func buildsGetRelease(_ params: BuildsGetRelease.Params, _ actor: Actor) async throws -> ReleaseDetail {
        _ = try normalizedProjectID(params.projectID)
        let tag = try Self.checkedNonEmpty(params.tag, param: "tag")
        let context = try await buildsContext(params.projectID)
        let output = try await runGitHubCLI(["release", "view", context.repoOption, "--json=" + BuildsJSON.releaseViewFields, "--", tag],
                                            command: "release view", context: context)
        return try decodeGitHubOutput(command: "release view") { try BuildsJSON.releaseDetail(from: output) }
    }

    /// `builds.downloadAsset`: gh downloads the asset into a new folder of `Runtime/downloads/`,
    /// then the engine moves it into the Downloads folder under a free name and gives it the
    /// quarantine attributes of a web download; the folder is removed in every case
    /// (docs/builds.md › Downloads).
    func buildsDownloadAsset(_ params: BuildsDownloadAsset.Params, _ actor: Actor) async throws -> DownloadedAsset {
        _ = try normalizedProjectID(params.projectID)
        let tag = try Self.checkedNonEmpty(params.tag, param: "tag")
        let asset = try Self.checkedNonEmpty(params.asset, param: "asset")
        let context = try await buildsContext(params.projectID)
        let downloads = configuration.downloadsFolder
        let folder = dataDirectory.downloadsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Self.assetNotSaved(asset, in: downloads, reason: error.localizedDescription)
        }
        defer { try? manager.removeItem(at: folder) }
        _ = try await runGitHubCLI(["release", "download", context.repoOption, "--pattern=" + ReleaseDownloads.pattern(forAsset: asset),
                                    "--dir=" + folder.path, "--", tag],
                                   command: "release download", context: context, timeout: Self.githubDownloadTimeout)
        guard let file = ReleaseDownloads.downloadedFile(in: folder, asset: asset) else {
            throw Self.assetNotSaved(asset, in: downloads, reason: "gh saved no file")
        }
        // The move may copy a large file to another volume: it runs off the engine actor.
        let moved = await Task.detached { () -> Result<URL, Error> in
            Result { try ReleaseDownloads.move(file, asset: asset, into: downloads) }
        }.value
        let destination: URL
        switch moved {
        case .success(let url):
            destination = url
        case .failure(let error):
            throw Self.assetNotSaved(asset, in: downloads, reason: error.localizedDescription)
        }
        if quarantinesReleaseDownloads {
            ReleaseDownloads.quarantine(destination, owner: context.owner, name: context.name, tag: tag, asset: asset)
        }
        return DownloadedAsset(path: destination.path)
    }

    // MARK: Context and gh runs (docs/builds.md › gh calls)

    /// The project of a `builds.*` call: `invalid` for a malformed identifier, `notFound` for a
    /// project that is not loaded, `unavailable` for a project without GitHub page. Waits for the
    /// login-shell environment, then reads the project again, since it may have gone meanwhile.
    func buildsContext(_ value: ProjectID) async throws -> BuildsContext {
        let projectID = try loadedProjectID(value)
        var environment = await childProcessEnvironment()
        guard domain.isLoaded(projectID), let root = domain.projectRoot(projectID) else {
            throw EngineError.notFound("Project", projectID)
        }
        guard let page = githubPage(of: projectID), let repository = GitHubPage.ownerAndName(of: page) else {
            throw EngineError(.unavailable, "Project \(projectID) has no GitHub page.")
        }
        for name in Self.githubCLIRemovedVariables {
            environment[name] = nil
        }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        return BuildsContext(projectID: projectID, root: root.path, owner: repository.owner, name: repository.name,
                             environment: environment)
    }

    /// Runs gh in the project root and returns its standard output; maps its failures
    /// (docs/builds.md › Failures).
    func runGitHubCLI(_ arguments: [String], command: String, context: BuildsContext,
                      timeout: Duration = Engine.githubCLITimeout) async throws -> Data {
        let run = GitHubCLIRun(arguments: arguments, environment: context.environment, directory: context.root, timeout: timeout)
        let processes = githubCLIProcesses
        let started = StartedProcess()
        let outcome = await configuration.githubCLI.run(run) { process in
            started.set(process)
            processes.add(process)
        }
        if let process = started.process {
            processes.remove(process)
        }
        if let error = GitHubCLIFailure.error(command: command, outcome: outcome) {
            throw error
        }
        guard case .finished(let result) = outcome else { return Data() }
        return result.standardOutput
    }

    /// Decodes the output of gh: `internal` with the coding path and the reason when it is not the
    /// JSON the call reads.
    func decodeGitHubOutput<T>(command: String, _ decode: () throws -> T) throws -> T {
        do {
            return try decode()
        } catch {
            let (path, reason) = DecodingErrorDescription.describe(error)
            throw GitHubCLIFailure.unexpectedOutput(command, reason: "\(path): \(reason)")
        }
    }

    // MARK: Checks (docs/engine-api.md › Builds, errors)

    /// A run id of at least 1, as the argument of gh; else `invalid`.
    static func checkedRunID(_ value: Int) throws -> String {
        guard value >= 1 else {
            throw EngineError.invalid("runID", "use a run id of at least 1")
        }
        return String(value)
    }

    /// A text of at least 1 character; else `invalid`.
    static func checkedNonEmpty(_ value: String, param: String) throws -> String {
        guard !value.isEmpty else {
            throw EngineError.invalid(param, "use at least 1 character")
        }
        return value
    }

    /// `internal` `<asset> cannot be saved in <folder>: <reason>.`
    static func assetNotSaved(_ asset: String, in folder: URL, reason: String) -> EngineError {
        var reason = reason
        while reason.hasSuffix(".") {
            reason.removeLast()
        }
        return EngineError(.internal, "\(asset) cannot be saved in \(folder.path): \(reason).")
    }
}

/// The project, repository and environment of a `builds.*` call.
struct BuildsContext: Sendable {
    var projectID: ProjectID
    /// The project root, the working directory of gh.
    var root: String
    var owner: String
    var name: String
    /// The login-shell environment without `HEPHAESTUS_*` and the variables that change the
    /// output of gh, with `GH_PROMPT_DISABLED` and `GH_NO_UPDATE_NOTIFIER`.
    var environment: [String: String]

    /// `--repo=github.com/<owner>/<name>`, so that a `GH_HOST` of the environment does not send
    /// the call to another host.
    var repoOption: String { "--repo=github.com/\(owner)/\(name)" }
}

/// The process of one gh run, recorded when it starts.
final class StartedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ChildProcess?

    var process: ChildProcess? { lock.withLock { current } }

    func set(_ process: ChildProcess) {
        lock.withLock { current = process }
    }
}
