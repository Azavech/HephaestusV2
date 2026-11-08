import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › Memories and docs/memories.md, through `LocalEngineConnection`. The test
/// engine resolves memory folders under its temporary folder (docs/development.md › Test rules).
@Suite("Memories methods")
struct MemoriesEngineTests {
    struct Bed {
        var engine: Engine
        var connection: LocalEngineConnection
        var folder: URL
        var trash: URL
        /// The memory folder of the project `MEM`.
        var memories: URL
    }

    /// Runs `body` with a started engine, the project `MEM` at `<temp>/Project` and its memory
    /// folder, which does not exist yet.
    private func withMemoriesEngine(_ body: (Bed) async throws -> Void) async throws {
        try await withTestEngine { engine, connection, folder in
            let trash = folder.appendingPathComponent("Trash", isDirectory: true)
            await engine.useTestTrash(trash)
            let root = folder.appendingPathComponent("Project", isDirectory: true)
            _ = try await connection.call(ProjectsCreate.self, .init(rootPath: root.path, name: "Memories", identifier: "MEM",
                                                                     createDirectory: true))
            let listing = try await connection.call(MemoriesList.self, .init(projectID: "MEM"))
            let memories = URL(fileURLWithPath: listing.path, isDirectory: true)
            try await body(Bed(engine: engine, connection: connection, folder: folder, trash: trash, memories: memories))
        }
    }

