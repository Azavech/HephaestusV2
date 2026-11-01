import Foundation
@testable import HephaestusCore

/// A launcher that starts nothing: these tests never reach a Claude process.
struct NoClaudeLauncher: ClaudeProcessLauncher {}

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

/// Runs `body` with a started test engine (docs/development.md › Test rules: a temporary data
/// directory, ports 0, the sync server on the loopback interface, no Bonjour advertising) and a
/// `LocalEngineConnection` to it, then closes both. `prepare` receives the data directory before
/// the engine opens it. `body` also receives the temporary directory that holds the data
/// directory, for other files of the test.
func withTestEngine<T>(debugTools: Bool = false, prepare: (DataDirectory) throws -> Void = { _ in },
                       _ body: (Engine, LocalEngineConnection, URL) async throws -> T) async throws -> T {
    try await withTemporaryDirectory { folder in
        let directory = DataDirectory(url: folder.appendingPathComponent("Data", isDirectory: true))
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        try prepare(directory)
        let configuration = EngineConfiguration.test(dataDirectory: directory.url, debugTools: debugTools,
                                                     claudeLauncher: NoClaudeLauncher())
        let engine = try await Engine(configuration: configuration)
        await engine.useFileTrash(.folder(folder.appendingPathComponent("Trash", isDirectory: true)))
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
    }
}

/// The first element of `stream` that satisfies `predicate`, or nil after `timeout`.
func firstElement<Element: Sendable>(of stream: AsyncStream<Element>, timeout: Duration = .seconds(5),
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
                                      timeout: Duration = .seconds(5)) async -> [Element] {
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
                timeout: Duration = .seconds(5)) async -> EngineEventEnvelope? {
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
