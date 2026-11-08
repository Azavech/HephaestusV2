import Foundation
import Testing
@testable import HephaestusCore

extension Engine {
    /// Holds the `ssh -G` runs of `alias` as if one were running, for checks.
    func testHoldSSH(_ alias: String) {
        files.sshHostNameReads[alias] = false
    }

    /// Ends the held run of `alias` with the host name it printed, as a run that ends does.
    func testEndSSH(_ alias: String, hostName: String) {
        files.sshHostNameReads[alias] = nil
        files.sshHostNames[alias] = hostName
        keepGitHubTabs(origin: .system)
    }

    /// True while the origin of the project at `root` is being read.
    func testReadsGitRemote(_ root: String) -> Bool {
        files.gitRemoteReads[DomainPaths.standardize(root)] != nil
    }
}

/// The GitHub tabs the engine keeps for the GitHub page of each project, and the refusals of the
/// web tab methods on them (docs/web-tabs.md › GitHub tabs, › Keeping the GitHub tabs,
/// docs/engine-api.md › Web tabs).
@Suite("GitHub tabs in the engine")
struct GitHubTabsEngineTests {
    static let page = "https://github.com/owner/name"
    static let ci = "https://github.com/owner/name/actions"
    static let locked = EngineError(.forbidden, "This tab is locked.")
    static let storedIDs = [UUID(uuidString: "0F8E2A3B-5C4D-4E6F-8A7B-9C0D1E2F3A4B")!, UUID(uuidString: "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D")!]

    /// The key `webTabs` of a project file with the two GitHub tabs of `page`, locked without an
    /// original URL as before original URLs existed, then `extra` tabs.
    static func storedTabsYAML(titles: [String] = ["", ""], extra: String = "") -> String {
        "webTabs:\n"
            + "- id: \(storedIDs[0].uuidString)\n  title: '\(titles[0])'\n  url: \(page)\n  locked: true\n  githubTab: page\n"
            + "- id: \(storedIDs[1].uuidString)\n  title: '\(titles[1])'\n  url: \(ci)\n  locked: true\n  githubTab: ci\n"
            + extra
    }

    /// Calls projects.get, which reads the origin again, until the project's tabs pass `check`;
    /// returns them.
    static func tabs(_ h: DomainHarness, _ id: ProjectID, until check: ([WebTab]) -> Bool) async throws -> [WebTab] {
        try await GitHubPageTests.detail(h, id) { check($0.project.webTabs) }.project.webTabs
    }

