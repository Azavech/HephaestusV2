import Foundation
import Testing
@testable import HephaestusCore

/// The environments a sub project inherits from its parent, with its changes, through
/// `LocalEngineConnection` and the MCP tools (docs/projects.md › Inherited environments,
/// docs/data-model.md › Environment override, docs/engine-api.md › projects.update,
/// › ProjectDetail).
@Suite("Inherited environments")
struct InheritedEnvironmentsTests {
    static let local = ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080)
    static let staging = ProjectEnvironment(name: "staging", url: "https://staging.example.com",
                                            namespace: "orders", deployment: "orders-api", argoCDApplication: "argocd/orders-staging",
                                            kubeconfig: "~/.kube/staging.yaml")
    static let replay = ProjectEnvironment(name: "replay", url: "http://127.0.0.1", port: 9090)

    /// The Go service `API` with `local` and `staging`, and its Go service sub project `WRK`.
    static func makeTree(_ h: DomainHarness) async throws {
        try await h.create("Api", name: "Orders API", identifier: "API")
        _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", type: .goService, environments: [local, staging]))
        try await h.create("Api/worker", name: "Orders worker", identifier: "WRK", parentID: "API")
        _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", type: .goService))
    }

    static func detail(_ h: DomainHarness, _ id: ProjectID) async throws -> ProjectDetail {
        try await h.connection.call(ProjectsGet.self, .init(projectID: id))
    }

    static func projectFile(_ h: DomainHarness, _ relative: String) -> URL {
        ProjectFolder(root: URL(fileURLWithPath: h.path(relative))).projectFile
    }

    /// The environments of the project.updated events of `id`.
    static func environments(_ events: [EngineEventEnvelope], _ id: ProjectID) -> [[ProjectEnvironment]] {
        events.compactMap { try? $0.payload(ProjectUpdatedEvent.self) }.filter { $0.project.id == id }.map(\.environments)
    }

    @Test("With Use parent settings on, a sub project has its parent's environments with its changes first, then its own")
    func checkboxOn() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            var worker = try await Self.detail(h, "WRK")
            #expect(worker.project.useParentSettings)
            #expect(worker.environments == [Self.local, Self.staging])
            #expect(worker.inheritedEnvironments == [Self.local, Self.staging])

            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environments: [Self.replay]))
            worker = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environmentOverrides: [
                "local": EnvironmentOverride(port: 8081),
                "staging": EnvironmentOverride(url: "https://worker.staging.example.com", deployment: "orders-worker",
                                               argoCDApplication: "argocd/orders-worker-staging"),
            ]))
            var changedStaging = Self.staging
            changedStaging.url = "https://worker.staging.example.com"
            changedStaging.deployment = "orders-worker"
            changedStaging.argoCDApplication = "argocd/orders-worker-staging"
            var changedLocal = Self.local
            changedLocal.port = 8081
            #expect(worker.environments == [changedLocal, changedStaging, Self.replay])
            #expect(worker.inheritedEnvironments == [Self.local, Self.staging])
            #expect(worker.project.environments == [Self.replay])
            #expect(worker.environments.map(\.baseURL) == ["http://127.0.0.1:8081", "https://worker.staging.example.com", "http://127.0.0.1:9090"])

            // The parent keeps its own values.
            let api = try await Self.detail(h, "API")
            #expect(api.environments == [Self.local, Self.staging])
            #expect(api.inheritedEnvironments.isEmpty)
            #expect(api.project.environmentOverrides.isEmpty)

            // The changes are in the sub project's file, keyed by name in code point order.
            #expect(try readFile(Self.projectFile(h, "Api/worker")).contains("""
                environmentOverrides:
                  local:
                    url: null
                    port: 8081
                    deployment: null
                    argoCDApplication: null
                  staging:
                    url: https://worker.staging.example.com
                    port: null
                    deployment: orders-worker
                    argoCDApplication: argocd/orders-worker-staging
                deletedChats: []

                """))
            #expect(try readFile(Self.projectFile(h, "Api")).contains("environmentOverrides: {}\n"))
        }
    }

    @Test("With Use parent settings off, only its own environments apply and its changes are kept, unused")
    func checkboxOff() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environments: [Self.replay],
                                                                       environmentOverrides: ["local": EnvironmentOverride(port: 8081)]))
            var worker = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: false))
            #expect(worker.environments == [Self.replay])
            #expect(worker.inheritedEnvironments.isEmpty)
            #expect(worker.project.environmentOverrides == ["local": EnvironmentOverride(port: 8081)])
            #expect(try ProjectFileStore.readProject(ProjectFolder(root: URL(fileURLWithPath: h.path("Api/worker"))))
                .environmentOverrides == ["local": EnvironmentOverride(port: 8081)])

            // A top-level project's checkbox has no effect.
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", useParentSettings: false))
            #expect(try await Self.detail(h, "API").environments == [Self.local, Self.staging])

            // On again, the changes apply again.
            worker = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: true))
            #expect(worker.environments.map(\.port) == [8081, nil, 9090])
        }
    }

    @Test("Nested sub projects inherit the environments their parent inherits, with each level's changes")
    func nested() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            try await h.create("Api/worker/jobs", name: "Jobs", identifier: "JOBS", parentID: "WRK")
            let mid = ProjectEnvironment(name: "mid", url: "https://mid.example.com")
            let leaf = ProjectEnvironment(name: "leaf", url: "https://leaf.example.com")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environments: [mid],
                                                                       environmentOverrides: ["local": EnvironmentOverride(port: 9000)]))
            let jobs = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "JOBS", type: .goService, environments: [leaf],
                                                                              environmentOverrides: [
                                                                                  "local": EnvironmentOverride(deployment: "jobs"),
                                                                                  "mid": EnvironmentOverride(url: "https://jobs.example.com"),
                                                                              ]))
            var midLocal = Self.local
            midLocal.port = 9000
            var jobsLocal = midLocal
            jobsLocal.deployment = "jobs"
            #expect(jobs.inheritedEnvironments == [midLocal, Self.staging, mid])
            #expect(jobs.environments == [jobsLocal, Self.staging, ProjectEnvironment(name: "mid", url: "https://jobs.example.com"), leaf])

            // The middle project's checkbox decides what it passes on.
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: false))
            let off = try await Self.detail(h, "JOBS")
            #expect(off.inheritedEnvironments == [mid])
            #expect(off.environments == [ProjectEnvironment(name: "mid", url: "https://jobs.example.com"), leaf])
        }
    }

    @Test("A parent or a sub project of another type gives no environments")
    func otherTypes() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environments: [Self.replay]))
            // A sub project of another type has none, while it keeps its own in its file.
            var worker = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", type: ProjectType.none))
            #expect(worker.environments.isEmpty)
            #expect(worker.inheritedEnvironments.isEmpty)
            #expect(worker.project.environments == [Self.replay])
            // A parent of another type passes none on.
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", type: .goService))
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", type: .swiftApplication))
            worker = try await Self.detail(h, "WRK")
            #expect(worker.inheritedEnvironments.isEmpty)
            #expect(worker.environments == [Self.replay])
            #expect(try await Self.detail(h, "API").environments.isEmpty)
        }
    }

    @Test("A change for an environment the parent no longer has is ignored and kept in the file, and applies again with the name")
    func removedEnvironment() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            let changes = ["staging": EnvironmentOverride(deployment: "orders-worker"), "gone": EnvironmentOverride(port: 7000)]
            var worker = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environmentOverrides: changes))
            #expect(worker.environments.map(\.name) == ["local", "staging"])
            #expect(worker.environments[1].deployment == "orders-worker")

            // The parent renames staging: its change is kept, unused.
            var renamed = Self.staging
            renamed.name = "stage"
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", environments: [Self.local, renamed]))
            worker = try await Self.detail(h, "WRK")
            #expect(worker.environments == [Self.local, renamed])
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", name: "Worker"))
            #expect(try ProjectFileStore.readProject(ProjectFolder(root: URL(fileURLWithPath: h.path("Api/worker"))))
                .environmentOverrides == changes)

            // An environment that takes the name again gets the change.
            let gone = ProjectEnvironment(name: "gone", url: "https://gone.example.com")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", environments: [Self.local, renamed, gone]))
            worker = try await Self.detail(h, "WRK")
            #expect(worker.environments.last == ProjectEnvironment(name: "gone", url: "https://gone.example.com", port: 7000))
        }
    }

    @Test("An environment of its own cannot take an inherited name; one that clashes afterwards is left out and kept")
    func nameClash() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            func update(_ environments: [ProjectEnvironment]) async -> EngineError? {
                await engineError { try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environments: environments)) }
            }
            #expect(await update([ProjectEnvironment(name: " staging ", url: "https://worker.example.com")])
                == EngineError(.invalid, "An environment named “staging” already exists."))
            // Letter case makes two names.
            #expect(await update([ProjectEnvironment(name: "Staging", url: "https://worker.example.com")]) == nil)
            // The check takes the inheritance the call leaves: off, the name is free.
            let own = ProjectEnvironment(name: "staging", url: "https://worker.example.com")
            let off = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: false, environments: [own]))
            #expect(off.environments == [own])

            // Back on, the inherited environment hides it; it stays in the file and comes back when off.
            var worker = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: true))
            #expect(worker.environments == [Self.local, Self.staging])
            #expect(worker.project.environments == [own])
            // The hidden environment, sent back unchanged, is kept; a new one is checked.
            worker = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environments: [own, Self.replay]))
            #expect(worker.project.environments == [own, Self.replay])
            #expect(worker.environments == [Self.local, Self.staging, Self.replay])
            #expect(await update([own, Self.replay, ProjectEnvironment(name: "local", url: "https://a.example")])
                == EngineError(.invalid, "An environment named “local” already exists."))
            worker = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: false))
            #expect(worker.environments == [own, Self.replay])
        }
    }

    @Test("projects.update checks and trims the changes it adds or changes and writes back a stored one as it is")
    func changeRules() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            func update(_ overrides: [String: EnvironmentOverride]) async -> EngineError? {
                await engineError { try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environmentOverrides: overrides)) }
            }
            #expect(await update(["staging": EnvironmentOverride(url: "localhost:8080")])
                == EngineError(.invalid, "environmentOverrides[staging]: use an absolute http or https URL."))
            #expect(await update(["staging": EnvironmentOverride(port: 0)])
                == EngineError(.invalid, "environmentOverrides[staging]: use a port from 1 to 65535."))
            #expect(await update(["staging": EnvironmentOverride(deployment: "orders\nworker")])
                == EngineError(.invalid, "environmentOverrides[staging]: use a deployment on one line."))
            #expect(await update(["staging": EnvironmentOverride(argoCDApplication: "argocd/orders/worker")])
                == EngineError(.invalid, "environmentOverrides[staging]: use an Argo CD application as <name> or <namespace>/<name>."))

            let worker = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environmentOverrides: [
                "staging": EnvironmentOverride(url: " https://worker.example.com ", deployment: " orders-worker ", argoCDApplication: "  "),
                "local": EnvironmentOverride(url: " ", deployment: "\n"),
            ]))
            #expect(worker.project.environmentOverrides == [
                "staging": EnvironmentOverride(url: "https://worker.example.com", deployment: "orders-worker"),
                "local": EnvironmentOverride(),
            ])

            // A change that a hand edit made invalid is written back as it is while the call leaves it unchanged.
            let file = Self.projectFile(h, "Api/worker")
            let edited = try readFile(file).replacingOccurrences(of: "url: https://worker.example.com", with: "url: ftp://worker.example.com")
            try writeFile(edited, to: file)
            await h.engine.projectDataFilesChanged(projectID: "WRK", paths: [".hephaestus/project.yml"])
            let stored = try await Self.detail(h, "WRK").project.environmentOverrides
            #expect(stored["staging"]?.url == "ftp://worker.example.com")
            var changes = stored
            changes["local"] = EnvironmentOverride(port: 8081)
            let kept = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environmentOverrides: changes))
            #expect(kept.project.environmentOverrides == changes)
            changes["staging"]?.deployment = "jobs"
            #expect(await update(changes) == EngineError(.invalid, "environmentOverrides[staging]: use an absolute http or https URL."))
        }
    }

    @Test("A change of a parent's environments emits project.updated for the sub projects that inherit them, and only for them")
    func liveUpdates() async throws {
        try await withDomainEngine { h in
            try await Self.makeTree(h)
            try await h.create("Api/worker/jobs", name: "Jobs", identifier: "JOBS", parentID: "WRK")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "JOBS", type: .goService))
            try await h.create("Api/own", name: "Own", identifier: "OWN", parentID: "API")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "OWN", type: .goService, useParentSettings: false))

            let events = await DomainEventRecorder.make(h)
            let qa = ProjectEnvironment(name: "qa", url: "https://qa.example.com")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", environments: [Self.local, Self.staging, qa]))
            let received = await events.wait { Self.environments($0, "JOBS").count == 1 }
            #expect(Self.environments(received, "API") == [[Self.local, Self.staging, qa]])
            #expect(Self.environments(received, "WRK") == [[Self.local, Self.staging, qa]])
            #expect(Self.environments(received, "JOBS") == [[Self.local, Self.staging, qa]])
            #expect(await events.settle().count == 3)
            #expect(Self.environments(events.all, "OWN").isEmpty)
            #expect(received.allSatisfy { $0.origin == .user(deviceID: h.engine.deviceID) })

            // A change of the middle project's changes reaches the sub project below it only.
            events.clear()
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environmentOverrides: ["qa": EnvironmentOverride(port: 8443)]))
            let changed = await events.wait { Self.environments($0, "JOBS").count == 1 }
            #expect(Self.environments(changed, "WRK").first?.last?.port == 8443)
            #expect(Self.environments(changed, "JOBS").first?.last?.port == 8443)
            #expect(await events.settle().count == 2)

            // A change outside the app is followed the same way, with origin system.
            events.clear()
            let file = Self.projectFile(h, "Api")
            try writeFile(try readFile(file).replacingOccurrences(of: "https://qa.example.com", with: "https://qa2.example.com"), to: file)
            await h.engine.projectDataFilesChanged(projectID: "API", paths: [".hephaestus/project.yml"])
            let reloaded = await events.wait { Self.environments($0, "JOBS").count == 1 }
            #expect(Self.environments(reloaded, "WRK").first?.last?.url == "https://qa2.example.com")
            #expect(Self.environments(reloaded, "JOBS").first?.last?.url == "https://qa2.example.com")
            #expect(Self.environments(reloaded, "OWN").isEmpty)
            #expect(reloaded.allSatisfy { $0.origin == .system })

            // A change that leaves every environment as it is emits nothing for the others.
            events.clear()
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "API", name: "Orders"))
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "projects.changed"])
        }
    }

    @Test("projects.open emits project.updated for a top-level project it adopts that now inherits environments")
    func adoption() async throws {
        try await withDomainEngine { h in
            try await h.create("Mono/x", name: "App", identifier: "APP")
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "APP", type: .goService))
            try writeFile(projectYAML(id: "MONO", name: "Mono", subprojects: ["x"], extra: """
                type: goService
                environments:
                - name: local
                  url: http://127.0.0.1
                  port: 8080

                """), to: h.projects.appendingPathComponent("Mono/.hephaestus/project.yml"))
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(ProjectsOpen.self, .init(rootPath: h.path("Mono")))
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "project.updated", "projects.changed"])
            #expect(Self.environments(events.all, "APP") == [[Self.local]])
        }
    }

    @Test("get_project gives the environments that apply and the inherited ones; update_project cannot change the changes")
    func throughMCP() async throws {
        try await withDomainEngine { h in
            let engine = h.engine
            let handlers = MCPToolHandlers(engineCall: { method, params, actor in
                try await engine.dispatch(method: method, params: params, actor: actor)
            }, debugUI: nil, homeDirectory: "/Users/example")
            func call(_ tool: String, _ arguments: String) async throws -> Result<String, MCPToolError> {
                let definition = try #require(MCPToolCatalog.tool(named: tool, debugTools: false))
                return await handlers.call(definition, arguments: try jsonValue(arguments), actor: h.claude)
            }
            try await Self.makeTree(h)
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environments: [Self.replay],
                                                                       environmentOverrides: ["local": EnvironmentOverride(port: 8081)]))
            let text = try await call("get_project", #"{"projectID":"WRK"}"#).get()
            let detail = try EngineJSON.decoder().decode(ProjectsGet.Result.self, from: Data(text.utf8))
            #expect(detail.environments.map(\.name) == ["local", "staging", "replay"])
            #expect(detail.environments[0].port == 8081)
            #expect(detail.inheritedEnvironments == [Self.local, Self.staging])
            #expect(detail.project.environmentOverrides == ["local": EnvironmentOverride(port: 8081)])
            let json = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue)
            #expect(json["environments"]?.arrayValue?.first?.objectValue?["port"] == .int(8081))
            #expect(json["inheritedEnvironments"]?.arrayValue?.first?.objectValue?["port"] == .int(8080))
            let api = try EngineJSON.decoder().decode(ProjectsGet.Result.self,
                                                      from: Data(try await call("get_project", #"{"projectID":"API"}"#).get().utf8))
            #expect(api.environments == [Self.local, Self.staging])

            let refused = try await call("update_project", #"{"projectID":"WRK","environmentOverrides":{}}"#)
            #expect(refused == .failure(MCPToolError(code: .invalid, message: "environmentOverrides: unknown argument.")))
        }
    }
}
