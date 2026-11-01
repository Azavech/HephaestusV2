import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › Skills and docs/skills.md › Library, Skill names, Skill files, Engine API,
/// through `LocalEngineConnection`.
@Suite("Skills library methods")
struct SkillsEngineTests {
    /// Runs `body` with a started engine whose Trash is a folder of the test, and its library.
    private func withSkillsEngine(_ body: (Engine, LocalEngineConnection, URL, URL) async throws -> Void) async throws {
        try await withTestEngine { engine, connection, folder in
            let trash = folder.appendingPathComponent("Trash", isDirectory: true)
            await engine.useTestTrash(trash)
            try await body(engine, connection, engine.dataDirectory.skillsFolder, trash)
        }
    }

    private func error<T>(_ body: () async throws -> T) async -> EngineError? {
        await engineError(body)
    }

    // MARK: Reading

    @Test("skills.list reads the library at every call, sorted by name, skipping what is not a skill")
    func list() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            #expect(try await connection.call(SkillsList.self) == [])
            try writeSkill("swift-testing", in: library, description: "Swift Testing rules.")
            try writeSkill("release-notes", in: library, SkillDocumentTests.example)
            try writeSkill("no-front", in: library, "Just a body.\n")
            try writeSkill("Release-Notes2", in: library, description: "Uppercase name.")
            try writeSkill("bad", in: library, "---\nname: bad\n")
            try writeSkill(".hidden", in: library, description: "Hidden.")
            try FileManager.default.createDirectory(at: library.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try writeFile("loose.md", in: library, "not a skill")
            try writeFile("binary/SKILL.md", in: library, "")
            try Data([0xFF, 0xFE, 0x00]).write(to: library.appendingPathComponent("binary/SKILL.md"))

            let skills = try await connection.call(SkillsList.self)
            #expect(skills == [
                SkillSummary(name: "no-front", description: ""),
                SkillSummary(name: "release-notes",
                             description: "Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog."),
                SkillSummary(name: "swift-testing", description: "Swift Testing rules."),
            ])
        }
    }

    @Test("skills.list creates a missing library folder and fails with unavailable when it cannot")
    func listFolder() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            try FileManager.default.removeItem(at: library)
            #expect(try await connection.call(SkillsList.self) == [])
            #expect(FileManager.default.fileExists(atPath: library.path))

            try FileManager.default.removeItem(at: library)
            try Data("file".utf8).write(to: library)
            #expect(await error { try await connection.call(SkillsList.self) }?.code == .unavailable)
            #expect(await error { try await connection.call(SkillsGet.self, .init(name: "a")) }?.code == .unavailable)
        }
    }

    @Test("skills.get returns the Skill of docs/skills.md with its extra files")
    func get() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            let folder = try writeSkill("release-notes", in: library, SkillDocumentTests.example)
            try writeFile("templates/changelog.md", in: folder, "# Changelog\n")
            try writeFile("scripts/.cache/x", in: folder, "hidden")
            try writeFile(".DS_Store", in: folder, "hidden")
            try writeFile("a.txt", in: folder, "a")
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.md"),
                                                       withDestinationURL: folder.appendingPathComponent("a.txt"))
            let skill = try await connection.call(SkillsGet.self, .init(name: "release-notes"))
            #expect(skill == Skill(
                name: "release-notes",
                description: "Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog.",
                body: SkillDocumentTests.exampleBody,
                extraFrontmatter: ["allowed-tools": .string("Bash(git log:*), Read")],
                files: ["a.txt", "templates/changelog.md"]
            ))
            let json = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(skill))
            #expect(json == (try jsonValue("""
            {
              "body": "\\n# Release notes\\n\\n1. Find the previous tag with `git describe --tags --abbrev=0`.\\n2. List the commit subjects since that tag with `git log <tag>..HEAD --format=%s`.\\n3. Group them by conventional commit type (feat, fix, others) and write one bullet per commit.\\n",
              "description": "Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog.",
              "extraFrontmatter": {"allowed-tools": "Bash(git log:*), Read"},
              "files": ["a.txt", "templates/changelog.md"],
              "name": "release-notes"
            }
            """)))
        }
    }

    @Test("skills.get: invalid names, unknown skills, skipped folders and exact names")
    func getErrors() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            try writeSkill("broken", in: library, "---\nname: broken\n")
            try writeSkill("Mixed", in: library, description: "Mixed case.")
            #expect(await error { try await connection.call(SkillsGet.self, .init(name: "Bad Name")) }?.code == .invalid)
            #expect(await error { try await connection.call(SkillsGet.self, .init(name: "missing")) }
                == EngineError(.notFound, "Skill missing not found."))
            #expect(await error { try await connection.call(SkillsGet.self, .init(name: "broken")) }?.code == .notFound)
            #expect(await error { try await connection.call(SkillsGet.self, .init(name: "mixed")) }?.code == .notFound)
        }
    }

    @Test("A symbolic link to a folder is a skill")
    func symbolicLinkSkill() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            try await withTemporaryDirectory { elsewhere in
                let target = try writeSkill("shared", in: elsewhere, description: "Shared.", body: "Body\n")
                try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("shared"), withDestinationURL: target)
                try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("dangling"),
                                                           withDestinationURL: elsewhere.appendingPathComponent("none"))
                #expect(try await connection.call(SkillsList.self) == [SkillSummary(name: "shared", description: "Shared.")])
                #expect(try await connection.call(SkillsGet.self, .init(name: "shared")).body == "Body\n")
            }
        }
    }

    // MARK: Create and update

    @Test("skills.create writes SKILL.md, enables nothing and emits skills.changed with the library")
    func create() async throws {
        try await withSkillsEngine { engine, connection, library, _ in
            let events = connection.events
            let skill = try await connection.call(SkillsCreate.self, .init(name: "swift-style", description: "Swift style\r\nrules."))
            #expect(skill == Skill(name: "swift-style", description: "Swift style\nrules.", body: ""))
            let text = try String(contentsOf: library.appendingPathComponent("swift-style/SKILL.md"), encoding: .utf8)
            #expect(text == "---\nname: swift-style\ndescription: |-\n  Swift style\n  rules.\n---\n")
            let event = try #require(await firstEvent(named: SkillsChangedEvent.name, on: events))
            #expect(event.origin == .user(deviceID: engine.deviceID))
            #expect(try event.payload(SkillsChangedEvent.self) == [SkillSummary(name: "swift-style", description: "Swift style\nrules.")])

            let withBody = try await connection.call(SkillsCreate.self, .init(name: "a", description: "A.", body: "# A\r\n"))
            #expect(withBody.body == "# A\n")
            #expect(try await connection.call(SkillsList.self).map(\.name) == ["a", "swift-style"])
        }
    }

    @Test("skills.create checks the name, the description and conflicts")
    func createErrors() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            func create(_ name: String, _ description: String = "D.") async -> EngineError? {
                await engineError { try await connection.call(SkillsCreate.self, .init(name: name, description: description)) }
            }
            for name in ["Release-Notes", "release_notes", "-release", "release--notes", String(repeating: "a", count: 65), ""] {
                #expect(await create(name)?.code == .invalid)
            }
            #expect(await create("ok", "") == EngineError(.invalid, "description: use 1 to 1024 characters."))
            #expect(await create("ok", String(repeating: "d", count: 1025))?.code == .invalid)
            #expect(await create(String(repeating: "a", count: 64), String(repeating: "d", count: 1024)) == nil)

            _ = try await connection.call(SkillsCreate.self, .init(name: "swift-style", description: "D."))
            #expect(await create("swift-style") == EngineError(.conflict, "A skill named swift-style already exists."))
            try FileManager.default.createDirectory(at: library.appendingPathComponent("taken"), withIntermediateDirectories: true)
            #expect(await create("taken")?.code == .conflict)
            try Data().write(to: library.appendingPathComponent("file"))
            #expect(await create("file")?.code == .conflict)
            if !SkillsLibraryReader.isCaseSensitiveVolume(library) {
                try FileManager.default.createDirectory(at: library.appendingPathComponent("Release-Notes"), withIntermediateDirectories: true)
                #expect(await create("release-notes")?.code == .conflict)
            }
        }
    }

    @Test("skills.update changes the given fields and keeps the other keys and files")
    func update() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            let folder = try writeSkill("release-notes", in: library, SkillDocumentTests.example)
            try writeFile("templates/changelog.md", in: folder, "# Changelog\n")
            let updated = try await connection.call(SkillsUpdate.self, .init(name: "release-notes", description: "New description."))
            #expect(updated.description == "New description.")
            #expect(updated.body == SkillDocumentTests.exampleBody)
            #expect(updated.extraFrontmatter == ["allowed-tools": .string("Bash(git log:*), Read")])
            #expect(updated.files == ["templates/changelog.md"])
            let text = try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)
            #expect(text == "---\nname: release-notes\ndescription: New description.\nallowed-tools: Bash(git log:*), Read\n---\n"
                + SkillDocumentTests.exampleBody)

            let body = try await connection.call(SkillsUpdate.self, .init(name: "release-notes", body: "New body\r\n"))
            #expect(body.body == "New body\n")
            #expect(body.description == "New description.")
        }
    }

    @Test("skills.update with nothing to change writes nothing and emits nothing")
    func updateUnchanged() async throws {
        try await withSkillsEngine { engine, connection, library, _ in
            let folder = try writeSkill("a", in: library, "---\nname: other\ndescription: \"D.\"\n---\nBody")
            let before = try Data(contentsOf: folder.appendingPathComponent("SKILL.md"))
            let events = connection.events
            let skill = try await connection.call(SkillsUpdate.self, .init(name: "a", newName: "a", description: "D.", body: "Body"))
            #expect(skill.description == "D.")
            #expect(try Data(contentsOf: folder.appendingPathComponent("SKILL.md")) == before)
            let event = await firstElement(of: events, timeout: .milliseconds(800)) {
                $0.name == SkillsChangedEvent.name && $0.origin == .user(deviceID: engine.deviceID)
            }
            #expect(event == nil)
        }
    }

    @Test("A rename renames the folder and the frontmatter name; a later write fixes a different name")
    func rename() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            let folder = try writeSkill("old-name", in: library, "---\nname: something-else\ndescription: D.\nmodel: haiku\n---\nBody\n")
            try writeFile("extra/file.txt", in: folder, "x")
            let events = connection.events
            let renamed = try await connection.call(SkillsUpdate.self, .init(name: "old-name", newName: "new-name"))
            #expect(renamed == Skill(name: "new-name", description: "D.", body: "Body\n", extraFrontmatter: ["model": .string("haiku")],
                                     files: ["extra/file.txt"]))
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            let text = try String(contentsOf: library.appendingPathComponent("new-name/SKILL.md"), encoding: .utf8)
            #expect(text == "---\nname: new-name\ndescription: D.\nmodel: haiku\n---\nBody\n")
            let event = try #require(await firstEvent(named: SkillsChangedEvent.name, on: events))
            #expect(try event.payload(SkillsChangedEvent.self) == [SkillSummary(name: "new-name", description: "D.")])
        }
    }

    @Test("skills.update errors: unknown skill, invalid newName or description, taken name")
    func updateErrors() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            try writeSkill("a", in: library, description: "A.")
            try writeSkill("b", in: library, description: "B.")
            func update(_ params: SkillsUpdate.Params) async -> EngineError? {
                await engineError { try await connection.call(SkillsUpdate.self, params) }
            }
            #expect(await update(.init(name: "missing", description: "D.")) == EngineError(.notFound, "Skill missing not found."))
            #expect(await update(.init(name: "a", newName: "Not Valid"))?.code == .invalid)
            #expect(await update(.init(name: "a", description: ""))?.code == .invalid)
            #expect(await update(.init(name: "a", newName: "b")) == EngineError(.conflict, "A skill named b already exists."))
            #expect(try await connection.call(SkillsList.self).map(\.name) == ["a", "b"])
        }
    }

    @Test("Renaming a skill whose library entry is a symbolic link renames the link and writes the target's SKILL.md")
    func renameLink() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            try await withTemporaryDirectory { elsewhere in
                let target = try writeSkill("shared", in: elsewhere, description: "Shared.")
                try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("shared"), withDestinationURL: target)
                _ = try await connection.call(SkillsUpdate.self, .init(name: "shared", newName: "renamed"))
                let link = library.appendingPathComponent("renamed")
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
                let text = try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8)
                #expect(text.hasPrefix("---\nname: renamed\n"))
            }
        }
    }

    // MARK: Delete

    @Test("skills.delete moves the folder to the Trash; a link goes, its target stays")
    func delete() async throws {
        try await withSkillsEngine { _, connection, library, trash in
            try writeSkill("a", in: library, description: "A.")
            let events = connection.events
            _ = try await connection.call(SkillsDelete.self, .init(name: "a"))
            #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("a").path))
            let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
            #expect(trashed.count == 1 && trashed[0].hasSuffix("-a"))
            #expect(try #require(await firstEvent(named: SkillsChangedEvent.name, on: events)).payload(SkillsChangedEvent.self) == [])

            try await withTemporaryDirectory { elsewhere in
                let target = try writeSkill("shared", in: elsewhere, description: "Shared.")
                try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("shared"), withDestinationURL: target)
                _ = try await connection.call(SkillsDelete.self, .init(name: "shared"))
                #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("SKILL.md").path))
                #expect(!SkillsLibraryReader.itemExists(library.appendingPathComponent("shared")))
            }
            #expect(await error { try await connection.call(SkillsDelete.self, .init(name: "a")) }?.code == .notFound)
        }
    }

    @Test("skills.delete fails with unavailable when the Trash cannot be used")
    func deleteUnavailable() async throws {
        try await withSkillsEngine { engine, connection, library, _ in
            let folder = try writeSkill("a", in: library, description: "A.")
            await engine.useFailingTrash()
            let failure = try #require(await error { try await connection.call(SkillsDelete.self, .init(name: "a")) })
            #expect(failure.code == .unavailable)
            #expect(failure.message.hasPrefix("\(folder.path) cannot be moved to the Trash: "))
            #expect(failure.message.hasSuffix("."))
            #expect(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    // MARK: Extra files

    @Test("skills.readFile reads any file of the skill with the content rules of files.read")
    func readFile() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            let folder = try writeSkill("a", in: library, description: "A.")
            try writeFile("templates/changelog.md", in: folder, "# Changelog\n")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: folder.appendingPathComponent("image.png"))
            try Data("nul\0inside".utf8).write(to: folder.appendingPathComponent("nul.txt"))
            func read(_ path: String) async throws -> FileContent {
                try await connection.call(SkillsReadFile.self, .init(name: "a", path: path))
            }
            let text = try await read("templates/changelog.md/")
            #expect(text.path == "templates/changelog.md")
            #expect(text.text == "# Changelog\n")
            #expect(text.dataBase64 == nil)
            #expect(text.size == 12)
            let modified = try #require(SkillsLibraryReader.modificationDate(folder.appendingPathComponent("templates/changelog.md")))
            #expect(abs(text.modified.timeIntervalSince(modified)) < 0.001)
            #expect(text.modified.timeIntervalSince1970 * 1000 == (text.modified.timeIntervalSince1970 * 1000).rounded(.down))
            let image = try await read("image.png")
            #expect(image.text == nil)
            #expect(image.dataBase64 == "iVBORwAB")
            #expect(try await read("nul.txt").dataBase64 != nil)
            #expect(try await read("SKILL.md").text == "---\nname: a\ndescription: A.\n---\n")
        }
    }

    @Test("skills.readFile errors: path rules, directories, missing files and skills")
    func readFileErrors() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            let folder = try writeSkill("a", in: library, description: "A.")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir"), withIntermediateDirectories: true)
            func read(_ name: String, _ path: String) async -> EngineError? {
                await engineError { try await connection.call(SkillsReadFile.self, .init(name: name, path: path)) }
            }
            for path in ["", "/abs", "a//b", "./a", "../a", "a/../b", "a/."] {
                #expect(await read("a", path)?.code == .invalid)
            }
            #expect(await read("a", "dir")?.code == .invalid)
            #expect(await read("a", "missing.md") == EngineError(.notFound, "File missing.md not found."))
            #expect(await read("missing", "SKILL.md") == EngineError(.notFound, "Skill missing not found."))
        }
    }

    @Test("skills.writeFile writes a text file with its folders and emits skills.changed")
    func writeFileMethod() async throws {
        try await withSkillsEngine { engine, connection, library, _ in
            let folder = try writeSkill("a", in: library, description: "A.")
            let events = connection.events
            _ = try await connection.call(SkillsWriteFile.self, .init(name: "a", path: "templates/new/changelog.md", text: "Line\r\n"))
            #expect(try Data(contentsOf: folder.appendingPathComponent("templates/new/changelog.md")) == Data("Line\r\n".utf8))
            let event = try #require(await firstEvent(named: SkillsChangedEvent.name, on: events))
            #expect(event.origin == .user(deviceID: engine.deviceID))
            _ = try await connection.call(SkillsWriteFile.self, .init(name: "a", path: "templates/new/changelog.md", text: ""))
            #expect(try Data(contentsOf: folder.appendingPathComponent("templates/new/changelog.md")) == Data())
            #expect(try await connection.call(SkillsGet.self, .init(name: "a")).files == ["templates/new/changelog.md"])
        }
    }

    @Test("skills.writeFile errors: SKILL.md, folders, path rules, size and unknown skills")
    func writeFileErrors() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            let folder = try writeSkill("a", in: library, description: "A.")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir"), withIntermediateDirectories: true)
            try writeFile("file", in: folder, "x")
            func write(_ path: String, _ text: String = "x", name: String = "a") async -> EngineError? {
                await engineError { try await connection.call(SkillsWriteFile.self, .init(name: name, path: path, text: text)) }
            }
            #expect(await write("SKILL.md") == EngineError(.invalid, "Use skills.update to change SKILL.md."))
            if !SkillsLibraryReader.isCaseSensitiveVolume(library) {
                #expect(await write("skill.md") == EngineError(.invalid, "Use skills.update to change SKILL.md."))
            }
            #expect(await write("")?.code == .invalid)
            #expect(await write("../escape")?.code == .invalid)
            #expect(await write("dir")?.code == .invalid)
            #expect(await write("x", String(repeating: "a", count: 20 * 1024 * 1024 + 1)) == EngineError(.invalid, "text: use at most 20 MiB of UTF-8."))
            #expect(await write("x", name: "missing") == EngineError(.notFound, "Skill missing not found."))
            #expect(await write("file/inside")?.code == .internal)
            #expect(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("A."))
        }
    }

    @Test("skills.deleteFile moves a file or a folder to the Trash; SKILL.md is refused")
    func deleteFileMethod() async throws {
        try await withSkillsEngine { _, connection, library, trash in
            let folder = try writeSkill("a", in: library, description: "A.")
            try writeFile("templates/one.md", in: folder, "1")
            try writeFile("two.md", in: folder, "2")
            func delete(_ path: String, name: String = "a") async -> EngineError? {
                await engineError { try await connection.call(SkillsDeleteFile.self, .init(name: name, path: path)) }
            }
            #expect(await delete("SKILL.md") == EngineError(.invalid, "Use skills.delete to delete a skill."))
            #expect(await delete("")?.code == .invalid)
            #expect(await delete("missing.md") == EngineError(.notFound, "File missing.md not found."))
            #expect(await delete("two.md", name: "missing") == EngineError(.notFound, "Skill missing not found."))
            #expect(await delete("templates") == nil)
            #expect(await delete("two.md") == nil)
            #expect(try await connection.call(SkillsGet.self, .init(name: "a")).files == [])
            #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).count == 2)
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path))
        }
    }

    // MARK: Actors and enablement

    @Test("Claude reaches list, get, create, update, delete and setEnabled, not the file methods")
    func actors() async throws {
        try await withSkillsEngine { engine, _, library, _ in
            try writeSkill("a", in: library, description: "A.")
            let claude = Actor.claude(chatID: "external")
            #expect(try await engine.call(SkillsList.self, Empty(), actor: claude).map(\.name) == ["a"])
            #expect(try await engine.call(SkillsGet.self, .init(name: "a"), actor: claude).name == "a")
            _ = try await engine.call(SkillsCreate.self, .init(name: "b", description: "B."), actor: claude)
            _ = try await engine.call(SkillsUpdate.self, .init(name: "b", body: "Body"), actor: claude)
            for error in [
                await engineError { try await engine.call(SkillsReadFile.self, .init(name: "a", path: "SKILL.md"), actor: claude) },
                await engineError { try await engine.call(SkillsWriteFile.self, .init(name: "a", path: "x", text: ""), actor: claude) },
                await engineError { try await engine.call(SkillsDeleteFile.self, .init(name: "a", path: "x"), actor: claude) },
            ] {
                #expect(error?.code == .forbidden)
            }
            _ = try await engine.call(SkillsDelete.self, .init(name: "b"), actor: claude)
            #expect(try await engine.call(SkillsList.self, Empty(), actor: claude).map(\.name) == ["a"])
        }
    }

    @Test("skills.setEnabled checks the project id, the name and the project")
    func setEnabledErrors() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            try writeSkill("a", in: library, description: "A.")
            func set(_ projectID: String, _ name: String, _ enabled: Bool) async -> EngineError? {
                await engineError { try await connection.call(SkillsSetEnabled.self, .init(projectID: projectID, name: name, enabled: enabled)) }
            }
            #expect(await set("H", "a", true)?.code == .invalid)
            #expect(await set("HEPH", "Not Valid", true)?.code == .invalid)
            #expect(await set("heph", "a", true) == EngineError(.notFound, "Project HEPH not found."))
            #expect(await set("HEPH", "a", false) == EngineError(.notFound, "Project HEPH not found."))
        }
    }

    @Test("The rename and the enable rules of a project's skills list")
    func skillLists() {
        #expect(SkillLists.enabling("c", in: ["a", "b"]) == ["a", "b", "c"])
        #expect(SkillLists.enabling("a", in: ["a", "b"]) == ["a", "b"])
        #expect(SkillLists.renaming("b", to: "x", in: ["a", "b", "c"]) == ["a", "x", "c"])
        #expect(SkillLists.renaming("z", to: "x", in: ["a", "b"]) == ["a", "b"])
        #expect(SkillLists.renaming("b", to: "c", in: ["c", "a", "b"]) == ["a", "c"])
        #expect(SkillLists.renaming("a", to: "c", in: ["a", "b", "c"]) == ["c", "b"])
    }

    // MARK: Watching and the library location

    @Test("A change made outside the engine emits skills.changed with origin system")
    func watcher() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            let events = connection.events
            // A first skill, written again every 2 seconds until skills.changed reports it: the
            // stream is running.
            let primer = Task {
                for _ in 0..<10 {
                    try writeSkill("primer", in: library, description: "Primer.")
                    try await Task.sleep(for: .seconds(2))
                }
            }
            let primed = await firstEvent(named: SkillsChangedEvent.name, on: events, timeout: .seconds(20))
            primer.cancel()
            _ = try #require(primed)
            try FileManager.default.removeItem(at: library.appendingPathComponent("primer"))
            #expect(try #require(await firstEvent(named: SkillsChangedEvent.name, on: events, timeout: .seconds(10)))
                .payload(SkillsChangedEvent.self).isEmpty)
            try writeSkill("outside", in: library, description: "Written elsewhere.")
            let event = try #require(await firstEvent(named: SkillsChangedEvent.name, on: events, timeout: .seconds(10)))
            #expect(event.origin == .system)
            #expect(try event.payload(SkillsChangedEvent.self) == [SkillSummary(name: "outside", description: "Written elsewhere.")])

            try writeFile("outside/templates/x.md", in: library, "x")
            let inside = try #require(await firstEvent(named: SkillsChangedEvent.name, on: events, timeout: .seconds(10)))
            #expect(inside.origin == .system)
        }
    }

    @Test("A new library location is used, watched, and the old one is left alone")
    func libraryLocation() async throws {
        try await withSkillsEngine { _, connection, library, _ in
            try writeSkill("old", in: library, description: "Old.")
            try await withTemporaryDirectory { other in
                let newLibrary = other.appendingPathComponent("Skills", isDirectory: true)
                _ = try await connection.call(SettingsUpdate.self, .init(skillsLibraryPath: .set(newLibrary.path)))
                #expect(try await connection.call(SkillsList.self) == [])
                _ = try await connection.call(SkillsCreate.self, .init(name: "new", description: "New."))
                #expect(FileManager.default.fileExists(atPath: newLibrary.appendingPathComponent("new/SKILL.md").path))
                #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent("old/SKILL.md").path))

                let events = connection.events
                try await Task.sleep(for: .milliseconds(500))
                try writeSkill("outside", in: newLibrary, description: "Outside.")
                let event = try #require(await firstElement(of: events, timeout: .seconds(10)) {
                    $0.name == SkillsChangedEvent.name && $0.origin == .system
                        && ((try? $0.payload(SkillsChangedEvent.self).map(\.name)) ?? []).contains("outside")
                })
                #expect(try event.payload(SkillsChangedEvent.self).map(\.name) == ["new", "outside"])

                _ = try await connection.call(SettingsUpdate.self, .init(skillsLibraryPath: .clear))
                #expect(try await connection.call(SkillsList.self).map(\.name) == ["old"])
            }
        }
    }

    @Test("A library folder set in settings.yml is created at start")
    func libraryCreatedAtStart() async throws {
        try await withTemporaryDirectory { other in
            let custom = other.appendingPathComponent("Nested/Skills", isDirectory: true)
            try await withTestEngine(prepare: { directory in
                try DeviceFileStore.write(HostSettings(skillsLibraryPath: custom.path), to: directory)
            }) { _, connection, _ in
                var isDirectory: ObjCBool = false
                #expect(FileManager.default.fileExists(atPath: custom.path, isDirectory: &isDirectory) && isDirectory.boolValue)
                #expect(try await connection.call(SnapshotGet.self).skills == [])
                try writeSkill("a", in: custom, description: "A.")
                #expect(try await connection.call(SnapshotGet.self).skills == [SkillSummary(name: "a", description: "A.")])
            }
        }
    }
}
