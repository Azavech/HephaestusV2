import Foundation
@testable import HephaestusCore

/// The folders of a test project: the project `TEST` at `<temp>/Project`, registered in the
/// data directory before the engine starts, optionally with the sub project `SUB` at
/// `<temp>/Project/Sub`, and a fake Trash at `<temp>/Trash`.
struct FileTestProject {
    static let id: ProjectID = "TEST"
    static let subID: ProjectID = "SUB"

    let folder: URL
    var root: URL { folder.appendingPathComponent("Project", isDirectory: true) }
    var subRoot: URL { root.appendingPathComponent("Sub", isDirectory: true) }
    var trash: URL { folder.appendingPathComponent("Trash", isDirectory: true) }

    /// The URL of a project path of `TEST`.
    func url(_ path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    /// Writes a file of `TEST`, creating its folders.
    func write(_ path: String, _ text: String) throws {
        try write(path, Data(text.utf8))
    }

    func write(_ path: String, _ data: Data) throws {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileItem.at(url(path).path) != nil
    }

    /// The names moved to the fake Trash, which keeps each item in its own folder.
    func trashedNames() throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: trash.path) else { return [] }
        return try manager.contentsOfDirectory(atPath: trash.path).flatMap { folder in
            try manager.contentsOfDirectory(atPath: trash.appendingPathComponent(folder).path)
        }.sorted()
    }
}

/// Runs `body` with a started test engine whose registry holds the project `TEST` (and its sub
/// project `SUB` when `subproject` is true), a fake Trash, and the files of `files` written
/// before the engine starts.
func withFileTestEngine<T>(subproject: Bool = false, docsPath: String = "docs", files: [String: String] = [:],
                           _ body: (Engine, LocalEngineConnection, FileTestProject) async throws -> T) async throws -> T {
    var project: FileTestProject?
    return try await withTestEngine(prepare: { directory in
        let fixture = FileTestProject(folder: directory.url.deletingLastPathComponent())
        project = fixture
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try ProjectFileStore.write(Project(id: FileTestProject.id, name: "Test", created: created, docsPath: docsPath,
                                           subprojects: subproject ? ["Sub"] : []),
                                   to: ProjectFolder(root: fixture.root))
        if subproject {
            try ProjectFileStore.write(Project(id: FileTestProject.subID, name: "Sub", created: created),
                                       to: ProjectFolder(root: fixture.subRoot))
        }
        for (path, text) in files {
            try fixture.write(path, text)
        }
        try DeviceFileStore.write(Registry(projects: [fixture.root.path]), to: directory)
    }) { engine, connection, _ in
        let fixture = project!
        let trash = fixture.trash
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        await engine.useFileTrash(FileTrash { url in
            let folder = trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        })
        return try await body(engine, connection, fixture)
    }
}

/// Writes an executable shell script and returns its path.
@discardableResult
func writeScript(_ url: URL, _ body: String) throws -> String {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

/// The files.changed events of a stream, decoded.
func filesChangedPayload(_ envelope: EngineEventEnvelope) -> FilesChangedEvent.Payload? {
    guard envelope.name == FilesChangedEvent.name else { return nil }
    return try? envelope.payload(FilesChangedEvent.self)
}

/// The first files.changed event of `projectID` whose paths satisfy `predicate`, or nil after
/// `timeout`.
func filesChanged(on stream: AsyncStream<EngineEventEnvelope>, projectID: ProjectID = FileTestProject.id,
                  timeout: Duration = .seconds(20),
                  where predicate: @escaping @Sendable ([String]) -> Bool) async -> FilesChangedEvent.Payload? {
    let envelope = await firstElement(of: stream, timeout: timeout) { envelope in
        guard let payload = filesChangedPayload(envelope), payload.projectID == projectID else { return false }
        return predicate(payload.paths)
    }
    return envelope.flatMap(filesChangedPayload)
}

/// Collects values sent from other tasks, for observers.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
