import AppKit
import Foundation
import HephaestusCore
import SwiftUI
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/ui.md › Pane headers: the sections and views that show their title in a title row, those
/// that show none, and the states without title row. The centre column of a main window is hosted
/// in a window that is never shown; each title row reports its title in `PaneTitlesKey`.
@MainActor
@Suite("Pane titles")
struct PaneTitleTests {
    nonisolated static let created = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated static let contract = """
    openapi: 3.0.3
    info:
      title: Pets
      version: 1.0.0
    paths:
      /pets:
        get:
          responses:
            "200":
              description: The pets
    """

    /// The contract of the API Explorer, a project path.
    nonisolated static let contractPath = "openapi/contract.yaml"

    /// A text that is detected as a contract and cannot be parsed as one.
    nonisolated static let brokenContract = "openapi: 3.0.3\ninfo: [\n"

    // MARK: Titles

    @Test("Dashboard, Tickets, Bundles, Chats, Web, Builds, Skills, Memories and API Explorer have their sidebar title; Docs, Costs, Code, Graph and Project Settings have none")
    func sectionTitles() {
        let titled: [ProjectSection: String] = [
            .dashboard: "Dashboard", .tickets: "Tickets", .bundles: "Bundles", .chats: "Chats", .web: "Web", .builds: "Builds",
            .skills: "Skills", .memories: "Memories", .apiExplorer: "API Explorer",
        ]
        for section in ProjectSection.allCases {
            #expect(PaneTitle.title(of: section) == titled[section], "\(section)")
        }
        for section in [ProjectSection.docs, .costs, .code, .graph, .settings] {
            #expect(PaneTitle.title(of: section) == nil, "\(section)")
        }
        #expect(PaneTitle.globalMemories == "Global Memories")
        #expect(PaneTitle.internalSkills == "Internal Skills")
    }

    // MARK: Hosted sections

    @Test("Each titled section shows its title row once, also with empty Tickets and Bundles lists; the Global Memories and Internal Skills views show theirs")
    func titledSections() async throws {
        try await withAppModel { app in
            for (section, title) in [(ProjectSection.dashboard, "Dashboard"), (.tickets, "Tickets"), (.bundles, "Bundles"),
                                     (.chats, "Chats"), (.web, "Web"), (.builds, "Builds"), (.skills, "Skills"),
                                     (.memories, "Memories"), (.apiExplorer, "API Explorer")] {
                let (workspace, _) = Self.workspace(filled: true)
                let shown = try await titles(Self.window(section), workspace, app: app, expecting: [title])
                #expect(shown == [title], "\(section)")
            }
            let (workspace, _) = Self.workspace(filled: true)
            let memories = Self.window(.tickets)
            memories.showsGlobalMemories = true
            let globalMemories = try await titles(memories, workspace, app: app, expecting: ["Global Memories"])
            #expect(globalMemories == ["Global Memories"])
            let skills = Self.window(.tickets)
            skills.showsInternalSkills = true
            let internalSkills = try await titles(skills, workspace, app: app, expecting: ["Internal Skills"])
            #expect(internalSkills == ["Internal Skills"])

            // The lists of Tickets and Bundles keep their header when they are empty, so they keep
            // their title; the Internal Skills view has no empty state.
            let (empty, _) = Self.workspace(filled: false)
            let tickets = try await titles(Self.window(.tickets), empty, app: app, expecting: ["Tickets"])
            #expect(tickets == ["Tickets"])
            let bundles = try await titles(Self.window(.bundles), empty, app: app, expecting: ["Bundles"])
            #expect(bundles == ["Bundles"])
            let noSkills = Self.window(.tickets)
            noSkills.showsInternalSkills = true
            let emptyInternalSkills = try await titles(noSkills, empty, app: app, expecting: ["Internal Skills"])
            #expect(emptyInternalSkills == ["Internal Skills"])
        }
    }

    @Test("Docs, Costs, Code, Graph, Project Settings and a sub project's Dashboard show no title row")
    func untitledSections() async throws {
        try await withAppModel { app in
            for section in [ProjectSection.docs, .costs, .code, .graph, .settings] {
                let (workspace, _) = Self.workspace(filled: true)
                let shown = try await titles(Self.window(section), workspace, app: app)
                #expect(shown == [], "\(section)")
            }
            let (workspace, _) = Self.workspace(filled: true)
            let window = Self.window(.dashboard)
            window.showSubProject("API")
            let shown = try await titles(window, workspace, app: app)
            #expect(shown == [])
        }
    }

