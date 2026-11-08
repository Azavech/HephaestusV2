import Foundation

/// The `git` tool of docs/architecture.md › Child processes, rule 5: its exit and output are
/// awaited, so that no thread waits while it runs (docs/architecture.md › Concurrency, rule 4).
enum GitTool {
    /// Time allowed to one git call before it is ended (docs/architecture.md › Child processes,
    /// the table of tool runs).
    static let timeout: Duration = .seconds(5)

    /// Runs `git` in `directory` with standard output piped and returns its exit status and
    /// output; nil when it cannot start, is ended by a signal or times out. A call that times out
    /// gets SIGTERM on its process group, then SIGKILL 2 s later (rule 6).
    static func run(_ executable: String, _ arguments: [String], in directory: String, environment: [String: String],
                    timeout: Duration = GitTool.timeout) async -> (status: Int32, output: Data)? {
        let request = ChildProcessRequest(executable: executable, arguments: arguments, environment: environment,
                                          currentDirectory: directory)
        guard let result = try? await ChildProcessRunner.run(request, timeout: timeout), !result.timedOut,
              case .exited(let status) = result.termination else { return nil }
        return (status, result.standardOutput)
    }
}

extension Engine {
    /// The `gitRemoteURL` of a ProjectDetail of the project at `root`: the last value read, nil
    /// before the first read. Starts a new read (docs/engine-api.md › ProjectDetail).
    func gitRemoteURL(root: String) -> String? {
        refreshGitRemoteURL(root: root)
        return files.gitRemoteURLs[root]
    }

    /// Reads the remote of every loaded project again, once the tools are known.
    func refreshGitRemoteURLs() {
        for root in domain.projects.values.map(\.rootPath).sorted() {
            refreshGitRemoteURL(root: root)
        }
    }

    /// Starts a read of the remote of `root` in a child task, unless one is running: then one more
    /// read runs after it. Without `git` nothing is read and the value stays absent.
    func refreshGitRemoteURL(root: String) {
        guard !hasStopped, let git = files.tools.git else { return }
        if files.gitRemoteReads[root] != nil {
            files.gitRemoteReads[root] = true
            return
        }
        files.gitRemoteReads[root] = false
        let environment = files.tools.environment
        Task {
            let url = await Engine.readGitRemoteURL(git: git, root: root, environment: environment)
            await self.gitRemoteURLRead(root: root, url: url)
        }
    }

    /// `git config --get remote.origin.url` run in the root; nil outside a git work tree, without
    /// an `origin` remote, or when git fails or times out.
    private static func readGitRemoteURL(git: String, root: String, environment: [String: String]) async -> String? {
        guard let result = await GitTool.run(git, ["config", "--get", "remote.origin.url"], in: root, environment: environment),
              result.status == 0 else { return nil }
        let url = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// A read ended: keeps a value that changed and emits `project.updated` for the project at the
    /// root, then for every other project whose GitHub page changed; runs `ssh -G` for the SSH host
    /// alias of the origin, checks the GitHub tabs, then runs the read asked for meanwhile
    /// (docs/projects.md › GitHub page, docs/web-tabs.md › Keeping the GitHub tabs).
    private func gitRemoteURLRead(root: String, url: String?) {
        let again = files.gitRemoteReads.removeValue(forKey: root) ?? false
        guard !hasStopped else { return }
        guard let id = domain.projectID(atRoot: root) else {
            files.gitRemoteURLs[root] = nil
            files.gitRemoteReadRoots.remove(root)
            return
        }
        files.gitRemoteReadRoots.insert(root)
        if files.gitRemoteURLs[root] != url {
            let pagesBefore = githubPages()
            files.gitRemoteURLs[root] = url
            emitProjectUpdated(id, origin: .system)
            emitGithubPageChanges(since: pagesBefore, except: [id], origin: .system)
        }
        refreshSSHHostName(remoteURL: url, root: root)
        keepGitHubTabs(origin: .system)
        if again {
            refreshGitRemoteURL(root: root)
        }
    }
}
