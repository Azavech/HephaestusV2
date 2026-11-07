import Foundation
import Testing
@testable import HephaestusCore

/// docs/projects.md › HephaestusV2 project: recognition, the launch check and the clone, the
/// retry, the reserved identifier, the removal refusal and the hiding.
@Suite("HephaestusV2 project")
struct HephaestusProjectTests {
    // MARK: Recognition

    @Test("A remote URL names Azavech/HephaestusV2 on any host, SSH host aliases included",
          arguments: [
              ("https://github.com/Azavech/HephaestusV2", true),
              ("https://github.com/azavech/hephaestusv2.git", true),
              ("http://user@example.com:443/Azavech/HephaestusV2/", true),
              ("ssh://git@github-alias:22/Azavech/HephaestusV2.git", true),
              ("git://example.com/Azavech/HephaestusV2", true),
              ("git@github-alias:Azavech/HephaestusV2.git", true),
              ("github-alias:Azavech/HephaestusV2", true),
              ("  git@example.com:Azavech/HephaestusV2.git\n", true),
              ("https://github.com/Azavech/Other", false),
              ("https://gitlab.com/group/Azavech/HephaestusV2", false),
              ("/Users/example/Azavech/HephaestusV2", false),
              ("file:///Users/example/Azavech/HephaestusV2", false),
              ("./Azavech:HephaestusV2", false),
              ("", false),
          ])
    func recognition(url: String, names: Bool) {
        #expect(HephaestusRepository.names(url) == names, "\(url)")
    }

    @Test("The origin is the last url of [remote \"origin\"], comments and quotes removed")
    func configParsing() {
        let text = """
            [core]
            \turl = https://example.com/not/this
            [remote "upstream"]
            \turl = https://github.com/Other/Repo
            [Remote "origin"] ; a comment
            \tURL = "git@github-alias:Azavech/HephaestusV2.git" # the fork
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            [branch "main"]
            \tremote = origin
            """
        #expect(GitConfigFile.originURL(inConfig: text) == "git@github-alias:Azavech/HephaestusV2.git")
        #expect(GitConfigFile.originURL(inConfig: "[remote \"origin2\"]\n\turl = x\n") == nil)
        #expect(GitConfigFile.originURL(inConfig: "") == nil)
    }

    @Test("The origin is read from the repository that holds the root, through .git files and commondir")
    func originOfRoot() throws {
        try withTemporaryDirectory { folder in
            let repository = folder.appendingPathComponent("Repo")
            try Self.writeOrigin("git@github-alias:Azavech/HephaestusV2.git", in: repository)
            let inner = repository.appendingPathComponent("Sources/App")
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            #expect(GitConfigFile.originURL(root: repository.path) == "git@github-alias:Azavech/HephaestusV2.git")
            #expect(GitConfigFile.originURL(root: inner.path) == "git@github-alias:Azavech/HephaestusV2.git")
            // A linked worktree: `.git` is a file whose gitdir has a commondir.
            let worktreeGitDir = repository.appendingPathComponent(".git/worktrees/feature")
            try writeFile("../..\n", to: worktreeGitDir.appendingPathComponent("commondir"))
            let worktree = folder.appendingPathComponent("Worktree")
            try writeFile("gitdir: \(worktreeGitDir.path)\n", to: worktree.appendingPathComponent(".git"))
            #expect(GitConfigFile.originURL(root: worktree.path) == "git@github-alias:Azavech/HephaestusV2.git")
            #expect(HephaestusRepository.isClone(root: worktree.path))
            let plain = folder.appendingPathComponent("Plain")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            #expect(GitConfigFile.originURL(root: plain.path) == nil || !HephaestusRepository.isClone(root: plain.path))
        }
    }

    // MARK: Launch check and clone

