import Foundation
import Testing
@testable import HephaestusCore

/// projects.list, projects.get, projects.create, projects.open, projects.update and
/// projects.remove through `LocalEngineConnection` (docs/engine-api.md › Projects,
/// docs/projects.md).
@Suite("Projects")
struct ProjectsTests {
    @Test("projects.create writes the project file and .gitignore, registers the root and emits the events")
    func createTopLevel() async throws {
        try await withDomainEngine { h in
            let events = await DomainEventRecorder.make(h)
            let detail = try await h.connection.call(ProjectsCreate.self, .init(
                rootPath: h.path("Website/./sub/.."), name: "  Website  ", identifier: "web", createDirectory: true))
            #expect(detail.project.id == "WEB")
            #expect(detail.project.name == "Website")
            #expect(detail.rootPath == h.path("Website"))
            #expect(detail.parentID == nil)
            #expect(detail.subprojects.isEmpty)
            #expect(detail.gitRemoteURL == nil)
            #expect(detail.project.nextTicketNumber == 1 && detail.project.docsPath == "docs")
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Website")))
            #expect(try readFile(folder.gitignoreFile) == "chats/\n")
            #expect(try ProjectFileStore.readProject(folder) == detail.project)
            let registry = try ProjectFileStore.decodeYAML(Registry.self, at: DataDirectory(url: h.folder.appendingPathComponent("Data")).registryFile)
            #expect(registry.projects == [h.path("Website")])
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "projects.changed"])
            let changed = try events.all.last!.payload(ProjectsChangedEvent.self)
            #expect(changed == [ProjectSummary(id: "WEB", name: "Website", rootPath: h.path("Website"))])
            #expect(events.all.allSatisfy { $0.origin == .user(deviceID: h.engine.deviceID) })
            #expect(try await h.connection.call(ProjectsList.self) == changed)
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "web")) == detail)
        }
    }

    @Test("projects.create stores the given project type, none when absent")
    func createWithType() async throws {
        try await withDomainEngine { h in
            let plain = try await h.connection.call(ProjectsCreate.self, .init(
                rootPath: h.path("Website"), name: "Website", identifier: "WEB", createDirectory: true))
            #expect(plain.project.type == .none)
            let service = try await h.connection.call(ProjectsCreate.self, .init(
                rootPath: h.path("Api"), name: "Api", identifier: "API", type: .goService, createDirectory: true))
            #expect(service.project.type == .goService)
            #expect(try ProjectFileStore.readProject(ProjectFolder(root: URL(fileURLWithPath: h.path("Api")))).type == .goService)
            #expect(try await h.connection.call(ProjectsList.self).map(\.type) == [.none, .goService])
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "API")).project.type == .goService)
        }
    }

    @Test("create_project, update_project and get_project set and return the type through the engine")
    func typeThroughMCP() async throws {
        try await withDomainEngine { h in
            let engine = h.engine
            let handlers = MCPToolHandlers(engineCall: { method, params, actor in
                try await engine.dispatch(method: method, params: params, actor: actor)
            }, debugUI: nil, homeDirectory: "/Users/example")
            func call(_ tool: String, _ arguments: String) async throws -> String {
                let definition = try #require(MCPToolCatalog.tool(named: tool, debugTools: false))
                return try await handlers.call(definition, arguments: try jsonValue(arguments), actor: h.claude).get()
            }
            func type(_ projectID: ProjectID) async throws -> ProjectType {
                let text = try await call("get_project", #"{"projectID":"\#(projectID)"}"#)
                return try EngineJSON.decoder().decode(ProjectsGet.Result.self, from: Data(text.utf8)).project.type
            }
            _ = try await call("create_project", #"{"path":"\#(h.path("Api"))","name":"Api","identifier":"API","type":"goService"}"#)
            #expect(try await type("API") == .goService)
            _ = try await call("update_project", #"{"projectID":"API","type":"swiftApplication"}"#)
            #expect(try await type("API") == .swiftApplication)
            _ = try await call("create_project", #"{"path":"\#(h.path("Web"))","name":"Web","identifier":"WEB"}"#)
            #expect(try await type("WEB") == .none)
        }
    }

    @Test("projects.create refuses invalid params, used identifiers, files and existing projects")
    func createErrors() async throws {
        try await withDomainEngine { h in
            func create(_ rootPath: String, _ name: String = "Name", identifier: String = "ABC", parentID: ProjectID? = nil,
                        createDirectory: Bool = true) async -> EngineError? {
                await engineError {
                    try await h.connection.call(ProjectsCreate.self, .init(rootPath: rootPath, name: name, identifier: identifier,
                                                                         parentID: parentID, createDirectory: createDirectory))
                }
            }
            #expect(await create("relative/path")?.code == .invalid)
            #expect(await create(h.path("A"), identifier: "A1") == EngineError(.invalid, "identifier: use 2 to 8 letters A–Z."))
            #expect(await create(h.path("A"), identifier: "ABCDEFGHI")?.code == .invalid)
            #expect(await create(h.path("A"), "")?.code == .invalid)
            #expect(await create(h.path("A"), "Two\nlines")?.code == .invalid)
            #expect(await create(h.path("A/.hephaestus/x"))?.code == .invalid)
            try writeFile("text", to: h.projects.appendingPathComponent("file"))
            #expect(await create(h.path("file"))?.code == .invalid)
            #expect(await create(h.path("Missing"), createDirectory: false) == EngineError(.notFound, "Folder \(h.path("Missing")) not found."))
            #expect(!FileManager.default.fileExists(atPath: h.path("Missing")))
            #expect(await create(h.path("A"), parentID: "NOPE") == EngineError(.notFound, "Project NOPE not found."))
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            #expect(await create(h.path("B"), identifier: "heph") == EngineError(.conflict, "Identifier HEPH is already used by Hephaestus V2."))
            #expect(await create(h.path("Other"), parentID: "HEPH")?.code == .invalid)
            #expect(!FileManager.default.fileExists(atPath: h.path("Other")))
            #expect(await create(h.path("Heph"), identifier: "NEW")
                == EngineError(.conflict, "\(h.path("Heph")) already contains a project; open it instead."))
        }
    }

    @Test("projects.create in an existing folder keeps its .gitignore lines and appends chats/")
    func createInExistingFolder() async throws {
        try await withDomainEngine { h in
            let root = h.projects.appendingPathComponent("Existing")
            try writeFile("attachments/", to: root.appendingPathComponent(".hephaestus/.gitignore"))
            let detail = try await h.connection.call(ProjectsCreate.self, .init(rootPath: root.path, name: "Existing",
                                                                              identifier: "EX", createDirectory: false))
            #expect(detail.project.id == "EX")
            #expect(try readFile(root.appendingPathComponent(".hephaestus/.gitignore")) == "attachments/\nchats/\n")
        }
    }

    @Test("A project created inside a loaded project becomes its sub project")
    func createSubProjects() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let events = await DomainEventRecorder.make(h)
            let site = try await h.create("Heph/site", name: "Website", identifier: "SITE")
            #expect(site.parentID == "HEPH")
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "project.updated", "projects.changed"])
            #expect(try events.all[0].payload(ProjectUpdatedEvent.self).project.id == "SITE")
            #expect(try events.all[1].payload(ProjectUpdatedEvent.self).project.subprojects == ["site"])
            let api = try await h.create("Heph/backend/api", name: "API", identifier: "API", parentID: "HEPH")
            #expect(api.parentID == "HEPH")
            let deep = try await h.create("Heph/site/blog", name: "Blog", identifier: "BLOG")
            #expect(deep.parentID == "SITE")
            let heph = try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH"))
            #expect(heph.project.subprojects == ["site", "backend/api"])
            #expect(heph.subprojects.map(\.id) == ["SITE", "API"])
            let list = try await h.connection.call(ProjectsList.self)
            #expect(list.map(\.id) == ["HEPH", "SITE", "BLOG", "API"])
            #expect(list.map(\.parentID) == [nil, "HEPH", "SITE", "HEPH"])
            #expect(list[0].subprojectIDs == ["SITE", "API"])
            let registry = await h.engine.testDomain.registry
            #expect(registry.projects == [h.path("Heph")])
            #expect(await h.engine.testDomain.loadedProjectIDs() == ["HEPH", "SITE", "BLOG", "API"])
        }
    }

    @Test("projects.open registers an existing project, inside a loaded project as its sub project")
    func open() async throws {
        try await withDomainEngine { h in
            let website = h.projects.appendingPathComponent("Website")
            try writeFile(projectYAML(id: "WEB", name: "Website"), to: website.appendingPathComponent(".hephaestus/project.yml"))
            try writeFile(ticketYAML(id: "WEB-3", title: "Open me"), to: website.appendingPathComponent(".hephaestus/ticket/WEB-3.yml"))
            let events = await DomainEventRecorder.make(h)
            let detail = try await h.connection.call(ProjectsOpen.self, .init(rootPath: website.path + "/"))
            #expect(detail.project.id == "WEB" && detail.rootPath == website.path && detail.parentID == nil)
            #expect(try readFile(website.appendingPathComponent(".hephaestus/.gitignore")) == "chats/\n")
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "projects.changed"])
            #expect(try await h.connection.call(TicketsList.self, .init(projectID: "WEB")).map(\.id) == ["WEB-3"])
            #expect(await h.engine.testDomain.registry.projects == [website.path])

            // An already loaded root is returned unchanged, without events.
            events.clear()
            #expect(try await h.connection.call(ProjectsOpen.self, .init(rootPath: website.path)) == detail)
            #expect(await events.settle().isEmpty)

            // A folder inside a loaded project becomes its sub project.
            let blog = website.appendingPathComponent("blog")
            try writeFile(projectYAML(id: "BLOG", name: "Blog"), to: blog.appendingPathComponent(".hephaestus/project.yml"))
            let opened = try await h.connection.call(ProjectsOpen.self, .init(rootPath: blog.path))
            #expect(opened.parentID == "WEB")
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "WEB")).project.subprojects == ["blog"])
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "project.updated", "projects.changed"])
            #expect(try events.all[0].payload(ProjectUpdatedEvent.self).project.id == "WEB")
        }
    }

    @Test("projects.open of a parent removes the registry entries of its listed sub projects")
    func openAdoptsTopLevelProjects() async throws {
        try await withDomainEngine { h in
            let parent = h.projects.appendingPathComponent("Parent")
            let child = parent.appendingPathComponent("apps/child")
            try writeFile(projectYAML(id: "CHILD", name: "Child"), to: child.appendingPathComponent(".hephaestus/project.yml"))
            _ = try await h.connection.call(ProjectsOpen.self, .init(rootPath: child.path))
            try writeFile(projectYAML(id: "PAR", name: "Parent", subprojects: ["apps/child", "missing"]),
                          to: parent.appendingPathComponent(".hephaestus/project.yml"))
            let detail = try await h.connection.call(ProjectsOpen.self, .init(rootPath: parent.path))
            #expect(detail.subprojects.map(\.id) == ["CHILD"])
            #expect(await h.engine.testDomain.registry.projects == [parent.path])
            let list = try await h.connection.call(ProjectsList.self)
            #expect(list.map(\.id) == ["PAR", "CHILD"])
            #expect(list[1].parentID == "PAR")
        }
    }

    @Test("projects.open fails without a project, with an invalid file or with a used identifier")
    func openErrors() async throws {
        try await withDomainEngine { h in
            #expect(await engineError { try await h.connection.call(ProjectsOpen.self, .init(rootPath: "relative")) }?.code == .invalid)
            #expect(await engineError { try await h.connection.call(ProjectsOpen.self, .init(rootPath: h.path("None"))) }?.code == .notFound)
            try FileManager.default.createDirectory(at: h.projects.appendingPathComponent("Empty"), withIntermediateDirectories: true)
            #expect(await engineError { try await h.connection.call(ProjectsOpen.self, .init(rootPath: h.path("Empty"))) }
                == EngineError(.notFound, "No project at \(h.path("Empty"))."))
            try writeFile("schema: 1\nid: BAD\ncreated: 2026-10-31T12:00:00Z\n",
                          to: h.projects.appendingPathComponent("Bad/.hephaestus/project.yml"))
            let invalid = await engineError { try await h.connection.call(ProjectsOpen.self, .init(rootPath: h.path("Bad"))) }
            #expect(invalid?.code == .invalid)
            #expect(invalid?.message.contains("name") == true)
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try writeFile(projectYAML(id: "HEPH", name: "Copy"), to: h.projects.appendingPathComponent("Copy/.hephaestus/project.yml"))
            #expect(await engineError { try await h.connection.call(ProjectsOpen.self, .init(rootPath: h.path("Copy"))) }
                == EngineError(.conflict, "Identifier HEPH is already used by Hephaestus V2."))
            try writeFile(projectYAML(id: "OUT", name: "Outer", subprojects: ["inner"]), to: h.projects.appendingPathComponent("Outer/.hephaestus/project.yml"))
            try writeFile(projectYAML(id: "HEPH", name: "Inner"), to: h.projects.appendingPathComponent("Outer/inner/.hephaestus/project.yml"))
            #expect(await engineError { try await h.connection.call(ProjectsOpen.self, .init(rootPath: h.path("Outer"))) }?.code == .conflict)
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["HEPH"])
        }
    }

    @Test("projects.update changes the given fields and emits project.updated, projects.changed for a new name")
    func update() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let events = await DomainEventRecorder.make(h)
            let detail = try await h.connection.call(ProjectsUpdate.self, .init(
                projectID: "heph", docsPath: "documentation/", commands: ProjectCommands(build: "  make build ", run: "  ", test: nil),
                chatDefaults: .set(ChatSettings(model: "opus", effort: .xhigh))))
            #expect(detail.project.docsPath == "documentation")
            #expect(detail.project.commands == ProjectCommands(build: "make build"))
            #expect(detail.project.chatDefaults == ChatSettings(model: "opus", effort: .xhigh))
            #expect(await events.wait(for: ProjectUpdatedEvent.name) == ["project.updated"])
            #expect(await events.settle() == ["project.updated"])

            events.clear()
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", name: "Forge"))
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "projects.changed"])
            events.clear()
            let same = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", name: "Forge"))
            #expect(same.project.name == "Forge")
            #expect(await events.settle().isEmpty)

            events.clear()
            let typed = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", type: .swiftApplication))
            #expect(typed.project.type == .swiftApplication)
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "projects.changed"])
            let summaries = try events.all.last!.payload(ProjectsChangedEvent.self)
            #expect(summaries.first?.type == .swiftApplication)

            let cleared = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", chatDefaults: .clear))
            #expect(cleared.project.chatDefaults == nil)
            let stored = try ProjectFileStore.readProject(ProjectFolder(root: URL(fileURLWithPath: h.path("Heph"))))
            #expect(stored == cleared.project)
        }
    }

    @Test("projects.update sets the color in uppercase, clears it with null and emits projects.changed with it, for the user and Claude")
    func updateColor() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let events = await DomainEventRecorder.make(h)
            let set = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", color: .set("#13284D")))
            #expect(set.project.color == "#13284D")
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "projects.changed"])
            #expect(try events.all.last!.payload(ProjectsChangedEvent.self).first?.color == "#13284D")
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Heph")))
            #expect(try String(contentsOf: folder.projectFile, encoding: .utf8).contains("color: '#13284D'\n"))

            events.clear()
            let lowercase = try await h.call(ProjectsUpdate.self, .init(projectID: "HEPH", color: .set("#ffd60a")), as: h.claude)
            #expect(lowercase.project.color == "#FFD60A")
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "projects.changed"])
            events.clear()
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", color: .set("#FFD60A")))
            #expect(await events.settle().isEmpty)

            let invalidColor = EngineError(.invalid, "color: use a color of the form #RRGGBB.")
            for invalid in ["", "#12345", "#GGGGGG", "red", " #FFD60A"] {
                let params = ProjectsUpdate.Params(projectID: "HEPH", color: .set(invalid))
                #expect(await engineError { try await h.connection.call(ProjectsUpdate.self, params) } == invalidColor)
                #expect(await engineError { try await h.call(ProjectsUpdate.self, params, as: h.claude) } == invalidColor)
            }

            let cleared = try await h.call(ProjectsUpdate.self, .init(projectID: "HEPH", color: .clear), as: h.claude)
            #expect(cleared.project.color == nil)
            #expect(try !String(contentsOf: folder.projectFile, encoding: .utf8).contains("color"))
            #expect(try await h.connection.call(ProjectsList.self).first?.color == nil)
        }
    }

    @Test("projects.update refuses invalid values and chat defaults from Claude")
    func updateErrors() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            func update(_ params: ProjectsUpdate.Params) async -> EngineError? {
                await engineError { try await h.connection.call(ProjectsUpdate.self, params) }
            }
            #expect(await update(.init(projectID: "HEPH", name: " "))?.code == .invalid)
            #expect(await update(.init(projectID: "HEPH", docsPath: "../docs"))?.code == .invalid)
            #expect(await update(.init(projectID: "HEPH", docsPath: "/docs"))?.code == .invalid)
            #expect(await update(.init(projectID: "HEPH", docsPath: ".hephaestus/docs"))?.code == .invalid)
            #expect(await update(.init(projectID: "HEPH", docsPath: ""))?.code == .invalid)
            #expect(await update(.init(projectID: "HEPH", chatDefaults: .set(ChatSettings(model: "two words"))))?.code == .invalid)
            #expect(await update(.init(projectID: "NONE", name: "X")) == EngineError(.notFound, "Project NONE not found."))
            #expect(await update(.init(projectID: "1", name: "X")) == EngineError(.invalid, "projectID: use 2 to 8 letters A–Z."))
            let claude = await engineError {
                try await h.call(ProjectsUpdate.self, .init(projectID: "HEPH", chatDefaults: .clear), as: h.claude)
            }
            #expect(claude == EngineError(.forbidden, "Claude cannot change chat defaults."))
            let renamed = try await h.call(ProjectsUpdate.self, .init(projectID: "HEPH", name: "By Claude"), as: h.claude)
            #expect(renamed.project.name == "By Claude")
            let typed = try await h.call(ProjectsUpdate.self, .init(projectID: "HEPH", type: .goService), as: h.claude)
            #expect(typed.project.type == .goService)
        }
    }

    @Test("projects.remove unregisters the project and its descendants and leaves their files")
    func remove() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.create("Heph/site", name: "Website", identifier: "SITE")
            try await h.create("Heph/site/blog", name: "Blog", identifier: "BLOG")
            try await h.create("Other", name: "Other", identifier: "OTH")
            try await h.ticket("SITE")
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(ProjectsRemove.self, .init(projectID: "SITE"))
            #expect(await events.wait(for: ProjectsChangedEvent.name)
                == ["project.removed", "project.removed", "project.updated", "projects.changed"])
            #expect(try events.all.prefix(2).map { try $0.payload(ProjectRemovedEvent.self).projectID } == ["SITE", "BLOG"])
            #expect(try events.all[2].payload(ProjectUpdatedEvent.self).project.subprojects.isEmpty)
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["HEPH", "OTH"])
            #expect(FileManager.default.fileExists(atPath: h.path("Heph/site/.hephaestus/ticket/SITE-1.yml")))
            #expect(await engineError { try await h.connection.call(TicketsList.self, .init(projectID: "SITE")) }?.code == .notFound)

            events.clear()
            _ = try await h.connection.call(ProjectsRemove.self, .init(projectID: "HEPH"))
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.removed", "projects.changed"])
            #expect(await h.engine.testDomain.registry.projects == [h.path("Other")])
            #expect(await engineError { try await h.connection.call(ProjectsRemove.self, .init(projectID: "HEPH")) }?.code == .notFound)

            // Opening the folder again registers the project with its data.
            _ = try await h.connection.call(ProjectsOpen.self, .init(rootPath: h.path("Heph/site")))
            #expect(try await h.connection.call(TicketsList.self, .init(projectID: "SITE")).map(\.id) == ["SITE-1"])
        }
    }

    @Test("A chat cannot remove its own project or one of its ancestors")
    func removeOwnProject() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.create("Heph/site", name: "Website", identifier: "SITE")
            try await h.create("Heph/site/blog", name: "Blog", identifier: "BLOG")
            let chatID = UUID()
            await h.engine.testUpsertChat(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), projectID: "SITE"))
            let chat = Actor.claude(chatID: chatID.uuidString)
            for id in ["SITE", "HEPH"] {
                #expect(await engineError { try await h.call(ProjectsRemove.self, .init(projectID: id), as: chat) }
                    == EngineError(.forbidden, "A chat cannot remove the project it belongs to."))
            }
            _ = try await h.call(ProjectsRemove.self, .init(projectID: "BLOG"), as: chat)
            _ = try await h.call(ProjectsRemove.self, .init(projectID: "SITE"), as: h.claude)
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["HEPH"])
        }
    }

    @Test("A project skipped because its identifier is used loads once the other project is removed")
    func retryAfterRemoval() async throws {
        try await withDomainEngine(prepare: { directory, projects in
            let first = projects.appendingPathComponent("First").path
            let second = projects.appendingPathComponent("Second").path
            try writeFile(projectYAML(id: "SAME", name: "First"), to: URL(fileURLWithPath: first + "/.hephaestus/project.yml"))
            try writeFile(projectYAML(id: "SAME", name: "Second"), to: URL(fileURLWithPath: second + "/.hephaestus/project.yml"))
            try writeFile(registryYAML([first, second]), to: directory.registryFile)
        }) { h in
            #expect(try await h.connection.call(ProjectsList.self).map(\.name) == ["First"])
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(ProjectsRemove.self, .init(projectID: "SAME"))
            await events.wait(for: ProjectsChangedEvent.name)
            let list = try await h.connection.call(ProjectsList.self)
            #expect(list.map(\.name) == ["Second"])
            #expect(try events.all.last!.payload(ProjectsChangedEvent.self) == list)
        }
    }

    @Test("ProjectDetail.gitRemoteURL is the origin remote of the git work tree, read in the background")
    func gitRemote() async throws {
        try await withDomainEngine { h in
            let tools = await FileTools.lookUp(environment: ProcessInfo.processInfo.environment)
            guard let git = tools.git else { return }
            await h.engine.useFileTools(tools)
            let root = h.projects.appendingPathComponent("Repo")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let environment = tools.environment
            #expect(await GitTool.run(git, ["init", "-q"], in: root.path, environment: environment)?.status == 0)
            #expect(await GitTool.run(git, ["remote", "add", "origin", "https://example.com/first.git"], in: root.path,
                                      environment: environment)?.status == 0)
            let events = await DomainEventRecorder.make(h)
            let url = "https://example.com/repo.git"
            func remoteEvents(_ events: [EngineEventEnvelope]) -> [String?] {
                events.compactMap { try? $0.payload(ProjectUpdatedEvent.self) }.filter { $0.project.id == "REPO" }.map(\.gitRemoteURL)
            }
            // The first ProjectDetail is built before any read of the root.
            let created = try await h.connection.call(ProjectsCreate.self, .init(rootPath: root.path, name: "Repo", identifier: "REPO",
                                                                               createDirectory: false))
            #expect(created.gitRemoteURL == nil)
            let first = await events.wait(timeout: waitLimit) { remoteEvents($0).contains("https://example.com/first.git") }
            let read = first.first { (try? $0.payload(ProjectUpdatedEvent.self))?.gitRemoteURL == "https://example.com/first.git" }
            #expect(read?.origin == .system)
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "REPO")).gitRemoteURL == "https://example.com/first.git")

            // A change is seen at the next ProjectDetail build.
            #expect(await GitTool.run(git, ["remote", "set-url", "origin", url], in: root.path, environment: environment)?.status == 0)
            _ = try await h.connection.call(ProjectsGet.self, .init(projectID: "REPO"))
            await events.wait(timeout: waitLimit) { remoteEvents($0).contains(url) }
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "REPO")).gitRemoteURL == url)
        }
    }
}
