import AppKit
import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/openapi.md › API Explorer: when the Go Service category shows the API Explorer row, how the
/// row follows `openapi/contract.yaml`, the window's fallback to the Dashboard, and the stored
/// values the API Explorer shares with the Code section's Contract view.
@MainActor
@Suite("API Explorer")
struct APIExplorerTests {
    nonisolated static let contract = """
    openapi: 3.0.3
    info:
      title: Pets
      version: 1.0.0
    paths: {}
    """

    private func workspace(_ type: ProjectType, _ connection: ScriptedConnection) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.projects = [ProjectSummary(id: "API", name: "Api", type: type, rootPath: "/Users/example/api")]
        return workspace
    }

    @Test("A Go service shows the row only when openapi/contract.yaml holds an OpenAPI 3.x contract",
          arguments: [
              (ScriptedConnection.File.text(APIExplorerTests.contract), true),
              (.text(#"{"openapi": "3.1.0", "info": {"title": "Pets", "version": "1"}, "paths": {}}"#), true),
              (.missing, false),
              (.text("swagger: \"2.0\"\ninfo:\n  title: Pets\n"), false),
              (.text("openapi: 2.0\n"), false),
              (.text("name: not a contract\n"), false),
              (.binary, false),
              (.failure(.internal), false),
          ])
    func goService(_ file: ScriptedConnection.File, shows: Bool) async {
        let connection = ScriptedConnection(file)
        let workspace = workspace(.goService, connection)
        defer { workspace.close() }
        #expect(workspace.showsAPIExplorer("API") == nil)
        workspace.followAPIContract(of: "API")
        #expect(await eventually { workspace.showsAPIExplorer("API") != nil })
        #expect(workspace.showsAPIExplorer("API") == shows)
        #expect(connection.reads == ["API/openapi/contract.yaml"])
        let categories = SidebarCategory.categories(for: .goService, showsAPIExplorer: workspace.showsAPIExplorer("API") == true)
        #expect(categories.last == SidebarCategory(title: "Go Service", sections: shows ? [.apiExplorer] : []))
    }

    @Test("Another project type shows no row and reads nothing, even with a contract", arguments: [ProjectType.none, .swiftApplication])
    func otherTypes(_ type: ProjectType) async {
        let connection = ScriptedConnection(.text(Self.contract))
        let workspace = workspace(type, connection)
        defer { workspace.close() }
        #expect(workspace.showsAPIExplorer("API") == false)
        workspace.followAPIContract(of: "API")
        connection.emit(paths: ["openapi/contract.yaml"])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(connection.reads.isEmpty)
        #expect(workspace.showsAPIExplorer("API") == false)
        #expect(SidebarCategory.categories(for: type, showsAPIExplorer: false).map(\.title) == ["Project"])
    }

    @Test("files.changed naming the contract, the openapi folder or the whole project reads the contract again")
    func followsFilesChanged() async {
        let connection = ScriptedConnection(.missing)
        let workspace = workspace(.goService, connection)
        defer { workspace.close() }
        workspace.followAPIContract(of: "API")
        #expect(await eventually { workspace.showsAPIExplorer("API") == false })

        connection.file = .text(Self.contract)
        connection.emit(paths: ["openapi/contract.yaml"])
        #expect(await eventually { workspace.showsAPIExplorer("API") == true })

        connection.file = .text("swagger: \"2.0\"\n")
        connection.emit(paths: ["openapi"])
        #expect(await eventually { workspace.showsAPIExplorer("API") == false })

        connection.file = .text(Self.contract)
        connection.emit(paths: [""])
        #expect(await eventually { workspace.showsAPIExplorer("API") == true })

        // Other paths and other projects read nothing.
        let reads = connection.reads.count
        connection.file = .missing
        connection.emit(paths: ["openapi2", "main.go", "openapi/contract.yaml.bak"])
        connection.emit(projectID: "OTHER", paths: [""])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(connection.reads.count == reads)
        #expect(workspace.showsAPIExplorer("API") == true)

        connection.emit(paths: ["main.go", "openapi/contract.yaml"])
        #expect(await eventually { workspace.showsAPIExplorer("API") == false })
    }

    @Test("A read that fails because the device is not connected keeps the previous result")
    func unavailableKeepsResult() async {
        let connection = ScriptedConnection(.text(Self.contract))
        let workspace = workspace(.goService, connection)
        defer { workspace.close() }
        workspace.followAPIContract(of: "API")
        #expect(await eventually { workspace.showsAPIExplorer("API") == true })
        connection.file = .failure(.unavailable)
        connection.emit(paths: ["openapi/contract.yaml"])
        #expect(await eventually { connection.reads.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(workspace.showsAPIExplorer("API") == true)
        connection.file = .failure(.notFound)
        connection.emit(paths: ["openapi/contract.yaml"])
        #expect(await eventually { workspace.showsAPIExplorer("API") == false })
    }

    @Test("The row follows the project's type without reading the contract again")
    func typeChanges() async {
        let connection = ScriptedConnection(.text(Self.contract))
        let workspace = workspace(.goService, connection)
        defer { workspace.close() }
        workspace.followAPIContract(of: "API")
        #expect(await eventually { workspace.showsAPIExplorer("API") == true })
        workspace.replaceProjects([ProjectSummary(id: "API", name: "Api", type: .none, rootPath: "/Users/example/api")])
        #expect(workspace.showsAPIExplorer("API") == false)
        workspace.replaceProjects([ProjectSummary(id: "API", name: "Api", type: .goService, rootPath: "/Users/example/api")])
        #expect(workspace.showsAPIExplorer("API") == true)
        #expect(connection.reads.count == 1)
        // A removed project forgets its contract.
        workspace.replaceProjects([])
        #expect(workspace.apiContracts["API"] == nil && workspace.apiContractReads["API"] == nil)
    }

    @Test("The window selects Dashboard when its API Explorer row is not shown, not while the first read runs")
    func windowFallback() async {
        let connection = ScriptedConnection(.missing)
        let workspace = workspace(.goService, connection)
        defer { workspace.close() }
        let window = WindowState(deviceID: "device")
        window.projectID = "API"
        window.section = .apiExplorer
        window.leaveHiddenAPIExplorer(in: workspace)
        #expect(window.section == .apiExplorer)

        workspace.followAPIContract(of: "API")
        #expect(await eventually { workspace.showsAPIExplorer("API") == false })
        window.leaveHiddenAPIExplorer(in: workspace)
        #expect(window.section == .dashboard)

        // Shown: the section stays; another section is never changed.
        connection.file = .text(Self.contract)
        connection.emit(paths: ["openapi/contract.yaml"])
        #expect(await eventually { workspace.showsAPIExplorer("API") == true })
        window.section = .apiExplorer
        window.leaveHiddenAPIExplorer(in: workspace)
        #expect(window.section == .apiExplorer)
        window.section = .code
        workspace.replaceProjects([ProjectSummary(id: "API", name: "Api", type: .none, rootPath: "/Users/example/api")])
        window.leaveHiddenAPIExplorer(in: workspace)
        #expect(window.section == .code)

        // Another type: at once.
        window.section = .apiExplorer
        window.leaveHiddenAPIExplorer(in: workspace)
        #expect(window.section == .dashboard)
    }

    @Test("The Code section's Contract view and the API Explorer share the stored values of the contract")
    func sharedStoredValues() async throws {
        try await withEngineApp { app, root in
            let workspace = app.localWorkspace
            #expect(await eventually { workspace.hasSnapshot })
            _ = try await workspace.call(ProjectsCreate.self, ProjectsCreate.Params(
                rootPath: root.appendingPathComponent("api").path, name: "Api", identifier: "API", type: .goService,
                createDirectory: true))
            let folder = root.appendingPathComponent("api/openapi", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.petsContract.write(to: folder.appendingPathComponent("contract.yaml"), atomically: true, encoding: .utf8)
            #expect(await eventually { workspace.project("API") != nil })

            let window = WindowState(deviceID: app.localDeviceID)
            app.registerMainWindow(window)
            let codeTab = EditorBuffer(path: DeviceWorkspace.apiContractPath, role: .codeTab)
            let explorer = EditorBuffer(path: DeviceWorkspace.apiContractPath, role: .apiExplorer)
            for buffer in [codeTab, explorer] {
                buffer.load(workspace: workspace, projectID: "API", window: window)
            }
            #expect(await eventually { codeTab.content == .text && explorer.content == .text })
            let code = codeTab.contractModel
            let api = explorer.contractModel
            code.appear()
            api.appear()
            #expect(await eventually { code.contract != nil && api.contract != nil && code.stored != nil && api.stored != nil })
            let contract = try #require(api.contract)
            let get = try #require(contract.operations.first { $0.method == "get" })
            let post = try #require(contract.operations.first { $0.method == "post" })

            // A value typed in the API Explorer is the Code section's once its Contract view appears.
            api.updateOperation(get) { $0.parameters["path:petId"] = "42" }
            code.disappear()
            code.appear()
            #expect(code.storedOperation(get).parameters["path:petId"] == "42")

            // A change applies to the latest values: it keeps what the other view changed.
            code.update { $0.headers = [OpenAPIHeader(name: "X-Tenant", value: "demo")] }
            api.updateOperation(get) { $0.parameters["query:verbose"] = "true" }
            #expect(api.stored?.headers == [OpenAPIHeader(name: "X-Tenant", value: "demo")])
            code.refreshStoredValues()
            #expect(code.storedOperation(get).parameters == ["path:petId": "42", "query:verbose": "true"])
            let stored = OpenAPIStoreModel.shared(dataDirectory: app.engine.dataDirectory).store
                .contract(deviceID: app.localDeviceID, projectID: "API", path: DeviceWorkspace.apiContractPath)
            #expect(stored == code.stored && stored == api.stored)

            // A body edited in one view replaces the body editor's text of the other.
            let media = try #require(api.mediaType(post))
            let apiBody = api.bodyModel(post, media)
            let codeBody = code.bodyModel(post, media)
            apiBody.text = #"{"name": "Rex"}"#
            api.bodyChanged(post, media, text: apiBody.text)
            code.refreshStoredValues()
            #expect(codeBody.text == #"{"name": "Rex"}"#)
            code.stop()
            api.stop()
            codeTab.detach()
            explorer.detach()

            // The values are written 500 ms after the last change, before the folder is removed.
            // A new store reads the file each time.
            let file = app.engine.dataDirectory.url.appendingPathComponent(OpenAPIRequestStore.fileName)
            #expect(await eventually(seconds: 5) {
                OpenAPIRequestStore(file: file).contract(deviceID: app.localDeviceID, projectID: "API", path: DeviceWorkspace.apiContractPath)
                    .operations[post.id]?.bodies[media.name] == #"{"name": "Rex"}"#
            })
        }
    }

    static let petsContract = """
    openapi: 3.0.3
    info:
      title: Pets
      version: 1.0.0
    paths:
      /pets/{petId}:
        get:
          parameters:
            - name: petId
              in: path
              required: true
              schema:
                type: string
            - name: verbose
              in: query
              schema:
                type: boolean
          responses:
            "200":
              description: A pet
      /pets:
        post:
          requestBody:
            content:
              application/json:
                schema:
                  type: object
                  properties:
                    name:
                      type: string
          responses:
            "201":
              description: Created
    """
}

