import Foundation
import Testing
@testable import HephaestusCore

@Suite("files.list")
struct FilesListTests {
    @Test("Lists directories first, then files, in Finder order, without .git and .DS_Store")
    func order() async throws {
        try await withFileTestEngine(files: [
            "file10.txt": "10", "file2.txt": "2", "B.txt": "b", "a.txt": "a", ".env": "x", ".DS_Store": "",
            ".git/HEAD": "ref", "src/main.go": "package main", "Docs/x.md": "# X", "assets/.keep": "",
        ]) { _, connection, _ in
            let entries = try await connection.call(FilesList.self, .init(projectID: "TEST", path: ""))
            #expect(entries.map(\.name) == [".hephaestus", "assets", "Docs", "src", ".env", "a.txt", "B.txt", "file2.txt", "file10.txt"])
            #expect(entries.map(\.path) == entries.map(\.name))
            #expect(entries.prefix(4).allSatisfy { $0.isDirectory && $0.size == 0 })
            #expect(entries.first { $0.name == "file10.txt" }?.size == 2)
            #expect(entries.allSatisfy { $0.isIgnored == nil })

            let sub = try await connection.call(FilesList.self, .init(projectID: "test", path: "src/"))
            #expect(sub.map(\.path) == ["src/main.go"])
            #expect(sub[0].size == 12)
            #expect(try await connection.call(FilesList.self, .init(projectID: "TEST", path: "assets")).map(\.path) == ["assets/.keep"])
        }
    }

    @Test("Modification dates have millisecond precision and match files.read")
    func modified() async throws {
        try await withFileTestEngine(files: ["a.txt": "a"]) { _, connection, project in
            let date = Date(timeIntervalSince1970: 1_790_000_123.456789)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: project.url("a.txt").path)
            let entry = try #require(try await connection.call(FilesList.self, .init(projectID: "TEST", path: "")).first { $0.name == "a.txt" })
            #expect(entry.modified == Date(timeIntervalSince1970: 1_790_000_123.456))
            let content = try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "a.txt"))
            #expect(content.modified == entry.modified)
        }
    }

    @Test("Symbolic links are described by their target; a broken link is a file of size 0")
    func links() async throws {
        try await withFileTestEngine(files: ["target.txt": "12345", "dir/inner.txt": "x"]) { _, connection, project in
            let manager = FileManager.default
            try manager.createSymbolicLink(atPath: project.url("file-link").path, withDestinationPath: "target.txt")
            try manager.createSymbolicLink(atPath: project.url("dir-link").path, withDestinationPath: "dir")
            try manager.createSymbolicLink(atPath: project.url("broken").path, withDestinationPath: "missing")
            let entries = try await connection.call(FilesList.self, .init(projectID: "TEST", path: ""))
            let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
            #expect(byName["file-link"]?.isDirectory == false)
            #expect(byName["file-link"]?.size == 5)
            #expect(byName["dir-link"]?.isDirectory == true)
            #expect(byName["broken"]?.isDirectory == false)
            #expect(byName["broken"]?.size == 0)
            #expect(try await connection.call(FilesList.self, .init(projectID: "TEST", path: "dir-link")).map(\.path) == ["dir-link/inner.txt"])
        }
    }

    @Test("At most 10,000 entries, the first ones in order")
    func limit() async throws {
        try await withFileTestEngine { _, connection, project in
            try project.makeDirectory("many")
            for index in 0..<10_003 {
                FileManager.default.createFile(atPath: project.url("many/f\(index)").path, contents: nil)
            }
            try project.makeDirectory("many/zz-folder")
            let entries = try await connection.call(FilesList.self, .init(projectID: "TEST", path: "many"))
            #expect(entries.count == 10_000)
            #expect(entries.first?.name == "zz-folder")
            #expect(entries[1].name == "f0")
            #expect(entries.last?.name == "f9998")
        }
    }

    @Test("Errors: invalid paths, files, missing items and unknown projects")
    func errors() async throws {
        try await withFileTestEngine(files: ["a.txt": "a"]) { _, connection, _ in
            for path in ["/a", "../x", "a//b", "./a"] {
                #expect(await engineError { try await connection.call(FilesList.self, .init(projectID: "TEST", path: path)) }?.code == .invalid)
            }
            #expect(await engineError { try await connection.call(FilesList.self, .init(projectID: "TEST", path: "a.txt")) }
                == EngineError(.invalid, "path: a.txt is not a directory."))
            #expect(await engineError { try await connection.call(FilesList.self, .init(projectID: "TEST", path: "missing")) }
                == EngineError(.notFound, "Directory missing not found."))
            #expect(await engineError { try await connection.call(FilesList.self, .init(projectID: "NOPE", path: "")) }
                == EngineError(.notFound, "Project NOPE not found."))
            #expect(await engineError { try await connection.call(FilesList.self, .init(projectID: "x1", path: "")) }?.code == .invalid)
        }
    }

    @Test("Only users call the files methods; Claude may call docs.list")
    func actors() async throws {
        try await withFileTestEngine(files: ["docs/a.md": "# A"]) { engine, _, _ in
            let claude = Actor.claude(chatID: "external")
            #expect(await engineError { try await engine.call(FilesList.self, .init(projectID: "TEST", path: ""), actor: claude) }?.code == .forbidden)
            #expect(await engineError { try await engine.call(FilesWrite.self, .init(projectID: "TEST", path: "x", text: ""), actor: claude) }?.code == .forbidden)
            #expect(await engineError { try await engine.call(FSBrowse.self, .init(path: "/"), actor: claude) }?.code == .forbidden)
            let docs = try await engine.call(DocsList.self, .init(projectID: "TEST"), actor: claude)
            #expect(docs.map(\.path) == ["docs/a.md"])
        }
    }
}

