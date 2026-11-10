import Foundation
import Testing
@testable import HephaestusCore

/// A launcher that starts nothing: these tests never reach a Claude process. Its processes are
/// inert, so the CLI lookup in the login shell lasts until its timeout; engines that use it get
/// `ClaudeCLITimings.inert`.
struct NoClaudeLauncher: ClaudeProcessLauncher {}

extension ClaudeCLITimings {
    /// The timings of an engine with `NoClaudeLauncher`: the inert CLI lookup outlasts every test,
    /// so the status stays `checking` and no `claude.updated` comes among the events a test
    /// checks, however long the test takes. The shutdown ends the lookup.
    static var inert: ClaudeCLITimings {
        var timings = ClaudeCLITimings()
        timings.loginShellTimeout = .seconds(3600)
        return timings
    }
}

extension Engine {
    /// Sets the Claude CLI timings before `start()`.
    func useCLITimings(_ timings: ClaudeCLITimings) {
        claudeCLI.timings = timings
    }

    /// Replaces the Haiku namer before `start()`.
    func useTitleNamer(_ namer: any TitleNamer) {
        titleNamer = namer
    }
}

extension FileTrash {
    /// A Trash that moves items into `folder`, so that tests never fill the Trash of the user
    /// running them: each item lands in a new sub-folder so that equal names never collide.
    static func folder(_ folder: URL) -> FileTrash {
        FileTrash { url in
            let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
        }
    }

    /// A Trash that cannot be used, for the `unavailable` errors.
    static let unavailable = FileTrash { _ in throw NoTrashFailure() }

    struct NoTrashFailure: LocalizedError {
        var errorDescription: String? { "the volume has no Trash" }
    }
}

/// A counting semaphore whose waiters are served in order, priority waiters first.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) {
        available = count
    }

    func acquire(priority: Bool = false) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if available > 0 {
                available -= 1
                lock.unlock()
                continuation.resume()
            } else {
                if priority { waiters.insert(continuation, at: 0) } else { waiters.append(continuation) }
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            available += 1
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }

    func withPermit<T>(priority: Bool = false, _ body: () async throws -> T) async rethrows -> T {
        await acquire(priority: priority)
        defer { release() }
        return try await body()
    }
}

/// Swift Testing starts every test of the run at once. A test engine opens one FSEvents stream
/// per watched folder (the data directory, the skills library and each project root), and a
/// process gets at most 512 streams: past that `FSEventStreamStart` fails and the engine
/// watches nothing. So at most `limit` test engines run at the same time; the tests that build
/// one wait here. An engine built inside another test engine's body shares that engine's slot.
enum TestEngineSlots {
    static let limit = 32
    private static let gate = AsyncGate(limit)
    @TaskLocal private static var held = false
    /// True inside `FSEventsTests.serialized`: those tests get the next free slot.
    @TaskLocal static var first = false

    static func withSlot<T>(_ body: () async throws -> T) async throws -> T {
        if held { return try await body() }
        return try await gate.withPermit(priority: first) {
            try await $held.withValue(true) { try await body() }
        }
    }
}

/// The tests that wait for FSEvents run one at a time, across suites, so that no other
/// watching test's writes compete with their timing checks; each also gets the next free
/// engine slot. Mark them with the trait `.fsEvents`.
enum FSEventsTests {
    private static let gate = AsyncGate(1)

    static func serialized<T>(_ body: () async throws -> T) async throws -> T {
        try await gate.withPermit {
            try await TestEngineSlots.$first.withValue(true) { try await body() }
        }
    }
}

/// Runs each test it is applied to (each test of a suite it is applied to) through
/// `FSEventsTests.serialized`.
struct FSEventsTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await FSEventsTests.serialized { try await function() }
    }
}

extension Trait where Self == FSEventsTrait {
    /// The test waits for FSEvents: see `FSEventsTests`.
    static var fsEvents: Self { Self() }
}