    private func write(_ file: String, in folder: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent(file))
    }

    private func read(_ file: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
    }

    private func memory(_ name: String, type: String?, description: String = "About it", body: String = "\nBody.\n") -> String {
        let typeLines = type.map { "metadata:\n  type: \($0)\n" } ?? ""
        return "---\nname: \(name)\ndescription: \(description)\n\(typeLines)---\n\(body)"
    }

    // MARK: Folder and listing

    @Test("memories.list gives the folder under the test config folder, MEMORY.md and the memories sorted by name")
    func list() async throws {
        try await withMemoriesEngine { bed in
            let root = ClaudeMemoryFolderResolver.realPath(bed.folder.appendingPathComponent("Project").path)
            #expect(bed.memories.path == bed.folder.appendingPathComponent("Claude").path + "/projects/"
                + ClaudeMemoryFolderResolver.folderName(of: root) + "/memory")
            #expect(try await bed.connection.call(MemoriesList.self, .init(projectID: "mem"))
                == MemoryFolder(projectID: "MEM", path: bed.memories.path, hasIndex: false, memories: []))

            try write("MEMORY.md", in: bed.memories, "- [b](b.md) — B\n")
            try write("b.md", in: bed.memories, memory("beta", type: "user"))
            try write("a.md", in: bed.memories, memory("alpha", type: "feedback"))
            try write("z.md", in: bed.memories, memory("alpha", type: nil))
            try write("old.md", in: bed.memories, "---\nname: old\ndescription: Old format\ntype: project\n---\n")
            try write("loose.md", in: bed.memories, "No frontmatter.\n")
            try write("broken.md", in: bed.memories, "---\nname: broken\n")
            try write(".hidden.md", in: bed.memories, memory("hidden", type: "user"))
            try write("notes.txt", in: bed.memories, "not a memory")
            try write("inner.md", in: bed.memories.appendingPathComponent("proposals"), memory("inner", type: "user"))
            try FileManager.default.createDirectory(at: bed.memories.appendingPathComponent("folder.md"), withIntermediateDirectories: true)

            let listing = try await bed.connection.call(MemoriesList.self, .init(projectID: "MEM"))
            #expect(listing.hasIndex)
            #expect(listing.memories == [
                MemorySummary(file: "a.md", name: "alpha", description: "About it", type: "feedback"),
                MemorySummary(file: "z.md", name: "alpha", description: "About it"),
                MemorySummary(file: "b.md", name: "beta", description: "About it", type: "user"),
                MemorySummary(file: "loose.md", name: "loose", description: ""),
                MemorySummary(file: "old.md", name: "old", description: "Old format", type: "project"),
            ])
        }
    }

    @Test("A sub project in the same repository shows the memories of its parent")
    func subProject() async throws {
        try await withMemoriesEngine { bed in
            let root = bed.folder.appendingPathComponent("Project")
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            _ = try await bed.connection.call(ProjectsCreate.self, .init(rootPath: root.appendingPathComponent("site").path, name: "Site",
                                                                         identifier: "SITE", parentID: "MEM", createDirectory: true))
            let parent = try await bed.connection.call(MemoriesList.self, .init(projectID: "MEM"))
            let child = try await bed.connection.call(MemoriesList.self, .init(projectID: "SITE"))
            #expect(child.path == parent.path)
            #expect(child.projectID == "SITE")

            // A change made through one project emits memories.changed for both watched projects.
            let events = bed.connection.events
            _ = try await bed.connection.call(MemoriesCreate.self, .init(projectID: "SITE", name: "shared", description: "D", type: .project))
            let user = Actor.user(deviceID: bed.engine.deviceID)
            var changed: [MemoryFolder] = []
            for _ in 0..<2 {
                let event = await firstElement(of: events) { $0.name == MemoriesChangedEvent.name && $0.origin == user }
                changed.append(try #require(try event?.payload(MemoriesChangedEvent.self)))
            }
            #expect(Set(changed.map(\.projectID)) == ["MEM", "SITE"])
            #expect(changed.allSatisfy { $0.memories.map(\.name) == ["shared"] && $0.path == parent.path })
        }
    }

    @Test("memories.get gives a memory and refuses bad file names, MEMORY.md, missing and unreadable files")
    func get() async throws {
        try await withMemoriesEngine { bed in
            try write("feedback_style.md", in: bed.memories, MemoryFileTests.example)
            try write("broken.md", in: bed.memories, "---\nname: broken\n")
            let memory = try await bed.connection.call(MemoriesGet.self, .init(projectID: "MEM", file: "feedback_style.md"))
            #expect(memory.name == "answer-style")
            #expect(memory.type == "feedback")

            func failure(_ file: String) async -> EngineError? {
                await engineError { try await bed.connection.call(MemoriesGet.self, .init(projectID: "MEM", file: file)) }
            }
            #expect(await failure("missing.md") == EngineError(.notFound, "Memory missing.md not found."))
            #expect(await failure("MEMORY.md") == EngineError(.invalid, "Use memories.readIndex and memories.writeIndex for MEMORY.md."))
            #expect(await failure("../x.md") == EngineError(.invalid, "file: use the name of a .md file of the memory folder."))
            #expect(await failure("x.txt")?.code == .invalid)
            #expect(await failure(".md")?.code == .invalid)
            #expect(await failure("broken.md") == EngineError(.invalid, "broken.md is not a memory file: its frontmatter has no closing --- line."))
            #expect(await engineError { try await bed.connection.call(MemoriesGet.self, .init(projectID: "NOPE", file: "a.md")) }
                == EngineError(.notFound, "Project NOPE not found."))
            #expect(await engineError { try await bed.connection.call(MemoriesList.self, .init(projectID: "x1")) }
                == EngineError(.invalid, "projectID: use 2 to 8 letters A–Z."))
        }
    }

    // MARK: Create

    @Test("memories.create writes <name>.md and appends its MEMORY.md line, creating the folder, and emits memories.changed")
    func create() async throws {
        try await withMemoriesEngine { bed in
            let events = bed.connection.events
            let memory = try await bed.connection.call(MemoriesCreate.self, .init(projectID: "MEM", name: "user-role",
                                                                                  description: "Backend\r\ndeveloper", type: .user))
            #expect(memory == Memory(file: "user-role.md", name: "user-role", description: "Backend\ndeveloper", type: "user", body: ""))
            #expect(try read("user-role.md", in: bed.memories)
                == "---\nname: user-role\ndescription: |-\n  Backend\n  developer\nmetadata:\n  type: user\n---\n")
            #expect(try read("MEMORY.md", in: bed.memories) == "- [user-role](user-role.md) — Backend developer\n")
            let event = try #require(await firstEvent(named: MemoriesChangedEvent.name, on: events))
            #expect(event.origin == .user(deviceID: bed.engine.deviceID))
            #expect(try event.payload(MemoriesChangedEvent.self) == MemoryFolder(
                projectID: "MEM", path: bed.memories.path, hasIndex: true,
                memories: [MemorySummary(file: "user-role.md", name: "user-role", description: "Backend\ndeveloper", type: "user")]))

            try write("MEMORY.md", in: bed.memories, "# Index")
            _ = try await bed.connection.call(MemoriesCreate.self, .init(projectID: "MEM", name: "style", description: "Short", type: .feedback))
            #expect(try read("MEMORY.md", in: bed.memories) == "# Index\n- [style](style.md) — Short\n")
        }
    }

    @Test("memories.create refuses invalid params and taken names")
    func createErrors() async throws {
        try await withMemoriesEngine { bed in
            try write("user_role.md", in: bed.memories, memory("user-role", type: "user"))
            func create(_ name: String, _ description: String = "D") async -> EngineError? {
                await engineError {
                    try await bed.connection.call(MemoriesCreate.self, .init(projectID: "MEM", name: name, description: description, type: .user))
                }
            }
            #expect(await create("User Role")
                == EngineError(.invalid, "name: use at most 64 lowercase letters, digits and single hyphens between them."))
            #expect(await create("memory") == EngineError(.invalid, "name: memory names the index MEMORY.md."))
            #expect(await create("fine", "") == EngineError(.invalid, "description: use at least 1 character."))
            #expect(await create("user-role") == EngineError(.conflict, "A memory named user-role already exists."))
            #expect(await create("user_role")?.code == .invalid)
            try write("taken.md", in: bed.memories, "Body only, named taken by its file.\n")
            #expect(await create("taken") == EngineError(.conflict, "A memory named taken already exists."))
            if !SkillsLibraryReader.isCaseSensitiveVolume(bed.memories) {
                try write("Upper.md", in: bed.memories, memory("something-else", type: nil))
                #expect(await create("upper") == EngineError(.conflict, "A memory named upper already exists."))
            }
            let typeError = await engineError {
                try await bed.engine.dispatch(method: MemoriesCreate.name,
                                              params: Data(#"{"projectID":"MEM","name":"a","description":"d","type":"other"}"#.utf8),
                                              actor: .user(deviceID: bed.engine.deviceID))
            }
            #expect(typeError == EngineError(.invalid, "Invalid params for memories.create: type: must be one of user, feedback, project, reference."))
        }
    }

    // MARK: Update

    @Test("memories.update changes the given fields and keeps the other frontmatter keys")
    func update() async throws {
        try await withMemoriesEngine { bed in
            try write("feedback_style.md", in: bed.memories, MemoryFileTests.example)
            let updated = try await bed.connection.call(MemoriesUpdate.self, .init(projectID: "MEM", file: "feedback_style.md",
                                                                                   description: "One sentence", type: .user,
                                                                                   body: "\r\nShort.\r\n"))
            #expect(updated.description == "One sentence")
            #expect(updated.type == "user")
            #expect(updated.body == "\nShort.\n")
            #expect(try read("feedback_style.md", in: bed.memories) == """
            ---
            name: answer-style
            description: One sentence
            metadata:
              node_type: memory
              type: user
              originSessionId: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
              modified: 2026-11-07T22:39:20Z
              count: '012'
            tags:
            - a
            - b
            ---

            Short.

            """)
        }
    }

    @Test("memories.update that changes nothing writes nothing and emits nothing")
    func updateUnchanged() async throws {
        try await withMemoriesEngine { bed in
            try write("a.md", in: bed.memories, memory("a", type: "user"))
            let events = bed.connection.events
            let memory = try await bed.connection.call(MemoriesUpdate.self, .init(projectID: "MEM", file: "a.md", name: "a",
                                                                                  description: "About it", type: .user, body: "\nBody.\n"))
            #expect(memory.name == "a")
            let event = await firstElement(of: events, timeout: .milliseconds(800)) {
                $0.name == MemoriesChangedEvent.name && $0.origin == .user(deviceID: bed.engine.deviceID)
            }
            #expect(event == nil)
        }
    }

    @Test("A rename renames the file, retargets MEMORY.md and replaces [[old-name]] in the other memories")
    func rename() async throws {
        try await withMemoriesEngine { bed in
            try write("user_role.md", in: bed.memories, memory("user-role", type: "user", body: "\nSee [[style]].\n"))
            try write("style.md", in: bed.memories, memory("style", type: "feedback", body: "\nFor [[user-role]], see [[user-role]].\n"))
            try write("other.md", in: bed.memories, "Loose [[user-role]] link.\r\n")
            try write("broken.md", in: bed.memories, "---\nname: broken\n[[user-role]]\n")
            try write("MEMORY.md", in: bed.memories,
                      "- [User role](user_role.md) — who the user is\n- [Style](style.md) — answers\n")

            let renamed = try await bed.connection.call(MemoriesUpdate.self, .init(projectID: "MEM", file: "user_role.md", name: "who"))
            #expect(renamed.file == "who.md")
            #expect(renamed.name == "who")
            #expect(!FileManager.default.fileExists(atPath: bed.memories.appendingPathComponent("user_role.md").path))
            #expect(try read("who.md", in: bed.memories) == memory("who", type: "user", body: "\nSee [[style]].\n"))
            #expect(try read("MEMORY.md", in: bed.memories) == "- [User role](who.md) — who the user is\n- [Style](style.md) — answers\n")
            #expect(try read("style.md", in: bed.memories) == memory("style", type: "feedback", body: "\nFor [[who]], see [[who]].\n"))
            #expect(try read("other.md", in: bed.memories) == "Loose [[who]] link.\r\n")
            #expect(try read("broken.md", in: bed.memories) == "---\nname: broken\n[[user-role]]\n")

            // The name changes while the file already has it: only the frontmatter name changes.
            try write("exact.md", in: bed.memories, memory("not-exact", type: nil))
            let same = try await bed.connection.call(MemoriesUpdate.self, .init(projectID: "MEM", file: "exact.md", name: "exact"))
            #expect(same.file == "exact.md")
            #expect(same.name == "exact")
        }
    }

    @Test("memories.update refuses taken names, a type without metadata mapping and missing memories")
    func updateErrors() async throws {
        try await withMemoriesEngine { bed in
            try write("a.md", in: bed.memories, memory("a", type: "user"))
            try write("b.md", in: bed.memories, memory("b", type: "user"))
            try write("plain.md", in: bed.memories, "---\nname: plain\nmetadata: text\n---\n")
            func update(_ params: MemoriesUpdate.Params) async -> EngineError? {
                await engineError { try await bed.connection.call(MemoriesUpdate.self, params) }
            }
            #expect(await update(.init(projectID: "MEM", file: "a.md", name: "b")) == EngineError(.conflict, "A memory named b already exists."))
            #expect(await update(.init(projectID: "MEM", file: "plain.md", type: .user))
                == EngineError(.invalid, "type: the metadata of plain.md is not a mapping."))
            #expect(await update(.init(projectID: "MEM", file: "c.md", body: "x")) == EngineError(.notFound, "Memory c.md not found."))
            #expect(await update(.init(projectID: "MEM", file: "a.md", description: ""))
                == EngineError(.invalid, "description: use at least 1 character."))
            #expect(try read("a.md", in: bed.memories) == memory("a", type: "user"))
        }
    }

    // MARK: Delete

    @Test("memories.delete removes the MEMORY.md lines, moves the file to the Trash and keeps [[name]] links")
    func delete() async throws {
        try await withMemoriesEngine { bed in
            try write("a.md", in: bed.memories, memory("a", type: "user"))
            try write("b.md", in: bed.memories, memory("b", type: "user", body: "\nSee [[a]].\n"))
            try write("MEMORY.md", in: bed.memories, "- [A](a.md) — a\n- [B](b.md) — b\n- [A again](./a.md) — a\n")
            let events = bed.connection.events
            _ = try await bed.connection.call(MemoriesDelete.self, .init(projectID: "MEM", file: "a.md"))
            #expect(!FileManager.default.fileExists(atPath: bed.memories.appendingPathComponent("a.md").path))
            let trashed = try FileManager.default.contentsOfDirectory(atPath: bed.trash.path)
            #expect(trashed.count == 1 && trashed[0].hasSuffix("-a.md"))
            #expect(try read("MEMORY.md", in: bed.memories) == "- [B](b.md) — b\n")
            #expect(try read("b.md", in: bed.memories) == memory("b", type: "user", body: "\nSee [[a]].\n"))
            let event = try #require(await firstEvent(named: MemoriesChangedEvent.name, on: events))
            #expect(try event.payload(MemoriesChangedEvent.self).memories.map(\.file) == ["b.md"])

            #expect(await engineError { try await bed.connection.call(MemoriesDelete.self, .init(projectID: "MEM", file: "a.md")) }
                == EngineError(.notFound, "Memory a.md not found."))
            await bed.engine.useFailingTrash()
            let failure = try #require(await engineError {
                try await bed.connection.call(MemoriesDelete.self, .init(projectID: "MEM", file: "b.md"))
            })
            #expect(failure.code == .unavailable)
            #expect(FileManager.default.fileExists(atPath: bed.memories.appendingPathComponent("b.md").path))
        }
    }

    // MARK: MEMORY.md

    @Test("memories.readIndex and memories.writeIndex read and replace MEMORY.md")
    func index() async throws {
        try await withMemoriesEngine { bed in
            #expect(await engineError { try await bed.connection.call(MemoriesReadIndex.self, .init(projectID: "MEM")) }
                == EngineError(.notFound, "File MEMORY.md not found."))
            _ = try await bed.connection.call(MemoriesWriteIndex.self, .init(projectID: "MEM", text: "# Memories\r\n"))
            #expect(try await bed.connection.call(MemoriesReadIndex.self, .init(projectID: "MEM")) == MemoryIndex(text: "# Memories\r\n"))
            #expect(try await bed.connection.call(MemoriesList.self, .init(projectID: "MEM")).hasIndex)
        }
    }

    @Test("An unchanged MEMORY.md writes nothing; an unreadable one stops create before any write; a BOM survives a rename")
    func indexEdgeCases() async throws {
        try await withMemoriesEngine { bed in
            let user = Actor.user(deviceID: bed.engine.deviceID)
            let events = bed.connection.events
            _ = try await bed.connection.call(MemoriesWriteIndex.self, .init(projectID: "MEM", text: "- [a](a.md) — A\n"))
            // The first write's event, which may arrive after the call returned.
            _ = try #require(await firstElement(of: events) { $0.name == MemoriesChangedEvent.name && $0.origin == user })
            _ = try await bed.connection.call(MemoriesWriteIndex.self, .init(projectID: "MEM", text: "- [a](a.md) — A\n"))
            let event = await firstElement(of: events, timeout: .milliseconds(800)) {
                $0.name == MemoriesChangedEvent.name && $0.origin == user
            }
            #expect(event == nil)

            try Data([0x2D, 0x20, 0xE9, 0x0A]).write(to: bed.memories.appendingPathComponent("MEMORY.md"))
            let failure = try #require(await engineError {
                try await bed.connection.call(MemoriesCreate.self, .init(projectID: "MEM", name: "new", description: "D", type: .user))
            })
            #expect(failure.code == .internal)
            #expect(failure.message.hasSuffix("MEMORY.md cannot be read: it is not valid UTF-8."))
            #expect(!FileManager.default.fileExists(atPath: bed.memories.appendingPathComponent("new.md").path))

            try write("MEMORY.md", in: bed.memories, "\u{FEFF}- [Old](old.md) — o\n")
            try write("old.md", in: bed.memories, memory("old", type: "user"))
            try write("other.md", in: bed.memories, "\u{FEFF}See [[old]].\n")
            _ = try await bed.connection.call(MemoriesUpdate.self, .init(projectID: "MEM", file: "old.md", name: "new"))
            #expect(try Data(contentsOf: bed.memories.appendingPathComponent("other.md")) == Data("\u{FEFF}See [[new]].\n".utf8))
            #expect(try Data(contentsOf: bed.memories.appendingPathComponent("MEMORY.md")) == Data("\u{FEFF}- [Old](new.md) — o\n".utf8))
        }
    }

    // MARK: Actors and events

    @Test("Only the user actor calls the memories methods")
    func actors() async throws {
        try await withMemoriesEngine { bed in
            let claude = Actor.claude(chatID: "external")
            let errors = [
                await engineError { try await bed.engine.call(MemoriesList.self, .init(projectID: "MEM"), actor: claude) },
                await engineError { try await bed.engine.call(MemoriesGet.self, .init(projectID: "MEM", file: "a.md"), actor: claude) },
                await engineError {
                    try await bed.engine.call(MemoriesCreate.self, .init(projectID: "MEM", name: "a", description: "d", type: .user), actor: claude)
                },
                await engineError { try await bed.engine.call(MemoriesUpdate.self, .init(projectID: "MEM", file: "a.md"), actor: claude) },
                await engineError { try await bed.engine.call(MemoriesDelete.self, .init(projectID: "MEM", file: "a.md"), actor: claude) },
                await engineError { try await bed.engine.call(MemoriesReadIndex.self, .init(projectID: "MEM"), actor: claude) },
                await engineError { try await bed.engine.call(MemoriesWriteIndex.self, .init(projectID: "MEM", text: ""), actor: claude) },
            ]
            for error in errors {
                #expect(error?.code == .forbidden)
            }
        }
    }

    @Test("A change made outside the engine emits memories.changed with origin system for each watched project", .fsEvents)
    func watcher() async throws {
        try await withMemoriesEngine { bed in
            let events = bed.connection.events
            // A first memory, written again every 2 seconds until memories.changed reports it:
            // the stream is running, also for a folder created after it started.
            let primer = Task {
                for _ in 0..<10 {
                    try write("primer.md", in: bed.memories, memory("primer", type: "user"))
                    try await Task.sleep(for: .seconds(2))
                }
            }
            let primed = await firstElement(of: events, timeout: waitLimit) {
                $0.name == MemoriesChangedEvent.name && ((try? $0.payload(MemoriesChangedEvent.self))?.memories.count ?? 0) == 1
            }
            primer.cancel()
            _ = await primer.result
            #expect(try #require(primed).origin == .system)

            try write("chat.md", in: bed.memories, memory("from-chat", type: "project"))
            let changed = await firstElement(of: events, timeout: waitLimit) {
                $0.name == MemoriesChangedEvent.name && $0.origin == .system
                    && ((try? $0.payload(MemoriesChangedEvent.self))?.memories.map(\.name) ?? []) == ["from-chat", "primer"]
            }
            #expect(changed != nil)
        }
    }
}