@Suite("files.read")
struct FilesReadTests {
    @Test("UTF-8 text without NUL is text; other bytes are base64")
    func content() async throws {
        try await withFileTestEngine(files: ["text.txt": "héllo\r\nworld\n"]) { _, connection, project in
            let text = try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "text.txt"))
            #expect(text.text == "héllo\r\nworld\n")
            #expect(text.dataBase64 == nil)
            #expect(text.size == 14)
            #expect(text.path == "text.txt")

            try project.write("nul.bin", Data([0x61, 0x00, 0x62]))
            let nul = try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "nul.bin"))
            #expect(nul.text == nil)
            #expect(nul.dataBase64 == "YQBi")

            try project.write("latin1.txt", Data([0x63, 0x61, 0x66, 0xE9]))
            let latin = try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "latin1.txt"))
            #expect(latin.text == nil)
            #expect(latin.dataBase64 == Data([0x63, 0x61, 0x66, 0xE9]).base64EncodedString())

            try project.write("empty.txt", Data())
            #expect(try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "empty.txt")).text == "")
        }
    }

    @Test("A file larger than 20 MiB is returned without content")
    func large() async throws {
        try await withFileTestEngine { _, connection, project in
            let url = project.url("big.bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(20 * 1024 * 1024 + 1))
            try handle.close()
            let content = try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "big.bin"))
            #expect(content.text == nil)
            #expect(content.dataBase64 == nil)
            #expect(content.size == 20 * 1024 * 1024 + 1)
        }
    }

    @Test("Errors: the root, a directory, a missing file")
    func errors() async throws {
        try await withFileTestEngine(files: ["dir/a.txt": "a"]) { _, connection, project in
            #expect(await engineError { try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "")) }?.code == .invalid)
            #expect(await engineError { try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "dir")) }
                == EngineError(.invalid, "path: dir is a directory."))
            #expect(await engineError { try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "dir/b.txt")) }
                == EngineError(.notFound, "File dir/b.txt not found."))
            try FileManager.default.createSymbolicLink(atPath: project.url("broken").path, withDestinationPath: "missing")
            #expect(await engineError { try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "broken")) }?.code == .notFound)
        }
    }
}