    @Test("Without a HephaestusV2 project the engine clones the repository and creates its project.yml")
    func cloneAtLaunch() async throws {
        let git = try #require(await CodeSearchTests.git())
        try await withTemporaryDirectory { (remotes: URL) async throws in
            let remote = try await Self.remoteRepository(git, in: remotes)
            try await withDomainEngine(hephaestusProject: HephaestusProjectConfiguration(cloneURL: remote.path)) { (h: DomainHarness) async throws in
                await h.engine.useFileTools(FileTools(environment: git.environment, git: git.executable))
                let events = await DomainEventRecorder.make(h)
                _ = try await h.connection.call(ProjectsEnsureHephaestus.self)
                try await Self.waitForHephaestus(h.engine)

                let root = DomainPaths.standardize(h.engine.dataDirectory.url.appendingPathComponent("HephaestusV2").path)
                let summary = try #require(try await h.connection.call(ProjectsList.self).first { $0.id == "HEPH" })
                #expect(summary.name == "HephaestusV2")
                #expect(summary.type == .swiftApplication)
                #expect(summary.rootPath == root)
                #expect(summary.parentID == nil)
                let project = try ProjectFileStore.readProject(ProjectFolder(root: URL(fileURLWithPath: root, isDirectory: true)))
                #expect(project.id == "HEPH" && project.name == "HephaestusV2" && project.type == .swiftApplication)
                #expect(project.docsPath == "docs")
                #expect(FileManager.default.fileExists(atPath: root + "/README.md"))
                #expect(FileManager.default.fileExists(atPath: root + "/.hephaestus/.gitignore"))
                #expect(!FileManager.default.fileExists(atPath: h.engine.dataDirectory.url.appendingPathComponent(".HephaestusV2.clone").path))
                // The clone's origin is the repository URL, so that it is recognized as in the app.
                #expect(GitConfigFile.originURL(root: root) == HephaestusRepository.url)
                #expect(await h.engine.testDomain.registry.projects.contains(root))
                await events.wait(for: ProjectsChangedEvent.name)
                #expect(events.names.contains(ProjectUpdatedEvent.name))

                // A HephaestusV2 project is loaded: nothing else happens.
                _ = try await h.connection.call(ProjectsEnsureHephaestus.self)
                await h.engine.waitForHephaestusAttempt()
                #expect(try await h.connection.call(ProjectsList.self).filter { $0.id == "HEPH" }.count == 1)
            }
        }
    }

    @Test("A failed clone leaves nothing behind and the next projects.ensureHephaestus tries again")
    func retryAfterFailure() async throws {
        let git = try #require(await CodeSearchTests.git())
        try await withTemporaryDirectory { (remotes: URL) async throws in
            let missing = remotes.appendingPathComponent("Azavech/HephaestusV2")
            try await withDomainEngine(hephaestusProject: HephaestusProjectConfiguration(cloneURL: missing.path)) { (h: DomainHarness) async throws in
                await h.engine.useFileTools(FileTools(environment: git.environment, git: git.executable))
                _ = try await h.connection.call(ProjectsEnsureHephaestus.self)
                await h.engine.waitForHephaestusAttempt()
                #expect(try await h.connection.call(ProjectsList.self).isEmpty)
                let data = h.engine.dataDirectory.url
                #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("HephaestusV2").path))
                #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent(".HephaestusV2.clone").path))

                _ = try await Self.remoteRepository(git, in: remotes)
                _ = try await h.connection.call(ProjectsEnsureHephaestus.self)
                try await Self.waitForHephaestus(h.engine)
                #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["HEPH"])
            }
        }
    }

    @Test("A registered HEPH clone whose origin uses an SSH host alias is the HephaestusV2 project: no second clone")
    func aliasCloneIsRecognized() async throws {
        try await withDomainEngine(hephaestusProject: Self.unreachable, prepare: { directory, projects in
            let clone = projects.appendingPathComponent("HephaestusV2")
            try Self.writeOrigin("git@github-alias:Azavech/HephaestusV2.git", in: clone)
            try writeFile(projectYAML(id: "HEPH", name: "HephaestusV2"), to: clone.appendingPathComponent(".hephaestus/project.yml"))
            try writeFile(registryYAML([clone.path]), to: directory.registryFile)
        }) { (h: DomainHarness) async throws in
            _ = try await h.connection.call(ProjectsEnsureHephaestus.self)
            await h.engine.waitForHephaestusAttempt()
            let list = try await h.connection.call(ProjectsList.self)
            #expect(list.map(\.id) == ["HEPH"])
            #expect(list.first?.rootPath == h.path("HephaestusV2"))
            #expect(await h.engine.hephaestusProjectID == "HEPH")
            #expect(!FileManager.default.fileExists(atPath: h.engine.dataDirectory.url.appendingPathComponent("HephaestusV2").path))
        }
    }

