import Foundation
import Testing
@testable import HephaestusCore

extension Engine {
    /// The host names `ssh -G` printed, for checks.
    var testSSHHostNames: [String: String] {
        files.sshHostNames
    }
}

/// The GitHub page of the projects through `LocalEngineConnection` and the MCP tools
/// (docs/projects.md › GitHub page, › Sub projects, docs/engine-api.md › projects.update,
/// › ProjectDetail).
@Suite("GitHub page")
struct GitHubPageTests {
    /// Written in two parts, so that no line of this file holds an address.
    static let at = "@"

    /// Tools whose `git` prints the content of the file `origin-url` of the folder it runs in
    /// for `git config --get remote.origin.url`, and whose `ssh -G` prints `hostname github.com`
    /// for the alias `github-work` and the alias itself for any other.
    static func fakeTools(in folder: URL) throws -> FileTools {
        let git = try writeScript(folder.appendingPathComponent("bin/git"), """
            if [ "$1" = config ] && [ -f origin-url ]; then cat origin-url; exit 0; fi
            exit 1
            """)
        let ssh = try writeScript(folder.appendingPathComponent("bin/ssh"), """
            [ "$1" = -G ] || exit 2
            if [ "$2" = github-work ]; then echo "user git"; echo "hostname github.com"; else echo "hostname $2"; fi
            """)
        return FileTools(environment: ["PATH": "/usr/bin:/bin"], git: git, ssh: ssh)
    }

