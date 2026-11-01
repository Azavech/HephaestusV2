import Foundation
import Testing
@testable import HephaestusCore

/// A started test engine for the project data tests: a `LocalEngineConnection`, a folder for
/// project folders and a folder that stands for the Trash, so that no test touches the user's
/// Trash.
struct DomainHarness {
    let engine: Engine
    let connection: LocalEngineConnection
    /// The temporary directory of the test.
    let folder: URL
    /// `<folder>/Projects`, where the tests put their project folders.
    let projects: URL
    /// `<folder>/Trash`, the Trash of the engine.
    let trash: URL

    var claude: Actor { .claude(chatID: Actor.externalChatID) }

    /// A project folder path under `projects`.
    func path(_ relative: String) -> String {
        projects.appendingPathComponent(relative).path
    }

    /// Creates a project through the connection.
    @discardableResult
    func create(_ relative: String, name: String, identifier: String, parentID: ProjectID? = nil) async throws -> ProjectDetail {
        try await connection.call(ProjectsCreate.self, .init(rootPath: path(relative), name: name, identifier: identifier,
                                                              parentID: parentID, createDirectory: true))
    }

    /// Creates a ticket as the user.
    @discardableResult
    func ticket(_ projectID: ProjectID, _ title: String = "A ticket", description: String = "Something to do.") async throws -> Ticket {
        try await connection.call(TicketsCreate.self, .init(projectID: projectID, title: title, description: description))
    }

    /// Calls a method with another actor than the connection's.
    func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params, as actor: Actor) async throws -> M.Result {
        try await engine.call(method, params, actor: actor)
    }

    /// The names of the items moved to the Trash.
    func trashedNames() -> [String] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(atPath: trash.path)) ?? []
        return folders.flatMap { (try? manager.contentsOfDirectory(atPath: trash.appendingPathComponent($0).path)) ?? [] }.sorted()
    }
}

/// Runs `body` with a started engine whose Trash is a temporary folder. `prepare` receives the
/// data directory and the projects folder before the engine opens them.
func withDomainEngine<T>(prepare: (DataDirectory, URL) throws -> Void = { _, _ in },
                         _ body: (DomainHarness) async throws -> T) async throws -> T {
    try await withTemporaryDirectory { folder in
        let directory = DataDirectory(url: folder.appendingPathComponent("Data", isDirectory: true))
        let projects = folder.appendingPathComponent("Projects", isDirectory: true)
        let trash = folder.appendingPathComponent("Trash", isDirectory: true)
        for url in [directory.url, projects, trash] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try prepare(directory, projects)
        let configuration = EngineConfiguration.test(dataDirectory: directory.url, claudeLauncher: NoClaudeLauncher())
        let engine = try await Engine(configuration: configuration)
        await engine.useFileTrash(.folder(trash))
        await engine.start()
        // The reload rules are tested by calling the domain's hooks; the FSEvents streams that
        // call them are tested in Files/, and their files.changed events would mix with the
        // events these tests expect.
        await engine.stopFileWatching()
        let connection = await LocalEngineConnection(engine: engine)
        let harness = DomainHarness(engine: engine, connection: connection, folder: folder, projects: projects, trash: trash)
        do {
            let result = try await body(harness)
            connection.close()
            await engine.shutdown()
            return result
        } catch {
            connection.close()
            await engine.shutdown()
            throw error
        }
    }
}

extension Engine {
    /// Adds chat metadata in memory, as core-claude does when it creates a chat.
    func testUpsertChat(_ meta: ChatMeta) {
        domain.upsertChat(meta)
    }

    /// The in-memory project data, for checks.
    var testDomain: DomainState {
        domain
    }
}

/// Collects the events the engine emits from the moment the recorder subscribes. It subscribes
/// to the engine itself: the events of the calls that returned before are never recorded, even
/// when the connection has not delivered them yet.
final class DomainEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EngineEventEnvelope] = []

    private init(_ stream: AsyncStream<Data>) {
        Task { [weak self] in
            for await data in stream {
                guard let event = try? EngineJSON.decode(EngineEventEnvelope.self, from: data) else { continue }
                self?.append(event)
            }
        }
    }

    // The task ends when the engine stops.

    /// A recorder of the events emitted after the calls made before.
    static func make(_ harness: DomainHarness) async -> DomainEventRecorder {
        DomainEventRecorder(await harness.engine.subscribe())
    }

    private func append(_ event: EngineEventEnvelope) {
        lock.withLock { events.append(event) }
    }

    /// The events received so far.
    var all: [EngineEventEnvelope] {
        lock.withLock { events }
    }

    /// The names of the events received so far.
    var names: [String] {
        all.map(\.name)
    }

    /// Forgets the events received so far.
    func clear() {
        lock.withLock { events.removeAll() }
    }

    /// Waits until `predicate` holds for the events received, at most `timeout`; returns the
    /// events then.
    @discardableResult
    func wait(timeout: Duration = .seconds(5), until predicate: ([EngineEventEnvelope]) -> Bool) async -> [EngineEventEnvelope] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = all
            if predicate(current) { return current }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return all
    }

    /// Waits until an event named `name` arrived, then returns the names received.
    @discardableResult
    func wait(for name: String, count: Int = 1, timeout: Duration = .seconds(5)) async -> [String] {
        await wait(timeout: timeout) { events in events.filter { $0.name == name }.count >= count }.map(\.name)
    }

    /// Waits a short time so that events emitted by a finished call have arrived.
    func settle() async -> [String] {
        try? await Task.sleep(for: .milliseconds(100))
        return names
    }
}

/// A title namer that answers a fixed title after an optional delay.
struct FixedTitleNamer: TitleNamer {
    var title: String?
    var delay: Duration = .zero

    func title(for subject: NamingSubject) async -> String? {
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return title
    }
}

/// A description that follows the ticket template.
let templateDescription = """
    Problem
    Locked tabs close with Command-W.

    Current Behavior
    1. Lock a tab.

    Expected
    The tab stays open.

    Change
    Check the lock.

    Docs
    - docs/web-tabs.md
    """

/// Writes a text file, creating its folders.
func writeFile(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// The text of a file.
func readFile(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// A minimal project file.
func projectYAML(id: ProjectID, name: String, subprojects: [String] = [], extra: String = "") -> String {
    var text = "schema: 1\nid: \(id)\nname: \(name)\ncreated: 2026-10-31T12:00:00Z\n"
    if !subprojects.isEmpty {
        text += "subprojects:\n" + subprojects.map { "  - \($0)\n" }.joined()
    }
    return text + extra
}

/// A minimal ticket file.
func ticketYAML(id: TicketID, title: String, status: String = "todo", extra: String = "") -> String {
    "schema: 1\nid: \(id)\ntitle: \(title)\nstatus: \(status)\ncreated: 2026-10-30T15:00:00Z\n" + extra
}

/// A registry file listing `paths`.
func registryYAML(_ paths: [String]) -> String {
    "schema: 1\nprojects:\n" + paths.map { "  - \($0)\n" }.joined()
}
