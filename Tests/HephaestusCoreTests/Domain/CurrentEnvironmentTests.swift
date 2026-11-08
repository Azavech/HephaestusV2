import Foundation
import Testing
@testable import HephaestusCore

/// The current working environment of a Go service project, kept by the main device outside
/// `project.yml` (docs/projects.md › Current working environment, docs/engine-api.md ›
/// projects.setCurrentEnvironment, › ProjectDetail, docs/data-model.md › Current environments
/// file).
@Suite("Current working environment")
struct CurrentEnvironmentTests {
    static let local = InheritedEnvironmentsTests.local
    static let staging = InheritedEnvironmentsTests.staging
    static let replay = InheritedEnvironmentsTests.replay

    static func detail(_ h: DomainHarness, _ id: ProjectID) async throws -> ProjectDetail {
        try await InheritedEnvironmentsTests.detail(h, id)
    }

    static func setCurrent(_ h: DomainHarness, _ id: ProjectID, _ name: String) async throws -> ProjectDetail {
        try await h.connection.call(ProjectsSetCurrentEnvironment.self, .init(projectID: id, environment: name))
    }

    /// The choices the file of the data directory holds.
    static func storedChoices(_ h: DomainHarness) throws -> [String: String] {
        try ProjectFileStore.decodeYAML(CurrentEnvironments.self, at: h.engine.dataDirectory.currentEnvironmentsFile).projects
    }

    /// The current working environments of the project.updated events of `id`.
    static func currentEnvironments(_ events: [EngineEventEnvelope], _ id: ProjectID) -> [String?] {
        events.compactMap { try? $0.payload(ProjectUpdatedEvent.self) }.filter { $0.project.id == id }.map(\.currentEnvironment)
    }

    @Test("The first environment is current until the user chooses one; the choice is kept outside project.yml and emits project.updated")
    func choose() async throws {
        try await withDomainEngine { h in
            try await InheritedEnvironmentsTests.makeTree(h)
            #expect(try await Self.detail(h, "API").currentEnvironment == "local")
            #expect(!FileManager.default.fileExists(atPath: h.engine.dataDirectory.currentEnvironmentsFile.path))
            let projectFile = try readFile(InheritedEnvironmentsTests.projectFile(h, "Api"))

            let events = await DomainEventRecorder.make(h)
            let detail = try await Self.setCurrent(h, "API", "staging")
            #expect(detail.currentEnvironment == "staging")
            #expect(detail.currentWorkingEnvironment == Self.staging)
            let received = await events.wait { Self.currentEnvironments($0, "API").count == 1 }
            #expect(Self.currentEnvironments(received, "API") == ["staging"])
            #expect(received.allSatisfy { $0.origin == .user(deviceID: h.engine.deviceID) })
            #expect(try Self.storedChoices(h) == ["API": "staging"])
            #expect(try readFile(InheritedEnvironmentsTests.projectFile(h, "Api")) == projectFile)

            // Each project has its own: the sub project keeps the first.
            #expect(try await Self.detail(h, "WRK").currentEnvironment == "local")
            #expect(await events.settle() == ["project.updated"])

            // The environment already current emits nothing; choosing the first one explicitly keeps it.
            events.clear()
            _ = try await Self.setCurrent(h, "API", "staging")
            _ = try await Self.setCurrent(h, "WRK", "local")
            #expect(await events.settle().isEmpty)
            #expect(try Self.storedChoices(h) == ["API": "staging", "WRK": "local"])
        }
    }