/// Waits until a condition holds, at most `seconds`.
@MainActor
private func eventually(seconds: Int = 2, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<(seconds * 100) {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// An app on an engine with its own temporary data directory, and a folder for its projects.
@MainActor
private func withEngineApp(_ check: (AppModel, URL) async throws -> Void) async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = folder.appendingPathComponent("Data", isDirectory: true)
    let projects = folder.appendingPathComponent("Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: NoClaudeLauncher()))
    let connection = await LocalEngineConnection(engine: engine)
    let app = AppModel(environment: LaunchEnvironment(dataDirectory: data), engine: engine,
                       appVersion: AppVersion(version: "0.0.0", build: 0), connection: connection, restartWindows: nil)
    do {
        try await check(app, projects)
    } catch {
        connection.close()
        await engine.shutdown()
        throw error
    }
    connection.close()
    await engine.shutdown()
}

/// A launcher that starts nothing: no Claude process runs.
private struct NoClaudeLauncher: ClaudeProcessLauncher {}

/// A connected engine connection that answers `files.read` with `file` for every path and lets a
/// test emit `files.changed` events; every other call fails.
final class ScriptedConnection: EngineConnection, @unchecked Sendable {
    /// What `files.read` answers.
    enum File: Sendable, CustomTestStringConvertible {
        case text(String)
        case binary
        case missing
        case failure(EngineError.Code)

        var testDescription: String {
            switch self {
            case .text(let text): return "text \(text.prefix(20))"
            case .binary: return "binary"
            case .missing: return "missing"
            case .failure(let code): return "failure \(code)"
            }
        }
    }

    private let lock = NSLock()
    private var currentFile: File
    private var readPaths: [String] = []
    private let continuation: AsyncStream<EngineEventEnvelope>.Continuation
    let events: AsyncStream<EngineEventEnvelope>

    init(_ file: File) {
        currentFile = file
        (events, continuation) = AsyncStream<EngineEventEnvelope>.makeStream(bufferingPolicy: .unbounded)
    }

    var file: File {
        get { lock.withLock { currentFile } }
        set { lock.withLock { currentFile = newValue } }
    }

    /// `<project id>/<path>` of every `files.read`, in order.
    var reads: [String] {
        lock.withLock { readPaths }
    }

    var deviceInfo: DeviceInfo? { nil }
    var state: ConnectionState { .connected }
    var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }

    func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        guard let read = params as? FilesRead.Params else { throw EngineError(.unavailable, "Offline.") }
        let file: File = lock.withLock {
            readPaths.append("\(read.projectID)/\(read.path)")
            return currentFile
        }
        let content: FileContent
        switch file {
        case .text(let text):
            content = FileContent(path: read.path, text: text, modified: Date(), size: text.utf8.count)
        case .binary:
            content = FileContent(path: read.path, dataBase64: Data([0, 1, 2]).base64EncodedString(), modified: Date(), size: 3)
        case .missing:
            throw EngineError(.notFound, "No file at \(read.path).")
        case .failure(let code):
            throw EngineError(code, "Failed.")
        }
        guard let result = content as? M.Result else { throw EngineError(.internal, "Unexpected method.") }
        return result
    }

    /// Emits a `files.changed` event.
    func emit(projectID: String = "API", paths: [String]) {
        let payload = FilesChangedEvent.Payload(projectID: projectID, paths: paths)
        guard let data = try? EngineJSON.jsonValue(payload) else { return }
        continuation.yield(EngineEventEnvelope(name: FilesChangedEvent.name, origin: .system, data: data))
    }

    func close() {
        continuation.finish()
    }
}