    /// Sets the origin that the fake `git` prints in a project folder; nil removes it.
    static func setOrigin(_ url: String?, _ h: DomainHarness, _ relative: String) throws {
        let file = h.projects.appendingPathComponent(relative).appendingPathComponent("origin-url")
        if let url {
            try writeFile(url + "\n", to: file)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Calls projects.get until `check` holds, at most `waitLimit`; returns the last ProjectDetail.
    static func detail(_ h: DomainHarness, _ id: ProjectID, until check: (ProjectDetail) -> Bool) async throws -> ProjectDetail {
        let deadline = ContinuousClock.now + waitLimit
        var detail = try await h.connection.call(ProjectsGet.self, .init(projectID: id))
        while !check(detail), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            detail = try await h.connection.call(ProjectsGet.self, .init(projectID: id))
        }
        return detail
    }

    /// Waits until `ssh -G` has run for `alias`, at most `waitLimit`; returns the host name it printed.
    static func waitForSSH(_ h: DomainHarness, alias: String) async throws -> String? {
        let deadline = ContinuousClock.now + waitLimit
        while ContinuousClock.now < deadline {
            if let hostName = await h.engine.testSSHHostNames[alias] {
                return hostName
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The pages of the project.updated events of `id`.
    static func pages(_ events: [EngineEventEnvelope], _ id: ProjectID) -> [String?] {
        events.compactMap { try? $0.payload(ProjectUpdatedEvent.self) }.filter { $0.project.id == id }.map(\.githubPage)
    }

    @Test("The origin's page is the page of a project on GitHub, by host or SSH host alias, and its placeholder")
    func originPage() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(try Self.fakeTools(in: h.folder))
            let page = "https://github.com/owner/name"
            let at = Self.at
            let forms = ["git\(at)github.com:owner/name.git", "ssh://git\(at)github.com/owner/name.git", "https://github.com/owner/name.git",
                         "https://github.com/owner/name", "git\(at)github-work:owner/name.git", "ssh://git\(at)github-work/owner/name"]
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            for url in forms {
                try Self.setOrigin(url, h, "Repo")
                let detail = try await Self.detail(h, "REPO") { $0.gitRemoteURL == url && $0.githubPage == page }
                #expect(detail.githubPage == page, "\(url)")
                #expect(detail.originGithubPage == page, "\(url)")
                #expect(detail.project.githubPage == nil)
            }
            // A remote that is not on GitHub, or whose alias is another host, gives no page.
            for url in ["https://example.com/owner/name.git", "git\(at)gitlab-work:owner/name.git", "https://github-work/owner/name.git",
                        "https://github.com/group/owner/name.git"] {
                try Self.setOrigin(url, h, "Repo")
                _ = try await Self.detail(h, "REPO") { $0.gitRemoteURL == url }
                if url.contains("gitlab-work") {
                    // The alias of the SSH form is resolved after the origin is read.
                    #expect(try await Self.waitForSSH(h, alias: "gitlab-work") == "gitlab-work")
                }
                let settled = try await h.connection.call(ProjectsGet.self, .init(projectID: "REPO"))
                #expect(settled.gitRemoteURL == url)
                #expect(settled.githubPage == nil, "\(url)")
                #expect(settled.originGithubPage == nil, "\(url)")
            }
            try Self.setOrigin(nil, h, "Repo")
            let none = try await Self.detail(h, "REPO") { $0.gitRemoteURL == nil }
            #expect(none.githubPage == nil && none.originGithubPage == nil)
        }
    }

    @Test("Without ssh, an SSH host alias is not resolved")
    func aliasWithoutSSH() async throws {
        try await withDomainEngine { h in
            var tools = try Self.fakeTools(in: h.folder)
            tools.ssh = nil
            await h.engine.useFileTools(tools)
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            let url = "git\(Self.at)github-work:owner/name.git"
            try Self.setOrigin(url, h, "Repo")
            let detail = try await Self.detail(h, "REPO") { $0.gitRemoteURL == url }
            // Without ssh nothing runs, so the alias stays unresolved.
            #expect(detail.githubPage == nil)
            #expect(await h.engine.testSSHHostNames.isEmpty)
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "REPO")).githubPage == nil)
        }
    }

    @Test("A typed page replaces the origin's page, removing it brings the origin's page back, and an invalid page is refused")
    func typedPage() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(try Self.fakeTools(in: h.folder))
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            try Self.setOrigin("https://github.com/owner/name.git", h, "Repo")
            _ = try await Self.detail(h, "REPO") { $0.githubPage == "https://github.com/owner/name" }

            let events = await DomainEventRecorder.make(h)
            let typed = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .set(" https://github.com/other/repo/ ")))
            #expect(typed.project.githubPage == "https://github.com/other/repo")
            #expect(typed.githubPage == "https://github.com/other/repo")
            #expect(typed.originGithubPage == "https://github.com/owner/name")
            #expect(await events.wait(for: ProjectUpdatedEvent.name) == ["project.updated"])
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Repo")))
            #expect(try readFile(folder.projectFile).contains("githubPage: https://github.com/other/repo\n"))

            // The same page, its trailing / aside, changes nothing.
            events.clear()
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .set("https://github.com/other/repo/")))
            #expect(await events.settle().isEmpty)

            let invalid = EngineError(.invalid, "githubPage: use a page of the form https://github.com/<owner>/<name>.")
            for text in ["", "github.com/x", "https://github.com/owner", "http://github.com/owner/name"] {
                let params = ProjectsUpdate.Params(projectID: "REPO", githubPage: .set(text))
                #expect(await engineError { try await h.connection.call(ProjectsUpdate.self, params) } == invalid)
            }
            #expect(try ProjectFileStore.readProject(folder).githubPage == "https://github.com/other/repo")

            let cleared = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .clear))
            #expect(cleared.project.githubPage == nil)
            #expect(cleared.githubPage == "https://github.com/owner/name")
            #expect(try !readFile(folder.projectFile).contains("githubPage"))
        }
    }

    @Test("A sub project uses its parent's page while Use parent settings is on, its own field and origin while it is off")
    func subProject() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(try Self.fakeTools(in: h.folder))
            try await h.create("Parent", name: "Parent", identifier: "PAR")
            let created = try await h.create("Parent/sub", name: "Sub", identifier: "SUB", parentID: "PAR")
            #expect(created.project.useParentSettings)
            #expect(try readFile(ProjectFolder(root: URL(fileURLWithPath: h.path("Parent/sub"))).projectFile)
                .contains("useParentSettings: true\n"))
            try Self.setOrigin("https://github.com/owner/parent.git", h, "Parent")
            try Self.setOrigin("https://github.com/owner/sub.git", h, "Parent/sub")

            // On: the parent's origin page, then the parent's typed page.
            var sub = try await Self.detail(h, "SUB") { $0.githubPage == "https://github.com/owner/parent" }
            #expect(sub.githubPage == "https://github.com/owner/parent")
            sub = try await Self.detail(h, "SUB") { $0.originGithubPage == "https://github.com/owner/sub" }
            #expect(sub.originGithubPage == "https://github.com/owner/sub")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "SUB", githubPage: .set("https://github.com/owner/typed")))
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "PAR", githubPage: .set("https://github.com/owner/main")))
            sub = try await h.connection.call(ProjectsGet.self, .init(projectID: "SUB"))
            #expect(sub.githubPage == "https://github.com/owner/main")

            // Off: its own typed page, then its own origin's page.
            let events = await DomainEventRecorder.make(h)
            sub = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "SUB", useParentSettings: false))
            #expect(!sub.project.useParentSettings)
            #expect(sub.githubPage == "https://github.com/owner/typed")
            #expect(await events.wait(for: ProjectUpdatedEvent.name) == ["project.updated"])
            #expect(try readFile(ProjectFolder(root: URL(fileURLWithPath: h.path("Parent/sub"))).projectFile)
                .contains("useParentSettings: false\n"))
            sub = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "SUB", githubPage: .clear))
            #expect(sub.githubPage == "https://github.com/owner/sub")
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "PAR")).githubPage == "https://github.com/owner/main")

            // On again.
            sub = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "SUB", useParentSettings: true))
            #expect(sub.githubPage == "https://github.com/owner/main")
            #expect(sub.originGithubPage == "https://github.com/owner/sub")
        }
    }

    @Test("Nested sub projects take the page of the nearest project that does not use its parent's settings")
    func nestedSubProjects() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            try await h.create("Top", name: "Top", identifier: "TOP")
            try await h.create("Top/mid", name: "Mid", identifier: "MID", parentID: "TOP")
            try await h.create("Top/mid/leaf", name: "Leaf", identifier: "LEAF", parentID: "MID")
            func page(_ id: ProjectID) async throws -> String? {
                try await h.connection.call(ProjectsGet.self, .init(projectID: id)).githubPage
            }
            #expect(try await page("LEAF") == nil)
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "TOP", githubPage: .set("https://github.com/owner/top")))
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "MID", githubPage: .set("https://github.com/owner/mid")))
            #expect(try await page("MID") == "https://github.com/owner/top")
            #expect(try await page("LEAF") == "https://github.com/owner/top")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "MID", useParentSettings: false))
            #expect(try await page("MID") == "https://github.com/owner/mid")
            #expect(try await page("LEAF") == "https://github.com/owner/mid")
            // A top-level project's useParentSettings has no effect.
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "TOP", useParentSettings: false))
            #expect(try await page("TOP") == "https://github.com/owner/top")
        }
    }

    @Test("A change of a parent's page emits project.updated for the sub projects that use it, and only for them")
    func eventsForSubProjects() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            try await h.create("Top", name: "Top", identifier: "TOP")
            try await h.create("Top/mid", name: "Mid", identifier: "MID", parentID: "TOP")
            try await h.create("Top/mid/leaf", name: "Leaf", identifier: "LEAF", parentID: "MID")
            try await h.create("Top/own", name: "Own", identifier: "OWN", parentID: "TOP")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "OWN", useParentSettings: false))

            let events = await DomainEventRecorder.make(h)
            let page = "https://github.com/owner/top"
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "TOP", githubPage: .set(page)))
            let received = await events.wait { Self.pages($0, "LEAF").count == 1 }
            #expect(received.map(\.name) == ["project.updated", "project.updated", "project.updated"])
            #expect(Self.pages(received, "TOP") == [page])
            #expect(Self.pages(received, "MID") == [page])
            #expect(Self.pages(received, "LEAF") == [page])
            #expect(await events.settle().count == 3)
            #expect(received.allSatisfy { $0.origin == .user(deviceID: h.engine.deviceID) })

            // Turning the checkbox of MID off changes the page of MID and LEAF.
            events.clear()
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "MID", useParentSettings: false))
            let off = await events.wait { Self.pages($0, "LEAF").count == 1 }
            #expect(Self.pages(off, "MID") == [nil])
            #expect(Self.pages(off, "LEAF") == [nil])
            #expect(Self.pages(off, "TOP").isEmpty && Self.pages(off, "OWN").isEmpty)

            // A change outside the app is followed the same way, with origin system.
            events.clear()
            let file = h.projects.appendingPathComponent("Top/mid/.hephaestus/project.yml")
            let text = try readFile(file).replacingOccurrences(of: "useParentSettings: false", with: "useParentSettings: true")
            try writeFile(text, to: file)
            await h.engine.projectDataFilesChanged(projectID: "MID", paths: [".hephaestus/project.yml"])
            let reloaded = await events.wait { Self.pages($0, "LEAF").count == 1 }
            #expect(Self.pages(reloaded, "MID") == [page])
            #expect(Self.pages(reloaded, "LEAF") == [page])
            #expect(reloaded.allSatisfy { $0.origin == .system })
        }
    }

    @Test("Removing a page that sub projects loaded at start use emits project.updated for them")
    func loadedAtStart() async throws {
        try await withDomainEngine(prepare: { directory, projects in
            let parent = projects.appendingPathComponent("Top")
            try writeFile(projectYAML(id: "TOP", name: "Top", subprojects: ["sub"], extra: "githubPage: https://github.com/owner/top\n"),
                          to: parent.appendingPathComponent(".hephaestus/project.yml"))
            try writeFile(projectYAML(id: "SUB", name: "Sub"), to: parent.appendingPathComponent("sub/.hephaestus/project.yml"))
            try writeFile(registryYAML([parent.path]), to: directory.registryFile)
        }) { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "SUB")).githubPage == "https://github.com/owner/top")
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "TOP", githubPage: .clear))
            let received = await events.wait { Self.pages($0, "SUB").count == 1 }
            #expect(Self.pages(received, "TOP") == [nil])
            #expect(Self.pages(received, "SUB") == [nil])
            // A change that leaves every page as it is emits nothing for the others.
            events.clear()
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "TOP", name: "Main"))
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "projects.changed"])
        }
    }

    @Test("projects.open emits project.updated for a top-level project it adopts whose page changes")
    func adoption() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            try await h.create("Mono/x", name: "App", identifier: "APP")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "APP", githubPage: .set("https://github.com/owner/x")))
            try writeFile(projectYAML(id: "MONO", name: "Mono", subprojects: ["x"], extra: "githubPage: https://github.com/owner/mono\n"),
                          to: h.projects.appendingPathComponent("Mono/.hephaestus/project.yml"))
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(ProjectsOpen.self, .init(rootPath: h.path("Mono")))
            let received = await events.wait(for: ProjectsChangedEvent.name)
            #expect(received == ["project.updated", "project.updated", "projects.changed"])
            let adopted = events.all.compactMap { try? $0.payload(ProjectUpdatedEvent.self) }.first { $0.project.id == "APP" }
            #expect(adopted?.parentID == "MONO")
            #expect(adopted?.githubPage == "https://github.com/owner/mono")
        }
    }

    @Test("A change of the origin emits project.updated for the sub projects that use the page")
    func originChangeEvents() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(try Self.fakeTools(in: h.folder))
            try await h.create("Top", name: "Top", identifier: "TOP")
            try await h.create("Top/sub", name: "Sub", identifier: "SUB", parentID: "TOP")
            let events = await DomainEventRecorder.make(h)
            try Self.setOrigin("git\(Self.at)github-work:owner/top.git", h, "Top")
            _ = try await h.connection.call(ProjectsGet.self, .init(projectID: "TOP"))
            let received = await events.wait { Self.pages($0, "SUB").contains("https://github.com/owner/top") }
            #expect(Self.pages(received, "SUB").last == "https://github.com/owner/top")
            #expect(received.filter { $0.name == ProjectUpdatedEvent.name }.allSatisfy { $0.origin == .system })
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "SUB")).githubPage == "https://github.com/owner/top")
        }
    }

    @Test("A change of a watched .git/config reads the origin again")
    func gitConfigWatched() async throws {
        try await withFileTestEngine(subproject: true) { engine, connection, project in
            // A git that prints the last url of the .git/config of the folder it runs in.
            let git = try writeScript(project.folder.appendingPathComponent("bin/git"), """
                [ "$1" = config ] && [ -f .git/config ] || exit 1
                url=$(sed -n 's/^[[:space:]]*url = //p' .git/config | tail -n 1)
                [ -n "$url" ] || exit 1
                echo "$url"
                """)
            await engine.useFileTools(FileTools(environment: ["PATH": "/usr/bin:/bin"], git: git))
            _ = try await connection.call(ProjectsGet.self, .init(projectID: FileTestProject.id))
            _ = try await connection.call(ProjectsGet.self, .init(projectID: FileTestProject.subID))
            let events = connection.events
            // Written again every 2 s: under the load of the test run, FSEvents may report only a
            // folder, which reads the origins inside it again too.
            let writer = Task {
                for _ in 0..<10 {
                    try project.write("Sub/.git/config", "[remote \"origin\"]\n\turl = https://github.com/owner/sub.git\n")
                    try await Task.sleep(for: .seconds(2))
                }
            }
            defer { writer.cancel() }
            let updated = await firstElement(of: events, timeout: .seconds(25)) { envelope in
                (try? envelope.payload(ProjectUpdatedEvent.self))?.originGithubPage == "https://github.com/owner/sub"
            }
            let detail = try updated.map { try $0.payload(ProjectUpdatedEvent.self) }
            #expect(detail?.project.id == FileTestProject.subID)
            #expect(detail?.githubPage == nil)
            #expect(updated?.origin == .system)
            // The parent's origin did not change: its root has no .git/config.
            #expect(try await connection.call(ProjectsGet.self, .init(projectID: FileTestProject.id)).gitRemoteURL == nil)
        }
    }

    @Test("get_project gives the page and useParentSettings; update_project cannot change them")
    func throughMCP() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            let engine = h.engine
            let handlers = MCPToolHandlers(engineCall: { method, params, actor in
                try await engine.dispatch(method: method, params: params, actor: actor)
            }, debugUI: nil, homeDirectory: "/Users/example")
            func call(_ tool: String, _ arguments: String) async throws -> Result<String, MCPToolError> {
                let definition = try #require(MCPToolCatalog.tool(named: tool, debugTools: false))
                return try await handlers.call(definition, arguments: try jsonValue(arguments), actor: h.claude)
            }
            try await h.create("Top", name: "Top", identifier: "TOP")
            try await h.create("Top/sub", name: "Sub", identifier: "SUB", parentID: "TOP")
            let plain = try await call("get_project", #"{"projectID":"SUB"}"#).get()
            let plainJSON = try jsonValue(plain).objectValue
            #expect(plainJSON?["githubPage"] == nil)
            #expect(plainJSON?["project"]?.objectValue?["useParentSettings"] == .bool(true))

            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "TOP", githubPage: .set("https://github.com/owner/name")))
            let text = try await call("get_project", #"{"projectID":"SUB"}"#).get()
            let json = try jsonValue(text).objectValue
            #expect(json?["githubPage"] == .string("https://github.com/owner/name"))
            #expect(json?["project"]?.objectValue?["githubPage"] == .null)

            for arguments in [#"{"projectID":"SUB","githubPage":"https://github.com/owner/other"}"#,
                              #"{"projectID":"SUB","useParentSettings":false}"#] {
                guard case .failure(let error) = try await call("update_project", arguments) else {
                    Issue.record("update_project accepted \(arguments)")
                    continue
                }
                #expect(error.message.hasSuffix(": unknown argument."))
            }
            let stored = try await h.connection.call(ProjectsGet.self, .init(projectID: "SUB")).project
            #expect(stored.githubPage == nil && stored.useParentSettings)
        }
    }
}