    @Test("No Memories, No Global Memories, No chats yet, No Web Tabs and No Skills show no title row")
    func emptyStates() async throws {
        try await withAppModel { app in
            for section in [ProjectSection.memories, .chats, .web, .skills] {
                let (workspace, _) = Self.workspace(filled: false)
                let shown = try await titles(Self.window(section), workspace, app: app)
                #expect(shown == [], "\(section)")
            }
            let (workspace, _) = Self.workspace(filled: false)
            let window = Self.window(.tickets)
            window.showsGlobalMemories = true
            let shown = try await titles(window, workspace, app: app)
            #expect(shown == [])
        }
    }

    @Test("The notices of the API Explorer show no title row: the spinner, a file that cannot be opened and a contract that cannot be read")
    func apiExplorerNotices() async throws {
        try await withAppModel { app in
            // The spinner while the file is read: the read does not end.
            let (reading, readingConnection) = Self.workspace(filled: true, contract: .pending)
            let spinner = try await titles(Self.window(.apiExplorer), reading, app: app)
            readingConnection.cancelPending()
            #expect(spinner == [])

            let (failing, _) = Self.workspace(filled: true, contract: .failure)
            let failed = Self.window(.apiExplorer)
            let notOpened = try await titles(failed, failing, app: app, when: {
                if case .failed = FileActions.viewState(failed, "DEMO").apiExplorerBuffer?.content { return true }
                return false
            })
            #expect(notOpened == [])

            let (broken, _) = Self.workspace(filled: true, contract: .text(Self.brokenContract))
            let unread = Self.window(.apiExplorer)
            let notRead = try await titles(unread, broken, app: app, when: {
                if case .failed = FileActions.viewState(unread, "DEMO").apiExplorerBuffer?.contractModel.state { return true }
                return false
            })
            #expect(notRead == [])
        }
    }

    @Test("The Contract view shows the title row only where the API Explorer asks for it")
    func contractViewOfTheCodeSection() {
        let buffer = EditorBuffer(path: "api/openapi.yaml", role: .codeTab)
        #expect(!OpenAPIContractView(model: buffer.contractModel, text: "").showsTitleRow)
    }

    // MARK: Hosting

    /// The title of the row the tests put under the hosted column: once it has reached the root,
    /// the titles of the column above it have too.
    static let marker = "End of the column"

    /// Records the titles that reach the root of a hosted view.
    final class Shown {
        var titles: [String] = []
    }

    /// Hosts the centre column of `window`, as a main window builds it, in a window that is never
    /// shown, and returns the titles of its title rows: once `ready` holds and, with `expected`,
    /// once they are `expected`. The bound only ends a test that fails.
    func titles(_ window: WindowState, _ workspace: DeviceWorkspace, app: AppModel, expecting expected: [String]? = nil,
                when ready: () -> Bool = { true }) async throws -> [String] {
        let project = try #require(workspace.project("DEMO"))
        let shown = Shown()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            SectionContent(state: window, workspace: workspace, project: project)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PaneTitleRow(title: Self.marker)
        }
        .environment(app)
        .frame(width: 1100, height: 760)
        .onPreferenceChange(PaneTitlesKey.self) { shown.titles = $0 })
        let hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = host
        defer {
            hostWindow.contentView = nil
            hostWindow.close()
        }
        /// The titles of the column, once the marker under it has reached the root.
        func columnTitles() -> [String]? {
            shown.titles.last == Self.marker ? Array(shown.titles.dropLast()) : nil
        }
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let titles = columnTitles(), ready(), expected == nil || titles == expected {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        // One more pass, so that the titles are those of the state just reached.
        try await Task.sleep(for: .milliseconds(10))
        host.layoutSubtreeIfNeeded()
        return columnTitles() ?? ["not laid out"]
    }

    static func window(_ section: ProjectSection) -> WindowState {
        let window = WindowState(deviceID: "device")
        window.section = section
        window.activate(projectID: "DEMO")
        return window
    }

    /// DEMO, a loaded Go service with its graph enabled, an environment and a contract, and its sub
    /// project API. `filled`: it has a chat, a web tab, a skill and a memory, and the device has
    /// internal skills and a global memory; otherwise it has none of them.
    static func workspace(filled: Bool, contract: SectionsConnection.Contract = .text(PaneTitleTests.contract))
        -> (DeviceWorkspace, SectionsConnection) {
        let memories = filled ? [MemorySummary(file: "user-role.md", name: "user-role", description: "The user's role", type: "user")] : []
        let skills = filled ? [SkillSummary(name: "implement-ticket", description: "Implements a ticket"),
                               SkillSummary(name: "release-notes", description: "Writes release notes")] : []
        let folder = MemoryFolder(projectID: "DEMO", path: "/Users/example/.claude/projects/-Users-example-Demo/memory",
                                  hasIndex: filled, memories: memories)
        let global = MemoryFolder(projectID: nil, path: "/Users/example/.claude/memory", hasIndex: false, memories: memories)
        let connection = SectionsConnection(skills: skills, folders: ["DEMO": folder, "": global], contract: contract)
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        let environment = ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080)
        workspace.projects = [
            ProjectSummary(id: "DEMO", name: "Demo", type: .goService, rootPath: "/Users/example/Demo", subprojectIDs: ["API"]),
            ProjectSummary(id: "API", name: "Api", rootPath: "/Users/example/Demo/api", parentID: "DEMO"),
        ]
        workspace.details["DEMO"] = ProjectDetail(
            project: Project(id: "DEMO", name: "Demo", created: created, type: .goService, graphEnabled: true, environments: [environment]),
            rootPath: "/Users/example/Demo", githubPage: "https://github.com/example/demo", environments: [environment],
            currentEnvironment: "local", graphEnabled: true)
        workspace.details["API"] = ProjectDetail(project: Project(id: "API", name: "Api", created: created),
                                                 rootPath: "/Users/example/Demo/api", parentID: "DEMO")
        workspace.loadedProjectIDs = ["DEMO", "API"]
        workspace.tickets = ["DEMO": [:], "API": [:]]
        workspace.bundles = ["DEMO": [:], "API": [:]]
        workspace.webTabs = ["DEMO": filled ? [WebTab(id: UUID(), title: "Local page", url: "http://127.0.0.1/")] : [], "API": []]
        workspace.skills = skills
        workspace.hasSnapshot = true
        workspace.apiContracts["DEMO"] = true
        workspace.setMemoryFolder(folder, for: .project("DEMO"))
        workspace.setMemoryFolder(global, for: .global)
        if filled {
            let chat = ChatMeta(id: UUID(), title: "Release plan", kind: .project, created: created, projectID: "DEMO")
            workspace.chats[chat.id.uuidString] = chat
        }
        return (workspace, connection)
    }
}