    @Test("A typed page gives the page tab and the CI tab, first and locked; removing the page removes them")
    func typedPage() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            let docs = try await h.connection.call(WebTabsOpen.self, .init(projectID: "REPO", url: "https://example.com/"))
            let events = await DomainEventRecorder.make(h)
            let detail = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .set(Self.page)))
            #expect(await events.wait(for: ProjectUpdatedEvent.name, count: 2) == ["project.updated", "webTabs.updated", "project.updated"])
            #expect(detail.project.webTabs.map(\.githubTab) == [.page, .ci, nil])

            let tabs = try await h.connection.call(WebTabsList.self, .init(projectID: "REPO"))
            #expect(tabs.map(\.url) == [Self.page, Self.ci, "https://example.com/"])
            #expect(tabs.map(\.title) == ["owner/name", "Actions · owner/name", "example.com"])
            #expect(tabs.map(\.locked) == [true, true, false])
            #expect(tabs.map(\.originalURL) == [Self.page, Self.ci, nil])
            #expect(tabs[2] == docs)
            let text = try readFile(ProjectFolder(root: URL(fileURLWithPath: h.path("Repo"))).projectFile)
            #expect(text.contains("  locked: true\n  originalURL: \(Self.page)\n  githubTab: page\n"))
            #expect(text.contains("  locked: true\n  originalURL: \(Self.ci)\n  githubTab: ci\n"))
            #expect(!text.contains("githubTab: null"))

            events.clear()
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .clear))
            #expect(await events.wait(for: ProjectUpdatedEvent.name, count: 2) == ["project.updated", "webTabs.updated", "project.updated"])
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "REPO")) == [docs])
        }
    }

    @Test("An origin on GitHub gives the tabs once read, an existing tab on the CI page becomes the CI tab, and removing the origin removes them")
    func origin() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(try GitHubPageTests.fakeTools(in: h.folder))
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            let actions = try await h.connection.call(WebTabsOpen.self, .init(projectID: "REPO", url: Self.ci, title: "Workflow runs"))
            let docs = try await h.connection.call(WebTabsOpen.self, .init(projectID: "REPO", url: "https://example.com/", index: 0))
            try GitHubPageTests.setOrigin("git\(GitHubPageTests.at)github.com:owner/name.git", h, "Repo")
            let tabs = try await Self.tabs(h, "REPO") { $0.count == 3 && $0.first?.githubTab == .page }
            #expect(tabs.map(\.githubTab) == [.page, .ci, nil])
            #expect(tabs[0].url == Self.page && tabs[0].locked)
            #expect(tabs[1] == WebTab(id: actions.id, title: "Workflow runs", url: Self.ci, locked: true, originalURL: Self.ci, githubTab: .ci))
            #expect(tabs[2] == docs)

            try GitHubPageTests.setOrigin(nil, h, "Repo")
            #expect(try await Self.tabs(h, "REPO") { $0.count == 1 } == [docs])
        }
    }

    @Test("A changed page gives both tabs the new URLs and titles with their ids; browsing from a tab keeps its original URL")
    func changedPage() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .set(Self.page)))
            let tabs = try await h.connection.call(WebTabsList.self, .init(projectID: "REPO"))
            let run = "https://github.com/owner/name/actions/runs/1"
            let browsed = try await h.connection.call(WebTabsUpdate.self, .init(projectID: "REPO", tabID: tabs[1].id, url: run, title: "Run 1"))
            #expect(browsed.url == run && browsed.originalURL == Self.ci && browsed.githubTab == .ci && browsed.locked)
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", name: "Renamed"))
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "REPO"))[1] == browsed)

            let other = "https://github.com/owner/other"
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .set(other)))
            let moved = try await h.connection.call(WebTabsList.self, .init(projectID: "REPO"))
            #expect(moved.map(\.id) == tabs.map(\.id))
            #expect(moved.map(\.url) == [other, other + "/actions"])
            #expect(moved.map(\.originalURL) == [other, other + "/actions"])
            #expect(moved.map(\.title) == ["owner/other", "Actions · owner/other"])
        }
    }

    @Test("The GitHub tabs cannot be closed, unlocked or moved, and no tab moves or opens before them")
    func refusals() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .set(Self.page)))
            let docs = try await h.connection.call(WebTabsOpen.self, .init(projectID: "REPO", url: "https://example.com/", index: 0))
            let tabs = try await h.connection.call(WebTabsList.self, .init(projectID: "REPO"))
            #expect(tabs.map(\.id).last == docs.id && tabs.count == 3)
            for tab in tabs.prefix(2) {
                for actor in [Actor.user(deviceID: h.engine.deviceID), h.claude, .system] {
                    #expect(await engineError { try await h.call(WebTabsClose.self, .init(projectID: "REPO", tabID: tab.id), as: actor) }
                        == Self.locked)
                    for index in [0, 1, 2] {
                        #expect(await engineError {
                            try await h.call(WebTabsMove.self, .init(projectID: "REPO", tabID: tab.id, toIndex: index), as: actor)
                        } == Self.locked)
                    }
                }
                #expect(await engineError { try await h.connection.call(WebTabsUpdate.self, .init(projectID: "REPO", tabID: tab.id, locked: false)) }
                    == Self.locked)
                #expect(await engineError { try await h.call(WebTabsUpdate.self, .init(projectID: "REPO", tabID: tab.id, locked: false), as: .system) }
                    == Self.locked)
                #expect(await engineError { try await h.call(WebTabsUpdate.self, .init(projectID: "REPO", tabID: tab.id, locked: false), as: h.claude) }
                    == EngineError(.forbidden, "Only the user can unlock a tab."))
            }
            for index in [0, 1, -3] {
                #expect(await engineError { try await h.connection.call(WebTabsMove.self, .init(projectID: "REPO", tabID: docs.id, toIndex: index)) }
                    == Self.locked)
            }
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "REPO")) == tabs)

            // Navigating, renaming and locking again are allowed; the original URL stays.
            let navigated = try await h.call(WebTabsUpdate.self, .init(projectID: "REPO", tabID: tabs[0].id, url: Self.page + "/pulls",
                                                                       title: "Pulls", locked: true), as: h.claude)
            #expect(navigated.url == Self.page + "/pulls" && navigated.title == "Pulls" && navigated.originalURL == Self.page)
            #expect(navigated.locked && navigated.githubTab == .page)

            // A duplicate of a GitHub tab opens right after the CI tab, as an ordinary tab.
            let duplicate = try await h.connection.call(WebTabsOpen.self, .init(projectID: "REPO", url: Self.page, title: "owner/name", index: 1))
            #expect(duplicate.githubTab == nil && !duplicate.locked)
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "REPO")).map(\.id)
                == [tabs[0].id, tabs[1].id, duplicate.id, docs.id])
            let moved = try await h.connection.call(WebTabsMove.self, .init(projectID: "REPO", tabID: docs.id, toIndex: 2))
            #expect(moved.map(\.id) == [tabs[0].id, tabs[1].id, docs.id, duplicate.id])
            _ = try await h.connection.call(WebTabsClose.self, .init(projectID: "REPO", tabID: duplicate.id))
        }
    }

    @Test("A sub project with an inherited page has its own two tabs; with its own settings it follows its own page")
    func subProject() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            try await h.create("Top", name: "Top", identifier: "TOP")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "TOP", githubPage: .set(Self.page)))
            let sub = try await h.create("Top/sub", name: "Sub", identifier: "SUB", parentID: "TOP")
            #expect(sub.project.webTabs.map(\.url) == [Self.page, Self.ci])
            let stored = try ProjectFileStore.readProject(ProjectFolder(root: URL(fileURLWithPath: h.path("Top/sub"))))
            #expect(stored.webTabs.map(\.githubTab) == [.page, .ci])
            let top = try await h.connection.call(WebTabsList.self, .init(projectID: "TOP"))
            #expect(top.map(\.url) == [Self.page, Self.ci])
            #expect(Set(top.map(\.id)).isDisjoint(with: stored.webTabs.map(\.id)))

            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "SUB", useParentSettings: false))
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "SUB")).isEmpty)
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "TOP")) == top)
            let own = "https://github.com/owner/sub"
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "SUB", githubPage: .set(own)))
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "SUB")).map(\.url) == [own, own + "/actions"])
        }
    }

    @Test("At load a typed page gives the tabs, and a project without a page loses its GitHub tabs once its origin is read")
    func atLoad() async throws {
        let tabsYAML = Self.storedTabsYAML(extra: "- id: 7C9E6679-7425-40DE-944B-E07FC1F90AE7\n  url: https://example.com/\n")
        try await withDomainEngine(prepare: { directory, projects in
            let typed = projects.appendingPathComponent("Typed")
            try writeFile(projectYAML(id: "TYPED", name: "Typed", extra: "githubPage: \(Self.page)\n"),
                          to: typed.appendingPathComponent(".hephaestus/project.yml"))
            let lost = projects.appendingPathComponent("Lost")
            try writeFile(projectYAML(id: "LOST", name: "Lost", extra: tabsYAML), to: lost.appendingPathComponent(".hephaestus/project.yml"))
            try writeFile(registryYAML([typed.path, lost.path]), to: directory.registryFile)
        }) { h in
            let typed = try await h.connection.call(WebTabsList.self, .init(projectID: "TYPED"))
            #expect(typed.map(\.url) == [Self.page, Self.ci])
            #expect(typed.map(\.githubTab) == [.page, .ci])
            await h.engine.useFileTools(try GitHubPageTests.fakeTools(in: h.folder))
            let lost = try await Self.tabs(h, "LOST") { $0.count == 1 }
            #expect(lost.map(\.url) == ["https://example.com/"])
        }
    }

    @Test("While the page depends on an SSH host alias whose ssh -G run has not ended, the tabs stay as they are")
    func unknownPage() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(try GitHubPageTests.fakeTools(in: h.folder))
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            try GitHubPageTests.setOrigin("https://github.com/owner/name.git", h, "Repo")
            let tabs = try await Self.tabs(h, "REPO") { $0.count == 2 }

            // The run of `ssh -G github-slow` lasts until the test ends it.
            await h.engine.testHoldSSH("github-slow")
            let alias = "git\(GitHubPageTests.at)github-slow:owner/name.git"
            try GitHubPageTests.setOrigin(alias, h, "Repo")
            let read = try await GitHubPageTests.detail(h, "REPO") { $0.gitRemoteURL == alias }
            #expect(read.githubPage == nil)
            #expect(read.project.webTabs == tabs)
            await h.engine.testEndSSH("github-slow", hostName: "gitlab.example.com")
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "REPO")).isEmpty)
        }
    }

    @Test("At launch the GitHub tabs of a page that comes from the origin stay as they are until the origin is read")
    func keptUntilRead() async throws {
        let git = try #require(await CodeSearchTests.git())
        try await withTemporaryDirectory { (folder: URL) async throws in
            let repo = folder.appendingPathComponent("Repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            for arguments in [["init", "-q"], ["remote", "add", "origin", "https://github.com/owner/name.git"]] {
                let request = ChildProcessRequest(executable: git.executable, arguments: ["-C", repo.path] + arguments,
                                                  environment: git.environment)
                #expect(try await ChildProcessRunner.run(request, timeout: waitLimit).termination.isSuccess)
            }
            try await withDomainEngine(prepare: { directory, _ in
                try writeFile(projectYAML(id: "REPO", name: "Repo", extra: Self.storedTabsYAML(titles: ["Home", "My CI"])),
                              to: repo.appendingPathComponent(".hephaestus/project.yml"))
                try writeFile(registryYAML([repo.path]), to: directory.registryFile)
            }) { h in
                await h.engine.useFileTools(FileTools(environment: git.environment, git: git.executable))
                let read = try await GitHubPageTests.detail(h, "REPO") { $0.githubPage == Self.page }
                #expect(read.githubPage == Self.page)
                #expect(read.project.webTabs.map(\.id) == Self.storedIDs)
                #expect(read.project.webTabs.map(\.title) == ["Home", "My CI"])
            }
        }
    }

    @Test("A project removed while its origin is read keeps its GitHub tabs when it is opened again")
    func reopenedWhileRead() async throws {
        try await withDomainEngine { h in
            // A git that waits for the file `gate` while the file `hold` exists in the folder it runs in.
            let git = try writeScript(h.folder.appendingPathComponent("bin/git"), """
                if [ -f hold ]; then while [ ! -f gate ]; do sleep 0.05; done; fi
                if [ "$1" = config ] && [ -f origin-url ]; then cat origin-url; exit 0; fi
                exit 1
                """)
            await h.engine.useFileTools(FileTools(environment: ["PATH": "/usr/bin:/bin"], git: git))
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            try GitHubPageTests.setOrigin("https://github.com/owner/name.git", h, "Repo")
            let tabs = try await Self.tabs(h, "REPO") { $0.count == 2 }

            let root = h.projects.appendingPathComponent("Repo")
            try writeFile("", to: root.appendingPathComponent("hold"))
            _ = try await h.connection.call(ProjectsGet.self, .init(projectID: "REPO"))
            _ = try await h.connection.call(ProjectsRemove.self, .init(projectID: "REPO"))
            try writeFile("", to: root.appendingPathComponent("gate"))
            let deadline = ContinuousClock.now + waitLimit
            while await h.engine.testReadsGitRemote(root.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent("hold"))

            _ = try await h.connection.call(ProjectsOpen.self, .init(rootPath: root.path))
            let reopened = try await GitHubPageTests.detail(h, "REPO") { $0.githubPage == Self.page }
            #expect(reopened.project.webTabs == tabs)
        }
    }

    @Test("A parent's page and its sub project's file changed outside the app together keep both changes")
    func changedTogether() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            try await h.create("Top", name: "Top", identifier: "TOP")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "TOP", githubPage: .set(Self.page)))
            try await h.create("Top/sub", name: "Sub", identifier: "SUB", parentID: "TOP")
            let topFolder = ProjectFolder(root: URL(fileURLWithPath: h.path("Top")))
            let subFolder = ProjectFolder(root: URL(fileURLWithPath: h.path("Top/sub")))
            // As a git pull writes both files before the engine reads either.
            let other = "https://github.com/owner/other"
            var top = try ProjectFileStore.readProject(topFolder)
            top.githubPage = other
            var sub = try ProjectFileStore.readProject(subFolder)
            sub.name = "Pulled"
            try writeFile(try YAMLCoding.encode(top), to: topFolder.projectFile)
            try writeFile(try YAMLCoding.encode(sub), to: subFolder.projectFile)

            await h.engine.projectDataFilesChanged(projectID: "TOP", paths: [".hephaestus/project.yml"])
            // The check did not write the sub project's file over its change.
            #expect(try ProjectFileStore.readProject(subFolder) == sub)
            await h.engine.projectDataFilesChanged(projectID: "SUB", paths: [".hephaestus/project.yml"])
            let reloaded = try ProjectFileStore.readProject(subFolder)
            #expect(reloaded.name == "Pulled")
            #expect(reloaded.webTabs.map(\.url) == [other, other + "/actions"])
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "SUB")).project == reloaded)
            #expect(try ProjectFileStore.readProject(topFolder).webTabs.map(\.url) == [other, other + "/actions"])
        }
    }

    @Test("An edit outside the app that removes or moves a GitHub tab is put back")
    func externalEdit() async throws {
        try await withDomainEngine { h in
            await h.engine.useFileTools(FileTools(environment: [:]))
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .set(Self.page)))
            let tabs = try await h.connection.call(WebTabsList.self, .init(projectID: "REPO"))
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Repo")))
            var project = try ProjectFileStore.readProject(folder)
            let docs = WebTab(id: UUID(), url: "https://example.com/")
            project.webTabs = [docs, tabs[1]]
            try writeFile(try YAMLCoding.encode(project), to: folder.projectFile)
            let events = await DomainEventRecorder.make(h)
            await h.engine.projectDataFilesChanged(projectID: "REPO", paths: [".hephaestus/project.yml"])
            let kept = try await h.connection.call(WebTabsList.self, .init(projectID: "REPO"))
            #expect(kept.map(\.githubTab) == [.page, .ci, nil])
            #expect(kept[0].url == Self.page && kept[0].id != tabs[0].id)
            #expect(kept[1] == tabs[1] && kept[2] == docs)
            #expect(try ProjectFileStore.readProject(folder).webTabs == kept)
            #expect(await events.wait(for: ProjectUpdatedEvent.name, count: 2)
                == ["project.updated", "webTabs.updated", "webTabs.updated", "project.updated"])
            #expect(events.all.allSatisfy { $0.origin == .system })
        }
    }

    @Test("Claude lists the GitHub tabs with their marker and cannot close or move them")
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
            try await h.create("Repo", name: "Repo", identifier: "REPO")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "REPO", githubPage: .set(Self.page)))
            let listed = try jsonValue(try await call("list_web_tabs", #"{"projectID":"REPO"}"#).get())
            #expect(listed.arrayValue?.map { $0.objectValue?["githubTab"] } == [.string("page"), .string("ci")])
            let locked = MCPToolError(code: .forbidden, message: "This tab is locked.")
            for tab in try await h.connection.call(WebTabsList.self, .init(projectID: "REPO")) {
                let id = tab.id.uuidString
                #expect(try await call("close_web_tab", #"{"projectID":"REPO","tabID":"\#(id)"}"#) == .failure(locked))
                #expect(try await call("move_web_tab", #"{"projectID":"REPO","tabID":"\#(id)","toIndex":1}"#) == .failure(locked))
            }
        }
    }
}
