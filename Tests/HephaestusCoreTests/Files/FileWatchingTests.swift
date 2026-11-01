import Foundation
import Testing
@testable import HephaestusCore

/// FSEvents tests: each waits for the event it expects with a generous timeout, and checks what
/// must not happen against a later marker change, so that no test depends on a fixed delay.
@Suite("File watching", .serialized)
struct FileWatchingTests {
    /// Writes `marker.txt` until a files.changed event of `projectID` names it: the stream is
    /// running and every earlier change has been processed.
    @discardableResult
    private func sync(_ project: FileTestProject, _ stream: AsyncStream<EngineEventEnvelope>,
                      marker: String = "marker.txt") async throws -> FilesChangedEvent.Payload? {
        try project.write(marker, UUID().uuidString)
        return await filesChanged(on: stream) { $0.contains(marker) }
    }

    @Test("A change under the project root emits files.changed with origin system")
    func change() async throws {
        try await withFileTestEngine(files: ["src/.keep": ""]) { _, connection, project in
            let events = connection.events
            try project.write("src/main.go", "package main\n")
            let envelope = await firstElement(of: events, timeout: .seconds(20)) { envelope in
                filesChangedPayload(envelope)?.paths.contains("src/main.go") == true
            }
            let found = try #require(envelope)
            #expect(found.origin == .system)
            #expect(filesChangedPayload(found)?.projectID == "TEST")
        }
    }