/// A connection that never connects, so that no web view loads. It answers `skills.list`,
/// `memories.list` and the read of `openapi/contract.yaml` from the test's data; every other call
/// fails as offline.
final class SectionsConnection: EngineConnection, @unchecked Sendable {
    /// What the read of the contract answers.
    enum Contract: Sendable {
        case text(String)
        /// The read fails.
        case failure
        /// The read does not end until `cancelPending()`.
        case pending
    }

    let skills: [SkillSummary]
    /// The memory folders by project id; `""` for the global memories folder.
    let folders: [String: MemoryFolder]
    let contract: Contract
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var isCancelled = false

    init(skills: [SkillSummary], folders: [String: MemoryFolder], contract: Contract) {
        self.skills = skills
        self.folders = folders
        self.contract = contract
    }

    var deviceInfo: DeviceInfo? { nil }
    var state: ConnectionState { .connecting }
    var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
    var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

    func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        if M.self == SkillsList.self, let result = skills as? M.Result {
            return result
        }
        if let params = params as? MemoriesList.Params, let folder = folders[params.projectID ?? ""], let result = folder as? M.Result {
            return result
        }
        if let params = params as? FilesRead.Params, params.path == PaneTitleTests.contractPath {
            switch contract {
            case .text(let text):
                if let result = FileContent(path: params.path, text: text, modified: PaneTitleTests.created, size: text.utf8.count) as? M.Result {
                    return result
                }
            case .failure:
                throw EngineError(.internal, "The file could not be read.")
            case .pending:
                await withCheckedContinuation { continuation in
                    let resume = lock.withLock {
                        if isCancelled { return true }
                        pending.append(continuation)
                        return false
                    }
                    if resume {
                        continuation.resume()
                    }
                }
            }
        }
        throw EngineError(.unavailable, "Offline.")
    }

    /// Ends the pending reads, which then fail as offline.
    func cancelPending() {
        let waiting = lock.withLock {
            isCancelled = true
            defer { pending = [] }
            return pending
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    func close() {
        cancelPending()
    }
}

/// Runs `check` with an app model over a test engine in a temporary folder: the hosted Chats
/// section reads it from its environment.
@MainActor
private func withAppModel(_ check: (AppModel) async throws -> Void) async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = folder.appendingPathComponent("Data", isDirectory: true)
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: SilentClaudeLauncher()))
    let connection = await LocalEngineConnection(engine: engine)
    let app = AppModel(environment: LaunchEnvironment(dataDirectory: data), engine: engine,
                       appVersion: AppVersion(version: "0.0.0", build: 0), connection: connection, restartWindows: nil)
    do {
        try await check(app)
    } catch {
        connection.close()
        await engine.shutdown()
        throw error
    }
    connection.close()
    await engine.shutdown()
}

/// A launcher that starts nothing: no Claude process runs.
private struct SilentClaudeLauncher: ClaudeProcessLauncher {}