@Suite("files.write")
struct FilesWriteTests {
    @Test("Creates or overwrites a file and returns what was written")
    func write() async throws {
        try await withFileTestEngine(files: ["dir/old.txt": "old"]) { _, connection, project in
            let created = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "dir/new.txt", text: "a\r\nb"))
            #expect(created.path == "dir/new.txt")
            #expect(created.text == "a\r\nb")
            #expect(created.size == 4)
            #expect(try project.text("dir/new.txt") == "a\r\nb")
            let read = try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "dir/new.txt"))
            #expect(read.modified == created.modified)

            _ = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "dir/old.txt", text: "new"))
            #expect(try project.text("dir/old.txt") == "new")
        }
    }

    @Test("expectedModified must equal the file's modification date")
    func expectedModified() async throws {
        try await withFileTestEngine(files: ["a.txt": "1"]) { _, connection, project in
            let read = try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "a.txt"))
            let first = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "a.txt", text: "2",
                                                                         expectedModified: read.modified))
            #expect(try project.text("a.txt") == "2")

            try FileManager.default.setAttributes([.modificationDate: first.modified.addingTimeInterval(-60)],
                                                  ofItemAtPath: project.url("a.txt").path)
            #expect(await engineError {
                try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "a.txt", text: "3", expectedModified: first.modified))
            } == EngineError(.conflict, "a.txt changed on disk."))
            #expect(try project.text("a.txt") == "2")

            #expect(await engineError {
                try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "gone.txt", text: "3", expectedModified: first.modified))
            } == EngineError(.conflict, "gone.txt changed on disk."))
            #expect(!project.exists("gone.txt"))
        }
    }

    @Test("A symbolic link is written at its target and stays a link")
    func link() async throws {
        try await withFileTestEngine(files: ["target.txt": "old"]) { _, connection, project in
            try FileManager.default.createSymbolicLink(atPath: project.url("link.txt").path, withDestinationPath: "target.txt")
            _ = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "link.txt", text: "new"))
            #expect(try project.text("target.txt") == "new")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: project.url("link.txt").path) == "target.txt")
        }
    }

    @Test("Errors: chats, directories, missing parents, size")
    func errors() async throws {
        try await withFileTestEngine(files: ["dir/a.txt": "a"]) { _, connection, _ in
            let chats = EngineError(.forbidden, "Chat files are written only by HephaestusV2.")
            #expect(await engineError { try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: ".hephaestus/chats/x.yml", text: "")) } == chats)
            #expect(await engineError { try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: ".hephaestus/chats", text: "")) } == chats)
            #expect(await engineError { try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "dir", text: "")) }
                == EngineError(.invalid, "path: dir is a directory."))
            #expect(await engineError { try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "nope/a.txt", text: "")) }
                == EngineError(.notFound, "Directory nope not found."))
            #expect(await engineError { try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "dir/a.txt/b", text: "")) }?.code == .notFound)
            #expect(await engineError { try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "", text: "")) }?.code == .invalid)
            let big = String(repeating: "a", count: 20 * 1024 * 1024 + 1)
            #expect(await engineError { try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "big.txt", text: big)) }?.code == .invalid)
            #expect(await engineError { try await connection.call(FilesWrite.self, .init(projectID: "NOPE", path: "a.txt", text: "")) }?.code == .notFound)
        }
    }

    @Test("project.yml can be written; the write is not recorded as the engine's own")
    func dataFiles() async throws {
        try await withFileTestEngine { engine, connection, project in
            let text = try project.text(".hephaestus/project.yml").replacingOccurrences(of: "name: Test", with: "name: Renamed")
            _ = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: ".hephaestus/project.yml", text: text))
            let data = try Data(contentsOf: project.url(".hephaestus/project.yml"))
            #expect(await !engine.ownWrites.isOwnWrite(path: project.url(".hephaestus/project.yml").path, data: data))
        }
    }
}

@Suite("files.create")
struct FilesCreateTests {
    @Test("Creates an empty file or a directory with the missing folders")
    func create() async throws {
        try await withFileTestEngine { _, connection, project in
            let file = try await connection.call(FilesCreate.self, .init(projectID: "TEST", path: "a/b/c.txt", isDirectory: false))
            #expect(file == FileEntry(name: "c.txt", path: "a/b/c.txt", isDirectory: false, size: 0, modified: file.modified))
            #expect(try project.text("a/b/c.txt") == "")
            let folder = try await connection.call(FilesCreate.self, .init(projectID: "TEST", path: "x/y/", isDirectory: true))
            #expect(folder.path == "x/y")
            #expect(folder.isDirectory)
            #expect(FileItem.at(project.url("x/y").path)?.isDirectory == true)
        }
    }

    @Test("Errors: existing items, chats, the root")
    func errors() async throws {
        try await withFileTestEngine(files: ["a.txt": "a"]) { _, connection, project in
            #expect(await engineError { try await connection.call(FilesCreate.self, .init(projectID: "TEST", path: "a.txt", isDirectory: true)) }
                == EngineError(.conflict, "a.txt already exists."))
            try FileManager.default.createSymbolicLink(atPath: project.url("broken").path, withDestinationPath: "missing")
            #expect(await engineError { try await connection.call(FilesCreate.self, .init(projectID: "TEST", path: "broken", isDirectory: false)) }?.code == .conflict)
            #expect(await engineError { try await connection.call(FilesCreate.self, .init(projectID: "TEST", path: ".hephaestus/chats/n", isDirectory: true)) }
                == EngineError(.forbidden, "Chat files are written only by HephaestusV2."))
            #expect(await engineError { try await connection.call(FilesCreate.self, .init(projectID: "TEST", path: "", isDirectory: true)) }?.code == .invalid)
            #expect(await engineError { try await connection.call(FilesCreate.self, .init(projectID: "TEST", path: "a.txt/b", isDirectory: false)) }?.code == .internal)
        }
    }
}

