import Foundation
import Testing
@testable import HephaestusCore

/// `graph.read` and `graph.request`, called by a window with a fake kubectl, a fake gh and a fake
/// Jaeger: their checks in the order of docs/engine-api.md › Graph, the graph built from the
/// Deployments and the sources of their images, Jaeger's traces and the failures.
@Suite("Graph methods")
struct GraphMethodsTests {
    /// `staging` of the Kubernetes tests, with the Jaeger `tracing/jaeger`; `local` without Kubernetes
    /// field nor Jaeger.
    static let environments = [
        ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080),
        ProjectEnvironment(name: "staging", namespace: "orders", jaeger: "tracing/jaeger", kubeconfig: "~/.kube/staging.yaml"),
        ProjectEnvironment(name: "nojaeger", namespace: "orders", kubeconfig: "~/.kube/staging.yaml"),
    ]

    static let deployments = """
    {"items": [
      {"metadata": {"name": "front"}, "spec": {"template": {"spec": {"containers": [{"image": "ghcr.io/example/front:sha-1111111"}]}}}},
      {"metadata": {"name": "back"}, "spec": {"template": {"spec": {"containers": [{"image": "ghcr.io/example/back:sha-2222222"}]}}}},
      {"metadata": {"name": "jaeger"}, "spec": {"template": {"spec": {"containers": [{"image": "jaegertracing/jaeger:2.23.0"}]}}}}
    ]}
    """

    /// The files of the repositories at their commits; any other file is answered 404.
    static let files = [
        "repos/example/front/contents/go.mod?ref=1111111": "module github.com/example/front\n\nrequire github.com/example/back/client v0.0.0\n",
        "repos/example/back/contents/go.mod?ref=2222222": "module github.com/example/back\n",
        "repos/example/back/contents/deployment/values-prod.yml?ref=2222222": "postgres:\n  enabled: true\n",
    ]

    static func gh() -> FakeGitHubCLI {
        FakeGitHubCLI { run in
            guard let path = run.arguments.last, let text = files[path] else {
                return .finished(.ghResult(status: 1, error: "gh: Not Found (HTTP 404)\n"))
            }
            return .finished(.ghResult(output: Data(text.utf8)))
        }
    }

    static func withGraphEngine<T>(graphEnabled: Bool = true, githubCLI: FakeGitHubCLI = gh(),
                                   _ body: (ChatTestBed, FakeKubectl, FakeGitHubCLI) async throws -> T) async throws -> T {
        let launcher = FakeClaudeLauncher()
        return try await withChatEngine(launcher: launcher, githubCLI: githubCLI, prepare: { folder, _ in
            try ProjectFileStore.write(Project(id: "DEMO", name: "Demo", created: ISODate.date(from: "2026-10-31T12:00:00Z")!,
                                               type: .goService, graphEnabled: graphEnabled, environments: environments),
                                       to: folder)
            let kubectl = FakeKubectl(root: folder.root)
            try FileManager.default.createDirectory(at: kubectl.bin, withIntermediateDirectories: true)
            try kubectl.install()
            launcher.environment["PATH"] = "\(kubectl.bin.path):/usr/bin:/bin"
        }) { bed in
            await bed.engine.useKubectl(now: KubernetesFixtures.now, forwardTimeout: waitLimit)
            return try await body(bed, FakeKubectl(root: bed.root), githubCLI)
        }
    }

    static func read(_ bed: ChatTestBed, projectID: ProjectID = "DEMO", environment: String = "staging",
                     window: GraphWindow = .fiveMinutes) async throws -> GraphSnapshot {
        try await bed.connection.call(GraphRead.self, .init(projectID: projectID, environment: environment, window: window))
    }

    @Test("The user calls them; Claude cannot")
    func actors() async throws {
        try await Self.withGraphEngine { bed, kubectl, _ in
            let chat = try await bed.createChat()
            let byClaude = await engineError {
                try await bed.engine.call(GraphRead.self, .init(projectID: "DEMO", environment: "staging", window: .hour),
                                          actor: .claude(chatID: chat.id.uuidString))
            }
            #expect(byClaude == EngineError(.forbidden, "graph.read is not available to claude."))
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("The project, then its graph, then the environment, then the correlation id, then kubectl")
    func checks() async throws {
        try await Self.withGraphEngine(graphEnabled: false) { bed, kubectl, _ in
            #expect(await engineError { try await Self.read(bed, projectID: "D3") } == EngineError(.invalid, "projectID: use 2 to 8 letters A–Z."))
            #expect(await engineError { try await Self.read(bed, projectID: "NOPE") } == EngineError(.notFound, "Project NOPE not found."))
            #expect(await engineError { try await Self.read(bed) } == EngineError(.invalid, "The graph of DEMO is not enabled."))
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", graphEnabled: true))
            #expect(await engineError { try await Self.read(bed, environment: "Staging") }
                == EngineError(.invalid, "environment: DEMO has no environment named “Staging”."))
            #expect(await engineError {
                try await bed.connection.call(GraphRequest.self, .init(projectID: "DEMO", environment: "staging", correlationID: "  "))
            } == EngineError(.invalid, "correlationID: use a correlation id."))
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("A sub project that uses its parent's settings has its parent's graph; turning the setting off gives its own")
    func inheritedGraph() async throws {
        try await Self.withGraphEngine(graphEnabled: false) { bed, _, _ in
            let root = bed.root.appendingPathComponent("worker").path
            _ = try await bed.connection.call(ProjectsCreate.self, .init(rootPath: root, name: "Worker", identifier: "WRK", parentID: "DEMO",
                                                                         type: .goService, createDirectory: true))
            #expect(try await bed.connection.call(ProjectsGet.self, .init(projectID: "WRK")).graphEnabled == false)
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", graphEnabled: true))
            // The sub project's windows follow: project.updated with its graph enabled.
            let event = await bed.events.wait(for: ProjectUpdatedEvent.name) { event in
                guard let detail = try? event.payload(ProjectUpdatedEvent.self) else { return false }
                return detail.project.id == "WRK" && detail.graphEnabled
            }
            #expect(event != nil)
            #expect(try await bed.connection.call(ProjectsGet.self, .init(projectID: "WRK")).graphEnabled)
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: false))
            #expect(try await bed.connection.call(ProjectsGet.self, .init(projectID: "WRK")).graphEnabled == false)
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", type: ProjectType.none, graphEnabled: true))
            #expect(try await bed.connection.call(ProjectsGet.self, .init(projectID: "WRK")).graphEnabled == false)
        }
    }

    @Test("The boxes and arrows of the Deployments whose image names a commit, from their sources on GitHub, kept by commit")
    func graphFromSources() async throws {
        try await Self.withGraphEngine { bed, kubectl, gh in
            try kubectl.answer(.deployments, output: Self.deployments)
            let snapshot = try await Self.read(bed, environment: "nojaeger")
            #expect(snapshot.environment == "nojaeger")
            #expect(snapshot.namespace == "orders")
            #expect(snapshot.boxes.map(\.id) == ["service/back", "service/front", "cluster/back"])
            #expect(snapshot.arrows.map(\.id) == ["service/back->cluster/back", "service/front->service/back"])
            #expect(snapshot.sourceErrors.isEmpty)
            #expect(snapshot.jaegerError == "Jaeger cannot be reached: Environment “nojaeger” has no Jaeger.")
            #expect(snapshot.requests.isEmpty && snapshot.calls.isEmpty)
            #expect(kubectl.calls() == [KubernetesFixtures.stagingPrefix + ["get", "deployments", "-o", "json"]])
            #expect(Set(gh.runs.map { $0.arguments.last ?? "" }) == [
                "repos/example/front/contents/go.mod?ref=1111111", "repos/example/front/contents/deployment/values-prod.yml?ref=1111111",
                "repos/example/back/contents/go.mod?ref=2222222", "repos/example/back/contents/deployment/values-prod.yml?ref=2222222",
            ])
            #expect(gh.runs.allSatisfy { $0.arguments.prefix(2) == ["api", "--header=Accept: application/vnd.github.raw"] })
            #expect(gh.runs.allSatisfy { $0.environment["GH_PROMPT_DISABLED"] == "1" })

            // The files read are kept, missing ones included: a later read runs no gh.
            _ = try await Self.read(bed, environment: "nojaeger", window: .hour)
            #expect(gh.runs.count == 4)
        }
    }

    @Test("A source that cannot be read leaves its box without its arrows, with its message")
    func sourceFailure() async throws {
        let gh = FakeGitHubCLI { run in
            if run.arguments.last?.contains("example/front") == true {
                return .finished(.ghResult(status: 1, error: "error connecting to api.github.com\n"))
            }
            return .finished(.ghResult(status: 1, error: "gh: Not Found (HTTP 404)\n"))
        }
        try await Self.withGraphEngine(githubCLI: gh) { bed, kubectl, _ in
            try kubectl.answer(.deployments, output: Self.deployments)
            let snapshot = try await Self.read(bed, environment: "nojaeger")
            #expect(snapshot.boxes.map(\.id) == ["service/back", "service/front"])
            #expect(snapshot.arrows.isEmpty)
            #expect(snapshot.sourceErrors == ["The sources of front cannot be read: error connecting to api.github.com."])
        }
    }

    @Test("A kubectl that fails fails the read with its command")
    func kubectlFailure() async throws {
        try await Self.withGraphEngine { bed, kubectl, _ in
            try kubectl.answer(.deployments, error: "error: You must be logged in to the server (Unauthorized)\n", status: 1)
            #expect(await engineError { try await Self.read(bed) } == EngineError(
                .unavailable, "kubectl --kubeconfig=/Users/example/.kube/staging.yaml --namespace=orders get deployments -o json "
                    + "exited with code 1: error: You must be logged in to the server (Unauthorized)"))
        }
    }

    @Test("Jaeger is read through a port forward to its Service: the calls of each arrow and the requests of the window")
    func jaeger() async throws {
        try await Self.withGraphEngine { bed, kubectl, _ in
            try kubectl.answer(.deployments, output: Self.deployments)
            let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
            let trace = Self.otlp(start: now - 60_000_000)
            let fetched = URLRecorder()
            await bed.engine.useJaeger { url in
                fetched.add(url)
                if url.path.hasPrefix("/api/v3/traces/") {
                    return url.lastPathComponent == "00000000000000000000000000000abc" ? trace : Data(#"{"error":{"httpCode":404,"message":"not found"}}"#.utf8)
                }
                return url.query?.contains("service_name=front") == true ? trace : Data(#"{"error":{"httpCode":404,"message":"none"}}"#.utf8)
            }
            let snapshot = try await Self.read(bed)
            #expect(snapshot.jaegerError == nil)
            #expect(snapshot.calls == ["service/front->service/back": 1, "service/back->cluster/back": 1])
            #expect(snapshot.requests.map(\.id) == ["00000000000000000000000000000abc"])
            #expect(snapshot.tracesRead == 1)
            let forward = try #require(kubectl.calls().first { $0.contains("port-forward") })
            #expect(forward == ["--kubeconfig=/Users/example/.kube/staging.yaml", "--namespace=tracing", "port-forward", "service/jaeger",
                                "--address=127.0.0.1", ":16686"])
            #expect(fetched.urls.allSatisfy { $0.host == "127.0.0.1" && $0.port == 52814 })
            #expect(Set(fetched.urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value })
                == ["back", "front"])

            // One forward for the reads that follow; the request of an id, from Jaeger.
            let detail = try await bed.connection.call(GraphRequest.self, .init(projectID: "DEMO", environment: "staging",
                                                                                correlationID: " 00000000000000000000000000000ABC "))
            #expect(detail.request.id == "00000000000000000000000000000abc")
            #expect(detail.timeline.map(\.kind) == [.httpRequest, .httpCall, .httpRequest, .sql])
            #expect(detail.logs.map(\.message) == ["request handled"])
            #expect(await engineError {
                try await bed.connection.call(GraphRequest.self, .init(projectID: "DEMO", environment: "staging", correlationID: "ffff"))
            } == EngineError(.notFound, "Request ffff not found."))
            #expect(kubectl.forwardPIDs().count == 1)

            // Without Jaeger: the request cannot be read.
            #expect(await engineError {
                try await bed.connection.call(GraphRequest.self, .init(projectID: "DEMO", environment: "nojaeger", correlationID: "abc"))
            } == EngineError(.unavailable, "Jaeger cannot be reached: Environment “nojaeger” has no Jaeger."))

            // The forward stops with the engine.
            let pid = try #require(kubectl.forwardPIDs().first)
            await bed.engine.shutdown()
            #expect(!processIsAlive(pid))
        }
    }

    @Test("A Jaeger that cannot be reached leaves the graph, grey, without requests")
    func jaegerFailure() async throws {
        try await Self.withGraphEngine { bed, kubectl, _ in
            try kubectl.answer(.deployments, output: Self.deployments)
            await bed.engine.useJaeger { _ in throw URLError(.cannotConnectToHost) }
            let snapshot = try await Self.read(bed)
            #expect(snapshot.boxes.count == 3)
            #expect(snapshot.calls.isEmpty && snapshot.requests.isEmpty)
            #expect(snapshot.jaegerError?.hasPrefix("Jaeger cannot be reached: ") == true)
            #expect(snapshot.jaegerError?.hasSuffix(".") == true)
        }
    }

    /// A request through front and back, as Jaeger answers it.
    static func otlp(start: Int64) -> Data {
        let nanos = { (micros: Int64) in String(micros * 1000) }
        return Data("""
        {"result":{"resourceSpans":[
          {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"front"}}]},
           "scopeSpans":[{"spans":[
             {"traceId":"abc","spanId":"01","name":"GET /page","kind":2,"startTimeUnixNano":"\(nanos(start))","endTimeUnixNano":"\(nanos(start + 9000))",
              "attributes":[{"key":"http.request.method","value":{"stringValue":"GET"}},{"key":"http.route","value":{"stringValue":"/page"}},
                            {"key":"http.status_code","value":{"intValue":"500"}}],
              "events":[{"timeUnixNano":"\(nanos(start + 8000))","name":"request handled","attributes":[{"key":"log.level","value":{"stringValue":"info"}}]}]},
             {"traceId":"abc","spanId":"02","parentSpanId":"01","name":"GET /greeting","kind":3,"startTimeUnixNano":"\(nanos(start + 100))",
              "endTimeUnixNano":"\(nanos(start + 8000))",
              "attributes":[{"key":"http.request.method","value":{"stringValue":"GET"}},{"key":"server.address","value":{"stringValue":"back"}}]}]}]},
          {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"back"}}]},
           "scopeSpans":[{"spans":[
             {"traceId":"abc","spanId":"03","parentSpanId":"02","name":"GET /greeting","kind":2,"startTimeUnixNano":"\(nanos(start + 200))",
              "endTimeUnixNano":"\(nanos(start + 7000))","attributes":[{"key":"http.request.method","value":{"stringValue":"GET"}}]},
             {"traceId":"abc","spanId":"04","parentSpanId":"03","name":"INSERT back_values","kind":3,"startTimeUnixNano":"\(nanos(start + 300))",
              "endTimeUnixNano":"\(nanos(start + 900))","attributes":[{"key":"db.system.name","value":{"stringValue":"postgresql"}}]}]}]}
        ]}}
        """.utf8)
    }
}

/// The URLs a fake Jaeger received.
final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    var urls: [URL] { lock.withLock { recorded } }

    func add(_ url: URL) {
        lock.withLock { recorded.append(url) }
    }
}

extension Engine {
    /// Answers the requests to Jaeger with `fetch` in place of the network.
    func useJaeger(_ fetch: @escaping JaegerClient.Fetch) {
        jaegerFetch = fetch
    }
}