/// Runs `body` with a started test engine (docs/development.md › Test rules: a temporary data
/// directory, ports 0, the sync server on the loopback interface, no Bonjour advertising) and a
/// `LocalEngineConnection` to it, then closes both. `prepare` receives the data directory before
/// the engine opens it. `body` also receives the temporary directory that holds the data
/// directory, for other files of the test. `githubCLI` replaces the fake gh that is never found,
/// `imageProvisioner` the provisioner of virtual machine images whose every operation fails, and
/// `guestTools` gives the engine a guest agent and an install script.
func withTestEngine<T>(debugTools: Bool = false, githubCLI: (any GitHubCLIRunning)? = nil,
                       claudeLauncher: any ClaudeProcessLauncher = NoClaudeLauncher(),
                       imageProvisioner: (any VMImageProvisioning)? = nil, guestTools: GuestTools? = nil,
                       prepare: (DataDirectory) throws -> Void = { _ in },
                       _ body: (Engine, LocalEngineConnection, URL) async throws -> T) async throws -> T {
    try await TestEngineSlots.withSlot { try await withTemporaryDirectory { folder in
        let directory = DataDirectory(url: folder.appendingPathComponent("Data", isDirectory: true))
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        try prepare(directory)
        let configuration = EngineConfiguration.test(dataDirectory: directory.url, debugTools: debugTools,
                                                     claudeLauncher: claudeLauncher, githubCLI: githubCLI,
                                                     imageProvisioner: imageProvisioner, guestTools: guestTools)
        let engine = try await Engine(configuration: configuration)
        await engine.useFileTrash(.folder(folder.appendingPathComponent("Trash", isDirectory: true)))
        await engine.useCLITimings(.inert)
        await engine.start()
        let connection = await LocalEngineConnection(engine: engine)
        do {
            let result = try await body(engine, connection, folder)
            connection.close()
            await engine.shutdown()
            return result
        } catch {
            connection.close()
            await engine.shutdown()
            throw error
        }
    } }
}

/// The first element of `stream` that satisfies `predicate`, or nil after `timeout`.
func firstElement<Element: Sendable>(of stream: AsyncStream<Element>, timeout: Duration = waitLimit,
                                     where predicate: @escaping @Sendable (Element) -> Bool = { _ in true }) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await element in stream where predicate(element) {
                return element
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// The first `count` elements of `stream`; empty when they do not all arrive within `timeout`.
func firstElements<Element: Sendable>(_ count: Int, of stream: AsyncStream<Element>,
                                      timeout: Duration = waitLimit) async -> [Element] {
    await withTaskGroup(of: [Element]?.self) { group in
        group.addTask {
            var elements: [Element] = []
            for await element in stream {
                elements.append(element)
                if elements.count == count { return elements }
            }
            return elements
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}

/// The first event named `name` on `stream`, or nil after `timeout`.
func firstEvent(named name: String, on stream: AsyncStream<EngineEventEnvelope>,
                timeout: Duration = waitLimit) async -> EngineEventEnvelope? {
    await firstElement(of: stream, timeout: timeout) { $0.name == name }
}

/// The EngineError a call throws, or nil when it succeeds or throws another error.
func engineError<T>(_ body: () async throws -> T) async -> EngineError? {
    do {
        _ = try await body()
        return nil
    } catch let error as EngineError {
        return error
    } catch {
        return nil
    }
}

/// The rows of every Markdown table of a document: the header cells and the cells of each row,
/// trimmed. Cells are split on `|`; the docs' tables hold no `|` inside a cell.
struct MarkdownTable {
    var header: [String]
    var rows: [[String]]

    static func tables(in text: String) -> [MarkdownTable] {
        var tables: [MarkdownTable] = []
        var current: MarkdownTable?
        var sawSeparator = false
        for line in text.components(separatedBy: "\n") {
            guard line.hasPrefix("|") else {
                if let table = current { tables.append(table) }
                current = nil
                sawSeparator = false
                continue
            }
            let cells = line.trimmingCharacters(in: .whitespaces)
                .dropFirst().dropLast()
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if current == nil {
                current = MarkdownTable(header: cells, rows: [])
            } else if !sawSeparator {
                sawSeparator = true
            } else {
                current?.rows.append(cells)
            }
        }
        if let table = current { tables.append(table) }
        return tables
    }

    /// The backticked names of a cell, in order: `` `a`, `b` `` gives `["a", "b"]`.
    static func backtickedNames(in cell: String) -> [String] {
        let parts = cell.split(separator: "`", omittingEmptySubsequences: false)
        return stride(from: 1, to: parts.count, by: 2).map { String(parts[$0]) }
    }
}

/// A JSON text as a `JSONValue`.
func jsonValue(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}