@Suite("files.rename")
struct FilesRenameTests {
    @Test("Renames and moves items, creating missing folders")
    func rename() async throws {
        try await withFileTestEngine(files: ["a.txt": "a", "dir/b.txt": "b"]) { _, connection, project in
            let renamed = try await connection.call(FilesRename.self, .init(projectID: "TEST", path: "a.txt", newPath: "new/deep/a2.txt"))
            #expect(renamed.path == "new/deep/a2.txt")
            #expect(renamed.name == "a2.txt")
            #expect(try project.text("new/deep/a2.txt") == "a")
            #expect(!project.exists("a.txt"))
            let folder = try await connection.call(FilesRename.self, .init(projectID: "TEST", path: "dir", newPath: "folder"))
            #expect(folder.isDirectory)
            #expect(try project.text("folder/b.txt") == "b")
        }
    }

    @Test("A rename that only changes the letter case works")
    func letterCase() async throws {
        try await withFileTestEngine(files: ["readme.md": "r"]) { _, connection, project in
            let renamed = try await connection.call(FilesRename.self, .init(projectID: "TEST", path: "readme.md", newPath: "README.md"))
            #expect(renamed.path == "README.md")
            #expect(try FileManager.default.contentsOfDirectory(atPath: project.root.path).contains("README.md"))
        }
    }

    @Test("Errors: clashes, moves into itself, protected items, missing items")
    func errors() async throws {
        try await withFileTestEngine(subproject: true, files: ["a.txt": "a", "b.txt": "b", "dir/c.txt": "c"]) { _, connection, project in
            func rename(_ path: String, _ newPath: String) async -> EngineError? {
                await engineError { try await connection.call(FilesRename.self, .init(projectID: "TEST", path: path, newPath: newPath)) }
            }
            #expect(await rename("a.txt", "b.txt") == EngineError(.conflict, "b.txt already exists."))
            #expect(await rename("a.txt", "a.txt") == EngineError(.conflict, "a.txt already exists."))
            let unchanged = try project.text("b.txt")
            #expect(unchanged == "b")
            #expect(await rename("dir", "dir/inner") == EngineError(.invalid, "newPath: dir/inner is inside dir."))
            let dataFolder = EngineError(.forbidden, "The project's data folder and project.yml cannot be moved.")
            #expect(await rename(".hephaestus", "data") == dataFolder)
            #expect(await rename(".hephaestus/project.yml", "p.yml") == dataFolder)
            #expect(await rename("Sub/.hephaestus", "Sub/data") == dataFolder)
            #expect(await rename("Sub/.hephaestus/project.yml", "Sub/p.yml") == dataFolder)
            let chats = EngineError(.forbidden, "Chat files are written only by HephaestusV2.")
            #expect(await rename(".hephaestus/chats", "c") == chats)
            #expect(await rename("a.txt", ".hephaestus/chats/a.txt") == chats)
            #expect(await rename("Sub/.hephaestus/chats/x", "x") == chats)
            #expect(await rename("missing", "other") == EngineError(.notFound, "File missing not found."))
            #expect(await rename("", "other")?.code == .invalid)
            #expect(await rename("a.txt", "")?.code == .invalid)
            #expect(await rename("a.txt", "../a.txt")?.code == .invalid)
            #expect(project.exists("a.txt"))
        }
    }
}

@Suite("files.trash")
struct FilesTrashTests {
    @Test("Moves files and folders to the Trash")
    func trash() async throws {
        try await withFileTestEngine(files: ["a.txt": "a", "dir/b.txt": "b"]) { _, connection, project in
            _ = try await connection.call(FilesTrash.self, .init(projectID: "TEST", path: "a.txt"))
            _ = try await connection.call(FilesTrash.self, .init(projectID: "TEST", path: "dir/"))
            #expect(!project.exists("a.txt"))
            #expect(!project.exists("dir"))
            #expect(try project.trashedNames() == ["a.txt", "dir"])
        }
    }

    @Test("Errors: protected items, missing items, an unusable Trash")
    func errors() async throws {
        try await withFileTestEngine(files: ["a.txt": "a"]) { engine, connection, project in
            func trash(_ path: String) async -> EngineError? {
                await engineError { try await connection.call(FilesTrash.self, .init(projectID: "TEST", path: path)) }
            }
            let dataFolder = EngineError(.forbidden, "The project's data folder and project.yml cannot be moved.")
            #expect(await trash(".hephaestus") == dataFolder)
            #expect(await trash(".hephaestus/project.yml") == dataFolder)
            #expect(await trash(".hephaestus/chats/x.yml") == EngineError(.forbidden, "Chat files are written only by HephaestusV2."))
            #expect(await trash("")?.code == .invalid)
            #expect(await trash("missing") == EngineError(.notFound, "File missing not found."))

            struct NoTrash: LocalizedError {
                var errorDescription: String? { "The volume has no Trash." }
            }
            await engine.useFileTrash(FileTrash { _ in throw NoTrash() })
            #expect(await trash("a.txt") == EngineError(.unavailable, "a.txt cannot be moved to the Trash: The volume has no Trash."))
            #expect(project.exists("a.txt"))
        }
    }
}