    @Test("A registered HEPH project whose origin does not name the repository is skipped and its entry kept")
    func foreignHEPHIsSkipped() async throws {
        try await withDomainEngine(hephaestusProject: Self.unreachable, prepare: { directory, projects in
            let other = projects.appendingPathComponent("Other")
            try Self.writeOrigin("https://github.com/example/Other.git", in: other)
            try writeFile(projectYAML(id: "HEPH", name: "Other"), to: other.appendingPathComponent(".hephaestus/project.yml"))
            let clone = projects.appendingPathComponent("Fork")
            try Self.writeOrigin("https://github.com/Azavech/HephaestusV2.git", in: clone)
            try writeFile(projectYAML(id: "FORK", name: "Fork"), to: clone.appendingPathComponent(".hephaestus/project.yml"))
            try writeFile(registryYAML([other.path, clone.path]), to: directory.registryFile)
        }) { (h: DomainHarness) async throws in
            // A clone of the repository with another identifier is a regular project.
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["FORK"])
            #expect(await h.engine.testDomain.registry.projects == [h.path("Other"), h.path("Fork")])
            #expect(await h.engine.hephaestusProjectID == nil)
        }
    }

    // MARK: Reserved identifier

    @Test("HEPH is reserved in projects.create and projects.open, except for a clone of the repository")
    func reservedIdentifier() async throws {
        try await withDomainEngine(hephaestusProject: Self.unreachable) { (h: DomainHarness) async throws in
            let reserved = EngineError(.invalid, "HEPH is reserved for HephaestusV2.")
            #expect(await engineError { try await h.create("Plain", name: "Plain", identifier: "heph") } == reserved)
            #expect(await engineError {
                try await h.call(ProjectsCreate.self, .init(rootPath: h.path("Plain"), name: "Plain", identifier: "HEPH", createDirectory: true),
                                 as: h.claude)
            } == reserved)

            let foreign = h.projects.appendingPathComponent("Foreign")
            try writeFile(projectYAML(id: "HEPH", name: "Foreign"), to: foreign.appendingPathComponent(".hephaestus/project.yml"))
            #expect(await engineError { try await h.connection.call(ProjectsOpen.self, .init(rootPath: foreign.path)) } == reserved)

            let clone = h.projects.appendingPathComponent("HephaestusV2")
            try Self.writeOrigin("git@github-alias:Azavech/HephaestusV2.git", in: clone)
            let detail = try await h.create("HephaestusV2", name: "HephaestusV2", identifier: "HEPH")
            #expect(detail.project.id == "HEPH")
            #expect(await h.engine.hephaestusProjectID == "HEPH")
        }
    }

    // MARK: Removal

    @Test("projects.remove refuses the HephaestusV2 project and its ancestors, for the user and for Claude")
    func removalRefused() async throws {
        try await withDomainEngine(hephaestusProject: Self.unreachable) { (h: DomainHarness) async throws in
            try await h.create("Work", name: "Work", identifier: "WORK")
            try Self.writeOrigin("ssh://github.com/Azavech/HephaestusV2.git", in: h.projects.appendingPathComponent("Work/HephaestusV2"))
            try await h.create("Work/HephaestusV2", name: "HephaestusV2", identifier: "HEPH", parentID: "WORK")
            try await h.create("Other", name: "Other", identifier: "OTHER")
            let refused = EngineError(.forbidden,
                                      "“HephaestusV2” cannot be removed: it is the HephaestusV2 project. Hide it in Settings ▸ General instead.")
            #expect(await engineError { try await h.connection.call(ProjectsRemove.self, .init(projectID: "HEPH")) } == refused)
            #expect(await engineError { try await h.connection.call(ProjectsRemove.self, .init(projectID: "work")) } == refused)
            #expect(await engineError { try await h.call(ProjectsRemove.self, .init(projectID: "HEPH"), as: h.claude) } == refused)
            _ = try await h.connection.call(ProjectsRemove.self, .init(projectID: "OTHER"))
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["WORK", "HEPH"])
        }
    }

    // MARK: Hiding

    @Test("Hiding leaves the HephaestusV2 project and its sub projects out and answers notFound for them")
    func hiding() async throws {
        try await withDomainEngine(hephaestusProject: Self.unreachable) { (h: DomainHarness) async throws in
            try Self.writeOrigin("ssh://github.com/Azavech/HephaestusV2.git", in: h.projects.appendingPathComponent("HephaestusV2"))
            try await h.create("HephaestusV2", name: "HephaestusV2", identifier: "HEPH")
            try await h.create("HephaestusV2/Site", name: "Site", identifier: "SITE", parentID: "HEPH")
            try await h.create("Demo", name: "Demo", identifier: "DEMO")
            let ticket = try await h.ticket("HEPH")
            let events = await DomainEventRecorder.make(h)

            _ = try await h.connection.call(SettingsUpdate.self, .init(showHephaestusProject: false))
            await events.wait(for: ProjectsChangedEvent.name)
            let removed = events.all.filter { $0.name == ProjectRemovedEvent.name }
            #expect(try removed.map { try $0.payload(ProjectRemovedEvent.self).projectID } == ["HEPH", "SITE"])
            let changed = try #require(events.all.last { $0.name == ProjectsChangedEvent.name })
            #expect(try changed.payload(ProjectsChangedEvent.self).map(\.id) == ["DEMO"])

            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["DEMO"])
            #expect(try await h.call(ProjectsList.self, Empty(), as: h.claude).map(\.id) == ["DEMO"])
            #expect(try await h.connection.call(SnapshotGet.self).projects.map(\.id) == ["DEMO"])
            #expect(await engineError { try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")) }
                == EngineError(.notFound, "Project HEPH not found."))
            #expect(await engineError { try await h.call(ProjectsGet.self, .init(projectID: "site"), as: h.claude) }
                == EngineError(.notFound, "Project SITE not found."))
            #expect(await engineError { try await h.call(TicketsGet.self, .init(ticketID: ticket.id), as: h.claude) }
                == EngineError(.notFound, "Ticket \(ticket.id) not found."))
            #expect(await engineError {
                try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: "Something."), as: h.claude)
            } == EngineError(.notFound, "Project HEPH not found."))
            #expect(await engineError { try await h.call(UIOpen.self, .init(target: .project(projectID: "HEPH")), as: h.claude) }
                == EngineError(.notFound, "Project HEPH not found."))
            #expect(await engineError { try await h.connection.call(ProjectsOpen.self, .init(rootPath: h.path("HephaestusV2"))) }
                == EngineError(.conflict, "HephaestusV2 is hidden. Show it in Settings ▸ General."))
            // The engine itself still reaches them, and their events are not emitted.
            #expect(try await h.engine.call(ProjectsGet.self, .init(projectID: "HEPH"), actor: .system).project.id == "HEPH")
            events.clear()
            _ = try await h.engine.call(TicketsUpdate.self, .init(ticketID: ticket.id, title: "Renamed"), actor: .system)
            #expect(await events.settle().isEmpty)
            // HEPH is still reserved and used.
            #expect(await engineError { try await h.create("Copy", name: "Copy", identifier: "HEPH") }?.code == .invalid)

            _ = try await h.connection.call(SettingsUpdate.self, .init(showHephaestusProject: true))
            await events.wait(for: ProjectsChangedEvent.name)
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["HEPH", "SITE", "DEMO"])
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).subprojects.map(\.id) == ["SITE"])
        }
    }

    // MARK: Helpers

    /// A clone URL that cannot be cloned, for the tests that do not clone.
    static let unreachable = HephaestusProjectConfiguration(cloneURL: "/nonexistent/Azavech/HephaestusV2")

    /// A `.git/config` whose origin is `url`.
    static func writeOrigin(_ url: String, in folder: URL) throws {
        try writeFile("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \(url)\n", to: folder.appendingPathComponent(".git/config"))
    }

    /// `<folder>/Azavech/HephaestusV2`, a repository with one commit that stands in for GitHub.
    static func remoteRepository(_ git: SearchGit, in folder: URL) async throws -> URL {
        let remote = folder.appendingPathComponent("Azavech/HephaestusV2")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try await ChatWorktreeTests.run(git, ["init", "-q", "-b", "main"], in: remote)
        try "# HephaestusV2\n".write(to: remote.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await ChatWorktreeTests.commit(git, "README.md", message: "first", in: remote)
        return remote
    }

    /// Waits until the HephaestusV2 project is loaded, the attempts of the launch included.
    static func waitForHephaestus(_ engine: Engine) async throws {
        let deadline = ContinuousClock.now + waitLimit
        while ContinuousClock.now < deadline {
            await engine.waitForHephaestusAttempt()
            if await engine.hephaestusProjectID != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the HephaestusV2 project was not loaded")
    }
}