    @Test("projects.setCurrentEnvironment refuses an unknown name, a project of another type and Claude")
    func refusals() async throws {
        try await withDomainEngine { h in
            try await InheritedEnvironmentsTests.makeTree(h)
            try await h.create("Web", name: "Web", identifier: "WEB")
            func error(_ id: ProjectID, _ name: String, as actor: Actor? = nil) async -> EngineError? {
                do {
                    let params = ProjectsSetCurrentEnvironment.Params(projectID: id, environment: name)
                    if let actor {
                        _ = try await h.call(ProjectsSetCurrentEnvironment.self, params, as: actor)
                    } else {
                        _ = try await h.connection.call(ProjectsSetCurrentEnvironment.self, params)
                    }
                    return nil
                } catch {
                    return error as? EngineError
                }
            }
            #expect(await error("API", "Staging") == EngineError(.invalid, "environment: API has no environment named “Staging”."))
            #expect(await error("WEB", "local") == EngineError(.invalid, "environment: WEB has no environment named “local”."))
            #expect(await error("NOPE", "local")?.code == .notFound)
            #expect(await error("API", "staging", as: h.claude)
                == EngineError(.forbidden, "projects.setCurrentEnvironment is not available to claude."))
            #expect(try await Self.detail(h, "API").currentEnvironment == "local")
            #expect(try await Self.detail(h, "WEB").currentEnvironment == nil)
        }
    }

    @Test("A removed current environment gives way to the first, and the choice is forgotten")
    func removal() async throws {
        try await withDomainEngine { h in
            try await InheritedEnvironmentsTests.makeTree(h)
            _ = try await Self.setCurrent(h, "API", "staging")
            let events = await DomainEventRecorder.make(h)
            let detail = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", environments: [Self.local]))
            #expect(detail.currentEnvironment == "local")
            #expect(try Self.storedChoices(h).isEmpty)
            #expect(Self.currentEnvironments(await events.wait { Self.currentEnvironments($0, "API").count == 1 }, "API") == ["local"])

            // An environment that gets the name again does not become current again.
            let again = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", environments: [Self.local, Self.staging]))
            #expect(again.currentEnvironment == "local")

            // The type no longer goService: no current working environment; back, the first.
            _ = try await Self.setCurrent(h, "API", "staging")
            #expect(try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", type: ProjectType.none)).currentEnvironment == nil)
            #expect(try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", type: .goService)).currentEnvironment == "local")
        }
    }

    @Test("A parent's removal and Use parent settings turned off give way to the sub project's first environment")
    func inheritedRemoval() async throws {
        try await withDomainEngine { h in
            try await InheritedEnvironmentsTests.makeTree(h)
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environments: [Self.replay]))
            _ = try await Self.setCurrent(h, "WRK", "staging")
            #expect(try await Self.detail(h, "WRK").currentEnvironment == "staging")

            // The parent removes it: the sub project's first environment is current, with project.updated.
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", environments: [Self.local]))
            let received = await events.wait { Self.currentEnvironments($0, "WRK").count == 1 }
            #expect(Self.currentEnvironments(received, "WRK") == ["local"])
            #expect(try Self.storedChoices(h).isEmpty)

            // Use parent settings turned off: only its own environments apply.
            _ = try await Self.setCurrent(h, "WRK", "local")
            let off = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: false))
            #expect(off.environments == [Self.replay])
            #expect(off.currentEnvironment == "replay")
            #expect(try Self.storedChoices(h).isEmpty)

            // The parent's change outside the app is followed the same way.
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: true))
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", environments: [Self.local, Self.staging]))
            _ = try await Self.setCurrent(h, "WRK", "staging")
            let file = InheritedEnvironmentsTests.projectFile(h, "Api")
            try writeFile(try readFile(file).replacingOccurrences(of: "name: staging", with: "name: stage"), to: file)
            await h.engine.projectDataFilesChanged(projectID: "API", paths: [".hephaestus/project.yml"])
            // A rename outside the app counts as a removal.
            #expect(try await Self.detail(h, "WRK").currentEnvironment == "local")
            #expect(try Self.storedChoices(h).isEmpty)
        }
    }

    @Test("A rename in Project Settings keeps the environment current, in the project and in the sub projects that inherit it")
    func rename() async throws {
        try await withDomainEngine { h in
            try await InheritedEnvironmentsTests.makeTree(h)
            try await h.create("Api/own", name: "Own", identifier: "OWN", parentID: "API")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "OWN", type: .goService, useParentSettings: false,
                                                                       environments: [Self.staging, Self.replay]))
            _ = try await Self.setCurrent(h, "API", "staging")
            _ = try await Self.setCurrent(h, "WRK", "staging")
            _ = try await Self.setCurrent(h, "OWN", "staging")

            var renamed = Self.staging
            renamed.name = "stage"
            let events = await DomainEventRecorder.make(h)
            let detail = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", environments: [Self.local, renamed]))
            #expect(detail.currentEnvironment == "stage")
            let received = await events.wait { Self.currentEnvironments($0, "WRK").count == 1 }
            #expect(Self.currentEnvironments(received, "WRK") == ["stage"])
            #expect(try await Self.detail(h, "WRK").currentEnvironment == "stage")
            // A project that does not inherit it keeps its own environment of that name.
            #expect(try await Self.detail(h, "OWN").currentEnvironment == "staging")
            #expect(try Self.storedChoices(h) == ["API": "stage", "WRK": "stage", "OWN": "staging"])

            // A list of another length is no rename: the removed name gives way to the first.
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", environments: [Self.staging]))
            #expect(try await Self.detail(h, "API").currentEnvironment == "staging")
            #expect(try Self.storedChoices(h)["API"] == nil)
        }
    }

    @Test("Renamed environments are those whose name changed at the same position of a list of the same length")
    func renamedEnvironments() {
        var renamed = Self.staging
        renamed.name = "stage"
        #expect(Engine.renamedEnvironments(from: [Self.local, Self.staging], to: [Self.local, renamed]) == ["staging": "stage"])
        #expect(Engine.renamedEnvironments(from: [Self.local, Self.staging], to: [renamed]).isEmpty)
        #expect(Engine.renamedEnvironments(from: [Self.local], to: [Self.local]).isEmpty)
    }

    @Test("projects.remove forgets the choices of the projects it unregisters")
    func remove() async throws {
        try await withDomainEngine { h in
            try await InheritedEnvironmentsTests.makeTree(h)
            _ = try await Self.setCurrent(h, "API", "staging")
            _ = try await Self.setCurrent(h, "WRK", "staging")
            _ = try await h.connection.call(ProjectsRemove.self, .init(projectID: "WRK"))
            #expect(try Self.storedChoices(h) == ["API": "staging"])
        }
    }

    @Test("get_project gives currentEnvironment; no tool changes it")
    func throughMCP() async throws {
        try await withDomainEngine { h in
            let engine = h.engine
            let handlers = MCPToolHandlers(engineCall: { method, params, actor in
                try await engine.dispatch(method: method, params: params, actor: actor)
            }, debugUI: nil, homeDirectory: "/Users/example")
            let definition = try #require(MCPToolCatalog.tool(named: "get_project", debugTools: false))
            try await InheritedEnvironmentsTests.makeTree(h)
            _ = try await Self.setCurrent(h, "WRK", "staging")
            let text = try await handlers.call(definition, arguments: try jsonValue(#"{"projectID":"WRK"}"#), actor: h.claude).get()
            let json = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue)
            #expect(json["currentEnvironment"] == .string("staging"))
            #expect(!MCPToolCatalog.tools.contains { $0.engineMethod == ProjectsSetCurrentEnvironment.name })

            // Without environments, the key is absent.
            try await h.create("Web", name: "Web", identifier: "WEB")
            let web = try await handlers.call(definition, arguments: try jsonValue(#"{"projectID":"WEB"}"#), actor: h.claude).get()
            #expect(try #require(try JSONDecoder().decode(JSONValue.self, from: Data(web.utf8)).objectValue)["currentEnvironment"] == nil)
        }
    }

    @Test("The file is read at launch; a missing or invalid one gives no choice, and an invalid one is set aside")
    func launch() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            try directory.createIfNeeded()
            #expect(try DeviceFileStore.loadAll(directory, log: nil).currentEnvironments == CurrentEnvironments())
            try DeviceFileStore.write(CurrentEnvironments(projects: ["DEMO": "staging"]), to: directory)
            #expect(try DeviceFileStore.loadAll(directory, log: nil).currentEnvironments.projects == ["DEMO": "staging"])
            try writeFile("projects: [", to: directory.currentEnvironmentsFile)
            #expect(try DeviceFileStore.loadAll(directory, log: nil).currentEnvironments == CurrentEnvironments())
            #expect(FileManager.default.fileExists(atPath: directory.invalidCopy(of: directory.currentEnvironmentsFile).path))
            #expect(!FileManager.default.fileExists(atPath: directory.currentEnvironmentsFile.path))
        }
    }

    @Test("A ProjectDetail without currentEnvironment, from an earlier engine, names the first environment")
    func earlierEngine() throws {
        let detail = ProjectDetail(project: Project(id: "API", name: "API", created: ISODate.now(), type: .goService,
                                                    environments: [Self.local, Self.staging]),
                                   rootPath: "/Users/example/api")
        #expect(detail.currentEnvironment == nil)
        #expect(detail.currentWorkingEnvironment == Self.local)
        var named = detail
        named.currentEnvironment = "staging"
        #expect(named.currentWorkingEnvironment == Self.staging)
        named.currentEnvironment = "gone"
        #expect(named.currentWorkingEnvironment == Self.local)
    }
}
