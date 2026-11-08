import Foundation

/// The host, owner and name of an origin remote in one of the forms of docs/projects.md ›
/// GitHub page.
struct GitHubRemote: Sendable, Hashable {
    /// The host of GitHub.
    static let gitHubHost = "github.com"

    /// The host as written in the remote, an SSH host alias included.
    var host: String
    var owner: String
    var name: String
    /// True for the two SSH forms, whose host may be an SSH host alias.
    var isSSH: Bool

    init(host: String, owner: String, name: String, isSSH: Bool) {
        self.host = host
        self.owner = owner
        self.name = name
        self.isSSH = isSSH
    }

    /// `[<user>@]<host>:<owner>/<name>`, `ssh://[<user>@]<host>[:<port>]/<owner>/<name>` and
    /// `https://[<user>@]<host>[:<port>]/<owner>/<name>`, each with or without a final `.git`;
    /// nil for any other remote.
    init?(remoteURL: String) {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: String
        if let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            guard scheme == "ssh" || scheme == "https", let components = URLComponents(string: text),
                  let host = components.host, !host.isEmpty, components.query == nil, components.fragment == nil,
                  components.path.hasPrefix("/") else { return nil }
            self.host = host
            path = String(components.path.dropFirst())
            isSSH = scheme == "ssh"
        } else {
            // The scp-like form: the part before the first `:` is `[<user>@]<host>` and holds no `/`
            // (git reads a `/` before the colon as a local path).
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let userAndHost = text[..<colon]
            guard !userAndHost.contains("/"), let host = userAndHost.split(separator: "@", omittingEmptySubsequences: false).last,
                  !host.isEmpty else { return nil }
            self.host = String(host)
            path = String(text[text.index(after: colon)...])
            isSSH = true
        }
        if path.hasSuffix(".git") {
            path.removeLast(4)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }

    /// True when the host is `github.com`, in any letter case.
    var isGitHubHost: Bool {
        host.lowercased() == Self.gitHubHost
    }
}

// The GitHub page of the projects (docs/projects.md › GitHub page): the resolution, the `ssh -G`
// runs for SSH host aliases and the `project.updated` events of the projects whose page changes.
extension Engine {
    /// The page of the origin of the project at `root`: nil before the first read of the origin,
    /// for an origin that is not on GitHub, and while its SSH host alias is not resolved. Starts
    /// no read.
    func originGithubPage(root: String) -> String? {
        guard let url = files.gitRemoteURLs[root], let remote = GitHubRemote(remoteURL: url) else { return nil }
        if !remote.isGitHubHost {
            guard remote.isSSH, let hostName = files.sshHostNames[remote.host],
                  hostName.lowercased() == GitHubRemote.gitHubHost else { return nil }
        }
        return GitHubPage.page(owner: remote.owner, name: remote.name)
    }

    /// The project whose GitHub page field and origin give the page of a loaded project: the
    /// project itself, or, while it uses its parent's settings, the one its parent's page comes
    /// from.
    func githubPageSource(of id: ProjectID) -> ProjectID? {
        var current = id
        var visited: Set<ProjectID> = []
        while let loaded = domain.projects[current], visited.insert(current).inserted {
            guard loaded.project.useParentSettings, let parentID = loaded.parentID, domain.isLoaded(parentID) else {
                return current
            }
            current = parentID
        }
        return nil
    }

    /// The GitHub page of a loaded project: its parent's while it uses its parent's settings,
    /// else the page typed in its field, else its origin's page; nil when it has none.
    func githubPage(of id: ProjectID) -> String? {
        guard let source = githubPageSource(of: id), let loaded = domain.projects[source] else { return nil }
        return loaded.project.githubPage ?? originGithubPage(root: loaded.rootPath)
    }

    /// The GitHub page of every loaded project, nil for none: taken before a change, so that
    /// `emitGithubPageChanges(since:except:origin:)` finds the pages it changed.
    func githubPages() -> [ProjectID: String?] {
        Dictionary(domain.loadedProjectIDs().map { ($0, githubPage(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Emits `project.updated` for every project loaded before a change whose GitHub page now
    /// differs from its page in `before`, except the projects of `except`, which the change
    /// announces itself.
    func emitGithubPageChanges(since before: [ProjectID: String?], except: Set<ProjectID> = [], origin: Actor) {
        for id in domain.loadedProjectIDs() where !except.contains(id) {
            guard let old = before[id], githubPage(of: id) != old else { continue }
            emitProjectUpdated(id, origin: origin)
        }
    }

    /// Runs `ssh -G` for the SSH host alias of an origin that was read, when it has one.
    func refreshSSHHostName(remoteURL: String?, root: String) {
        guard let remoteURL, let remote = GitHubRemote(remoteURL: remoteURL), remote.isSSH, !remote.isGitHubHost else { return }
        refreshSSHHostName(alias: remote.host, root: root)
    }

    /// Starts `ssh -G <alias>` in a child task, unless one runs for the alias: then one more run
    /// starts after it. Without `ssh` nothing runs and the alias stays unresolved.
    private func refreshSSHHostName(alias: String, root: String) {
        guard !hasStopped, files.tools.ssh != nil else { return }
        if files.sshHostNameReads[alias] != nil {
            files.sshHostNameReads[alias] = true
            return
        }
        files.sshHostNameReads[alias] = false
        let tools = files.tools
        Task {
            let hostName = await tools.sshHostName(alias: alias, in: root)
            await self.sshHostNameRead(alias: alias, hostName: hostName, root: root)
        }
    }

    /// A run ended: keeps a host name that changed and emits `project.updated` for the projects
    /// whose page changed, then starts the run asked for meanwhile.
    private func sshHostNameRead(alias: String, hostName: String?, root: String) {
        let again = files.sshHostNameReads.removeValue(forKey: alias) ?? false
        guard !hasStopped else { return }
        let value = hostName ?? ""
        if files.sshHostNames[alias] != value {
            let pagesBefore = githubPages()
            files.sshHostNames[alias] = value
            emitGithubPageChanges(since: pagesBefore, origin: .system)
        }
        if again {
            refreshSSHHostName(alias: alias, root: root)
        }
    }
}