    @Test("files.write, files.create, files.rename and files.trash are reported by the watcher")
    func engineChanges() async throws {
        try await withFileTestEngine(files: ["a.txt": "a"]) { _, connection, _ in
            let events = connection.events
            _ = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "written.txt", text: "w"))
            #expect(await filesChanged(on: events) { $0.contains("written.txt") } != nil)
            _ = try await connection.call(FilesCreate.self, .init(projectID: "TEST", path: "folder", isDirectory: true))
            #expect(await filesChanged(on: events) { $0.contains("folder") } != nil)
            _ = try await connection.call(FilesRename.self, .init(projectID: "TEST", path: "a.txt", newPath: "b.txt"))
            #expect(await filesChanged(on: events) { $0.contains("b.txt") } != nil)
            _ = try await connection.call(FilesTrash.self, .init(projectID: "TEST", path: "b.txt"))
            #expect(await filesChanged(on: events) { $0.contains("b.txt") } != nil)
        }
    }

    @Test("Changes inside .git/ and .hephaestus/chats/ emit no files.changed")
    func excluded() async throws {
        try await withFileTestEngine(files: [".git/HEAD": "ref", ".hephaestus/chats/.keep": ""]) { _, connection, project in
            let events = connection.events
            try await sync(project, events)
            let collected = Recorder<[String]>()
            let all = connection.events
            let collector = Task {
                for await envelope in all {
                    if let payload = filesChangedPayload(envelope) { collected.append(payload.paths) }
                }
            }
            try project.write(".git/index", "x")
            try project.write(".git/objects/ab/cdef", "x")
            try project.write(".hephaestus/chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301.jsonl", "{}\n")
            try project.write("visible.txt", "v")
            let visible = await filesChanged(on: events) { $0.contains("visible.txt") }
            #expect(visible != nil)
            try await sync(project, events, marker: "marker2.txt")
            collector.cancel()
            let paths = collected.values.flatMap { $0 }
            #expect(!paths.isEmpty)
            #expect(paths.allSatisfy { !$0.hasPrefix(".git") && !$0.hasPrefix(".hephaestus/chats") })
        }
    }

    @Test("A sub project gets its own files.changed with its own paths")
    func subproject() async throws {
        try await withFileTestEngine(subproject: true, files: ["Sub/src/.keep": ""]) { _, connection, project in
            let parentEvents = connection.events
            let subEvents = connection.events
            try project.write("Sub/src/lib.swift", "let x = 1\n")
            #expect(await filesChanged(on: parentEvents, projectID: "TEST") { $0.contains("Sub/src/lib.swift") } != nil)
            #expect(await filesChanged(on: subEvents, projectID: "SUB") { $0.contains("src/lib.swift") } != nil)
        }
    }

    @Test("Changes under .hephaestus/ reach projectDataFilesChanged, project files first")
    func dataFiles() async throws {
        try await withFileTestEngine(subproject: true) { engine, connection, project in
            let calls = Recorder<(ProjectID, [String])>()
            await engine.observeProjectDataChanges { calls.append(($0, $1)) }
            let events = connection.events
            try await sync(project, events)
            var before = calls.values.count

            try project.write(".hephaestus/ticket/TEST-1.yml", "id: TEST-1\n")
            try project.write(".hephaestus/ticket/notes.txt", "x")
            try project.write(".hephaestus/attachments/TEST-1/a.png", "x")
            try project.write(".hephaestus/chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301.yml", "x")
            try project.write("Sub/.hephaestus/bundle/SUB-B1.yml", "id: SUB-B1\n")
            #expect(await filesChanged(on: events) { $0.contains(".hephaestus/ticket/TEST-1.yml") } != nil)
            try await sync(project, events)
            var later = calls.values.dropFirst(before)
            let byProject = Dictionary(grouping: later, by: \.0).mapValues { Set($0.flatMap(\.1)) }
            #expect(byProject["TEST"]?.contains(".hephaestus/ticket/TEST-1.yml") == true)
            #expect(byProject["TEST"]?.isSubset(of: [".hephaestus/ticket", ".hephaestus/ticket/TEST-1.yml"]) == true)
            #expect(byProject["SUB"]?.contains(".hephaestus/bundle/SUB-B1.yml") == true)
            #expect(byProject["SUB"]?.isSubset(of: [".hephaestus/bundle", ".hephaestus/bundle/SUB-B1.yml"]) == true)

            before = calls.values.count
            try project.write(".hephaestus/project.yml", try project.text(".hephaestus/project.yml") + "extra: 1\n")
            try project.write("Sub/.hephaestus/project.yml", try project.text("Sub/.hephaestus/project.yml") + "extra: 1\n")
            #expect(await filesChanged(on: events, projectID: "SUB") { $0.contains(".hephaestus/project.yml") } != nil)
            try await sync(project, events)
            later = calls.values.dropFirst(before)
            let projectFiles = later.filter { $0.1 == [".hephaestus/project.yml"] }.map(\.0)
            #expect(Set(projectFiles) == ["TEST", "SUB"])
            if projectFiles.count == 2, later.count == 2 {
                // One batch: the parent's project file comes first.
                #expect(projectFiles == ["TEST", "SUB"])
            }
        }
    }

    @Test("The engine's own writes and removals do not reach projectDataFilesChanged")
    func ownWrites() async throws {
        try await withFileTestEngine(files: [".hephaestus/ticket/TEST-2.yml": "id: TEST-2\n"]) { engine, connection, project in
            let calls = Recorder<(ProjectID, [String])>()
            await engine.observeProjectDataChanges { calls.append(($0, $1)) }
            let events = connection.events
            try await sync(project, events)
            var before = calls.values.count

            let own = Data("id: TEST-1\n".utf8)
            let ownURL = project.url(".hephaestus/ticket/TEST-1.yml")
            let digest = try AtomicFile.write(own, to: ownURL)
            await engine.ownWrites.recordWrite(path: ownURL.path, sha256: digest)
            let removed = project.url(".hephaestus/ticket/TEST-2.yml")
            await engine.ownWrites.recordRemoval(path: removed.path)
            try FileManager.default.removeItem(at: removed)
            #expect(await filesChanged(on: events) { $0.contains(".hephaestus/ticket/TEST-1.yml") } != nil)
            try await sync(project, events)
            #expect(calls.values.dropFirst(before).flatMap(\.1).isEmpty)

            before = calls.values.count
            try project.write(".hephaestus/ticket/TEST-1.yml", "id: TEST-1\nchanged: true\n")
            #expect(await filesChanged(on: events) { $0.contains(".hephaestus/ticket/TEST-1.yml") } != nil)
            try await sync(project, events)
            #expect(calls.values.dropFirst(before).flatMap(\.1) == [".hephaestus/ticket/TEST-1.yml"])
        }
    }

    @Test("Events wait 300 ms of quiet, and at most 2 s after the first change")
    func debounce() async throws {
        try await withFileTestEngine { _, connection, project in
            let events = connection.events
            try await sync(project, events)

            var start = ContinuousClock.now
            try project.write("single.txt", "x")
            #expect(await filesChanged(on: events) { $0.contains("single.txt") } != nil)
            #expect(ContinuousClock.now - start >= .milliseconds(290))

            // Changes every 100 ms for 6 s never leave 300 ms of quiet: the first event comes
            // 2 s after the first change, long before the changes stop.
            let writer = Task {
                for index in 0..<60 {
                    try project.write("busy/\(index).txt", "x")
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            start = ContinuousClock.now
            let first = await filesChanged(on: events) { $0.contains { $0.hasPrefix("busy") } }
            let elapsed = ContinuousClock.now - start
            writer.cancel()
            #expect(first != nil)
            #expect(elapsed >= .milliseconds(1900))
            #expect(elapsed < .milliseconds(5500))
        }
    }

    @Test("A project root that is moved away and back is reported whole and still watched")
    func rootChanged() async throws {
        try await withFileTestEngine { _, connection, project in
            let events = connection.events
            try await sync(project, events)
            let moved = project.folder.appendingPathComponent("Moved")
            try FileManager.default.moveItem(at: project.root, to: moved)
            try FileManager.default.moveItem(at: moved, to: project.root)
            #expect(await filesChanged(on: events) { $0 == [""] } != nil)
            #expect(try await sync(project, events, marker: "after.txt") != nil)
        }
    }

    @Test("A registered root created after the engine started is watched once it exists")
    func lateRoot() async throws {
        try await withFileTestEngine { _, connection, project in
            let events = connection.events
            try await sync(project, events)
            let parked = project.folder.appendingPathComponent("Parked")
            try FileManager.default.moveItem(at: project.root, to: parked)
            // Wait until the move is processed: the project is no longer loaded, so the next
            // events come from the root once it is back.
            try await Task.sleep(for: .milliseconds(800))
            try FileManager.default.moveItem(at: parked, to: project.root)
            #expect(await filesChanged(on: events) { $0 == [""] } != nil)
            #expect(try await sync(project, events, marker: "late.txt") != nil)
        }
    }

    @Test("A sub project whose project file reappears in its listed folder loads again")
    func projectFileAppears() async throws {
        try await withFileTestEngine(subproject: true) { _, connection, project in
            let events = connection.events
            try await sync(project, events)
            let file = project.subRoot.appendingPathComponent(".hephaestus/project.yml")
            let saved = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            let removed = try #require(await firstEvent(named: ProjectRemovedEvent.name, on: events, timeout: .seconds(20)))
            #expect(try removed.payload(ProjectRemovedEvent.self).projectID == FileTestProject.subID)
            try saved.write(to: file)
            let changed = await firstElement(of: events, timeout: .seconds(20)) { envelope in
                guard envelope.name == ProjectsChangedEvent.name,
                      let list = try? envelope.payload(ProjectsChangedEvent.self) else { return false }
                return list.contains { $0.id == FileTestProject.subID }
            }
            #expect(changed?.origin == .system)
            #expect(try await connection.call(ProjectsList.self).map(\.id) == [FileTestProject.id, FileTestProject.subID])
        }
    }

    @Test("An external edit of registry.yml loads the added projects and unloads the removed ones")
    func registryFile() async throws {
        try await withFileTestEngine { engine, connection, project in
            let events = connection.events
            let other = project.folder.appendingPathComponent("Other", isDirectory: true)
            try ProjectFileStore.write(Project(id: "OTHER", name: "Other", created: Date(timeIntervalSince1970: 1_790_000_000)),
                                       to: ProjectFolder(root: other))
            try DeviceFileStore.write(Registry(projects: [other.path]), to: engine.dataDirectory)
            let removed = try #require(await firstEvent(named: ProjectRemovedEvent.name, on: events, timeout: .seconds(20)))
            #expect(removed.origin == .system)
            #expect(try removed.payload(ProjectRemovedEvent.self).projectID == FileTestProject.id)
            #expect(try await connection.call(ProjectsList.self).map(\.id) == ["OTHER"])
            #expect(await engine.watchedFolders() == [engine.dataDirectory.url.path, other.path])
        }
    }

    @Test("More than 500 changed paths are reduced to their ancestors")
    func manyPaths() async throws {
        try await withFileTestEngine { _, connection, project in
            let events = connection.events
            try await sync(project, events)
            let collected = Recorder<[String]>()
            let all = connection.events
            let collector = Task {
                for await envelope in all {
                    if let payload = filesChangedPayload(envelope) { collected.append(payload.paths) }
                }
            }
            try project.makeDirectory("generated/a")
            for index in 0..<700 {
                FileManager.default.createFile(atPath: project.url("generated/a/f\(index)").path, contents: nil)
            }
            try await sync(project, events, marker: "marker2.txt")
            collector.cancel()
            #expect(!collected.values.isEmpty)
            #expect(collected.values.allSatisfy { $0.count <= 500 })
            let reported = collected.values.flatMap { $0 }
            #expect(reported.contains { $0 == "generated" || $0.hasPrefix("generated/") })
        }
    }

    @Test("An external edit of settings.yml applies like settings.update")
    func settingsFile() async throws {
        try await withFileTestEngine { engine, connection, _ in
            let events = connection.events
            var settings = try await connection.call(SettingsGet.self)
            #expect(settings.formatGoOnSave)
            settings.formatGoOnSave = false
            try DeviceFileStore.write(settings, to: engine.dataDirectory)
            let envelope = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: events, timeout: .seconds(20)))
            #expect(envelope.origin == .system)
            #expect(try envelope.payload(SettingsUpdatedEvent.self).formatGoOnSave == false)
            #expect(try await connection.call(SettingsGet.self).formatGoOnSave == false)
        }
    }

    @Test("An invalid settings.yml leaves the settings in memory unchanged")
    func invalidSettingsFile() async throws {
        try await withFileTestEngine { engine, connection, project in
            let events = connection.events
            let settingsEvents = connection.events
            let original = try await connection.call(SettingsGet.self)
            try Data("schema: 1\nmcpPort: [1\n".utf8).write(to: engine.dataDirectory.settingsFile)
            try await sync(project, events)
            #expect(try await connection.call(SettingsGet.self) == original)

            var settings = original
            settings.formatSwiftOnSave = true
            try DeviceFileStore.write(settings, to: engine.dataDirectory)
            let envelope = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: settingsEvents, timeout: .seconds(20)))
            #expect(try envelope.payload(SettingsUpdatedEvent.self) == settings)
        }
    }

    @Test("Watching stops with the engine")
    func stop() async throws {
        try await withFileTestEngine { engine, connection, project in
            let events = connection.events
            try await sync(project, events)
            #expect(await engine.watchedFolders() == [engine.dataDirectory.url.path, project.root.path])
            await engine.stopFileWatching()
            #expect(await engine.watchedFolders().isEmpty)
            await engine.startFileWatching()
            #expect(try await sync(project, events, marker: "restarted.txt") != nil)
        }
    }
}
