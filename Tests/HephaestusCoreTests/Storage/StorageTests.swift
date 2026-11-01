import Darwin
import Foundation
import Testing
@testable import HephaestusCore

@Suite("Atomic writes")
struct AtomicFileTests {
    @Test("A write creates parent folders and the file with mode 0644, and returns its SHA-256")
    func newFile() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("a/b/file.yml")
            let digest = try AtomicFile.write(Data("hello\n".utf8), to: url)
            #expect(try String(contentsOf: url, encoding: .utf8) == "hello\n")
            #expect(digest == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
            #expect(mode(of: url) == 0o644)
            #expect(mode(of: url.deletingLastPathComponent()) == 0o755)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["file.yml"])
        }
    }

    @Test("A write keeps the mode of the file it replaces; secrets get 0600")
    func modes() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("file")
            try AtomicFile.write(Data("1".utf8), to: url)
            chmod(url.path, 0o640)
            try AtomicFile.write(Data("2".utf8), to: url)
            #expect(mode(of: url) == 0o640)
            let secret = folder.appendingPathComponent("secrets.json")
            try AtomicFile.write(Data("{}".utf8), to: secret, newFileMode: AtomicFile.privateMode)
            #expect(mode(of: secret) == 0o600)
        }
    }

    @Test("A symbolic link destination is written at its target and stays a link")
    func symbolicLink() throws {
        try withTemporaryDirectory { folder in
            let target = folder.appendingPathComponent("target.yml")
            try AtomicFile.write(Data("old".utf8), to: target)
            let link = folder.appendingPathComponent("link.yml")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.yml")
            try AtomicFile.write(Data("new".utf8), to: link)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target.yml")
            #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        }
    }

    @Test("A failed write leaves no temporary file and names the path")
    func failure() throws {
        try withTemporaryDirectory { folder in
            let blocker = folder.appendingPathComponent("blocker")
            try Data().write(to: blocker)
            let url = blocker.appendingPathComponent("file.yml")
            #expect(throws: StorageError.self) { try AtomicFile.write(Data("x".utf8), to: url) }
            let readOnly = folder.appendingPathComponent("readonly", isDirectory: true)
            try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
            chmod(readOnly.path, 0o555)
            defer { chmod(readOnly.path, 0o755) }
            do {
                try AtomicFile.write(Data("x".utf8), to: readOnly.appendingPathComponent("f"))
                Issue.record("the write should fail")
            } catch let error as StorageError {
                guard case .writeFailed(let path, _) = error else { Issue.record("unexpected \(error)"); return }
                #expect(path.hasSuffix("readonly/f"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: readOnly.path).isEmpty)
        }
    }

    @Test("Leftover temporary files are recognized and deleted")
    func leftovers() throws {
        try withTemporaryDirectory { folder in
            let leftover = ".HEPH-1.yml.\(UUID().uuidString).tmp"
            for name in [leftover, "HEPH-1.yml", ".DS_Store", ".x.tmp"] {
                try Data().write(to: folder.appendingPathComponent(name))
            }
            #expect(AtomicFile.removeLeftoverTemporaryFiles(in: folder) == [leftover])
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [".DS_Store", ".x.tmp", "HEPH-1.yml"])
        }
    }

    @Test("Own writes are recognized by their SHA-256")
    func ownWrites() throws {
        let writes = OwnWrites()
        writes.recordWrite(path: "/p", sha256: AtomicFile.sha256(Data("a".utf8)))
        #expect(writes.isOwnWrite(path: "/p", data: Data("a".utf8)))
        #expect(!writes.isOwnWrite(path: "/p", data: Data("b".utf8)))
        writes.recordRemoval(path: "/p")
        #expect(writes.isOwnRemoval(path: "/p"))
        #expect(!writes.isOwnWrite(path: "/p", data: Data("a".utf8)))
    }

    private func mode(of url: URL) -> mode_t {
        var status = stat()
        stat(url.path, &status)
        return status.st_mode & 0o7777
    }
}

@Suite("JSON Lines and transcript replay")
struct TranscriptTests {
    static let created = ISODate.date(from: "2026-10-31T13:00:00Z")!

    @Test("Appends are one compact line each, and a cut line stays separate")
    func appends() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301.jsonl")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"op\":\"add\",\"item\":{\"ty".utf8).write(to: url)
            let writer = JSONLinesWriter()
            let item = ChatItem.system(SystemItem(id: "s1", created: Self.created, text: "line\nbreak"))
            try writer.append(TranscriptLine(op: .add, item: item), to: url)
            try writer.append(TranscriptLine(op: .update, item: item), to: url)
            let lines = JSONLines.lines(of: try Data(contentsOf: url))
            #expect(lines.count == 3)
            let replay = TranscriptReplay.replay(try Data(contentsOf: url))
            #expect(replay.items == [item])
            #expect(replay.skipped.map(\.line) == [1])
            #expect(throws: StorageError.self) { try writer.append(Data("a\nb".utf8), to: url) }
        }
    }

    @Test("Replay: add appends or replaces, update replaces or appends, bad lines are skipped")
    func replayRules() throws {
        func line(_ op: String, _ id: String, _ text: String) -> String {
            "{\"op\":\"\(op)\",\"item\":{\"type\":\"system\",\"id\":\"\(id)\",\"created\":\"2026-10-31T13:00:00Z\",\"text\":\"\(text)\",\"extra\":1}}"
        }
        let text = [
            line("add", "a", "1"),
            line("update", "b", "2"),
            line("add", "a", "3"),
            "not json",
            "{\"op\":\"remove\",\"item\":{}}",
            "{\"op\":\"add\",\"item\":{\"type\":\"unknown\",\"id\":\"c\",\"created\":\"2026-10-31T13:00:00Z\"}}",
            "{\"op\":\"add\",\"item\":{\"type\":\"system\",\"id\":\"d\",\"created\":\"2026-10-31T13:00:00Z\"}}",
            line("update", "b", "4"),
        ].joined(separator: "\r\n") + "\n"
        let replay = TranscriptReplay.replay(Data(text.utf8))
        #expect(replay.items.map(\.id) == ["a", "b"])
        if case .system(let first) = replay.items[0] { #expect(first.text == "3") }
        if case .system(let second) = replay.items[1] { #expect(second.text == "4") }
        #expect(replay.skipped.map(\.line) == [4, 5, 6, 7])
    }
}

@Suite("Data directory")
struct DataDirectoryTests {
    @Test("Paths of docs/architecture.md › Device data directory")
    func paths() {
        let directory = DataDirectory(url: URL(fileURLWithPath: "/Users/example/Library/Application Support/HephaestusV2"))
        let chat = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        let root = directory.url.path
        #expect(DataDirectory.defaultURL(homeDirectory: "/Users/example").path == root)
        #expect(directory.deviceFile.path == root + "/device.yml")
        #expect(directory.registryFile.path == root + "/registry.yml")
        #expect(directory.settingsFile.path == root + "/settings.yml")
        #expect(directory.secretsFile.path == root + "/secrets.json")
        #expect(directory.remotesFile.path == root + "/remotes.yml")
        #expect(directory.invalidCopy(of: directory.settingsFile).path == root + "/settings.yml.invalid")
        #expect(directory.pluginFolder(projectID: "HEPH").path == root + "/Runtime/plugins/HEPH")
        #expect(directory.claudeWorkingDirectory.path == root + "/Runtime/claude-cwd")
        #expect(directory.mcpConfigFile(chatID: chat).path == root + "/Runtime/mcp/3F2504E0-4F89-11D3-9A0C-0305E82C3301.json")
        #expect(directory.screenshotsFolder.path == root + "/Runtime/screenshots")
        #expect(directory.engineLogFile.path == root + "/Logs/engine.log")
        #expect(directory.claudeLogFile(chatID: chat).path == root + "/Logs/claude-3F2504E0-4F89-11D3-9A0C-0305E82C3301.log")
        #expect(directory.claudeStdoutCaptureFile(chatID: chat).path
            == root + "/Logs/claude-3F2504E0-4F89-11D3-9A0C-0305E82C3301.stdout.jsonl")
    }

    @Test("The directory is created with mode 0700, and the lock is exclusive")
    func lock() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder.appendingPathComponent("nested/data"))
            try directory.createIfNeeded()
            var status = stat()
            stat(directory.url.path, &status)
            #expect(status.st_mode & 0o777 == 0o700)
            #expect(FileManager.default.fileExists(atPath: directory.logsFolder.path))
            let first = try DataDirectoryLock.acquire(directory)
            #expect(throws: StorageError.dataDirectoryInUse(path: directory.url.path)) { try DataDirectoryLock.acquire(directory) }
            #expect(StorageError.dataDirectoryInUse(path: "/x").description
                == "HephaestusV2: data directory /x is in use by another HephaestusV2 process")
            first.release()
            let second = try DataDirectoryLock.acquire(directory)
            second.release()
        }
    }
}

@Suite("Device files")
struct DeviceFileStoreTests {
    @Test("A first launch creates every device file with its defaults")
    func firstLaunch() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            let log = MemoryLog()
            let files = try DeviceFileStore.loadAll(directory, log: log)
            #expect(files.settings == HostSettings())
            #expect(files.registry == Registry())
            #expect(files.remotes == RemotesFile())
            #expect(files.device.name == nil)
            #expect(Identifiers.isPairingCode(files.secrets.pairingCode))
            #expect(Identifiers.isExternalToken(files.secrets.mcpExternalToken))
            var status = stat()
            stat(directory.secretsFile.path, &status)
            #expect(status.st_mode & 0o777 == 0o600)
            let again = try DeviceFileStore.loadAll(directory, log: log)
            #expect(again == files)
            #expect(!log.entries.contains { $0.message.contains(files.secrets.pairingCode) })
        }
    }

    @Test("An invalid device file is set aside as <file>.invalid and recreated")
    func invalidFile() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            try Data("schema: 2\n".utf8).write(to: directory.settingsFile)
            try Data("old".utf8).write(to: directory.invalidCopy(of: directory.settingsFile))
            try Data("{\"schema\":1,\"pairingCode\":\"bad\"}".utf8).write(to: directory.secretsFile)
            let log = MemoryLog()
            let files = try DeviceFileStore.loadAll(directory, log: log)
            #expect(files.settings == HostSettings())
            #expect(try String(contentsOf: directory.invalidCopy(of: directory.settingsFile), encoding: .utf8) == "schema: 2\n")
            #expect(FileManager.default.fileExists(atPath: directory.invalidCopy(of: directory.secretsFile).path))
            let errors = log.entries.filter { $0.level == .error }
            #expect(errors.count == 2)
            #expect(errors.contains { $0.message.contains("newer version") })
            #expect(!errors.contains { $0.message.contains("bad") })
        }
    }

    @Test("Missing secrets are generated, the file mode is fixed and other keys are kept")
    func secretsCompletion() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            let remote = "0E3C2A55-8B1D-4F4C-9E43-2D6A9C1B7F10"
            try Data("{\"schema\":1,\"remoteSecrets\":{\"\(remote)\":\"M8ZQ-4RTV-K2PX-9HDC\"},\"future\":true}".utf8)
                .write(to: directory.secretsFile)
            chmod(directory.secretsFile.path, 0o644)
            let secrets = try DeviceFileStore.loadSecrets(directory, log: nil)
            #expect(Identifiers.isPairingCode(secrets.pairingCode))
            #expect(secrets.remoteSecrets == [remote: "M8ZQ-4RTV-K2PX-9HDC"])
            #expect(secrets.unknownKeys == ["future": true])
            let reread = try DeviceFileStore.loadSecrets(directory, log: nil)
            #expect(reread == secrets)
            var status = stat()
            stat(directory.secretsFile.path, &status)
            #expect(status.st_mode & 0o777 == 0o600)
        }
    }

    @Test("A duplicate key makes secrets.json invalid")
    func duplicateJSONKey() {
        #expect(JSONDuplicateKeys.firstDuplicate(in: Data("{\"a\":1,\"b\":{\"a\":2},\"a\":3}".utf8)) == "a")
        #expect(JSONDuplicateKeys.firstDuplicate(in: Data("{\"a\":1,\"b\":{\"a\":2},\"c\":[{\"a\":1},{\"a\":2}]}".utf8)) == nil)
        #expect(JSONDuplicateKeys.firstDuplicate(in: Data("{\"a\":\"x\\\"y\",\"\\u0061\":1}".utf8)) == "a")
        #expect(throws: FormatError.self) { try StorageJSON.decodeObject(Secrets.self, from: Data("{\"schema\":1,\"schema\":1}".utf8)) }
        #expect(throws: FormatError.self) { try StorageJSON.decodeObject(Secrets.self, from: Data("[]".utf8)) }
    }

    @Test("Registry entries that are not absolute paths are skipped and logged")
    func registryEntries() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            try Data("schema: 1\nprojects:\n  - /Users/example/A\n  - relative\n".utf8).write(to: directory.registryFile)
            let log = MemoryLog()
            let files = try DeviceFileStore.loadAll(directory, log: log)
            #expect(files.registry.loadableEntries == ["/Users/example/A"])
            #expect(log.entries.contains { $0.level == .warn && $0.message.contains("relative") })
        }
    }
}

@Suite("Project files")
struct ProjectFileStoreTests {
    static let created = ISODate.date(from: "2026-10-31T12:00:00Z")!

    @Test("Project, ticket, bundle and chat files round-trip through their folders")
    func roundTrip() throws {
        try withTemporaryDirectory { root in
            let folder = ProjectFolder(root: root)
            #expect(!folder.isProject)
            let project = Project(id: "HEPH", name: "Hephaestus V2", created: Self.created)
            try ProjectFileStore.write(project, to: folder)
            #expect(folder.isProject)
            #expect(try ProjectFileStore.readProject(folder) == project)

            let ticket = Ticket(id: "HEPH-1", title: "T", created: Self.created, description: "Problem\n")
            let bundle = TicketBundle(id: "HEPH-B1", title: "B", created: Self.created, ticketIDs: ["HEPH-1"])
            var meta = ChatMeta(id: UUID(), kind: .ticket, ticketID: "HEPH-1", created: Self.created)
            try ProjectFileStore.write(ticket, to: folder)
            try ProjectFileStore.write(bundle, to: folder)
            try ProjectFileStore.write(meta, to: folder)
            try Data().write(to: folder.ticketFolder.appendingPathComponent(".DS_Store"))
            try Data("junk".utf8).write(to: folder.ticketFolder.appendingPathComponent("HEPH-1.yml.orig"))
            try Data("id: HEPH-3\ntitle: T\ncreated: 2026-10-31T12:00:00Z\n".utf8).write(to: folder.ticketFile("HEPH-2"))
            try Data("id: WEB-4\ntitle: T\ncreated: 2026-10-31T12:00:00Z\n".utf8).write(to: folder.ticketFile("WEB-4"))
            let leftover = folder.ticketFolder.appendingPathComponent(".HEPH-1.yml.\(UUID().uuidString).tmp")
            try Data().write(to: leftover)

            let log = MemoryLog()
            let contents = ProjectFileStore.loadContents(of: folder, projectID: "HEPH", log: log)
            meta.projectID = "HEPH"
            #expect(contents.tickets == [ticket])
            #expect(contents.bundles == [bundle])
            #expect(contents.chats == [meta])
            #expect(contents.invalidFiles.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted() == ["HEPH-2.yml", "WEB-4.yml"])
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
            #expect(log.entries.filter { $0.level == .warn }.count == 2)
        }
    }

    @Test("Id allocation skips numbers whose file exists")
    func idAllocation() throws {
        try withTemporaryDirectory { root in
            let folder = ProjectFolder(root: root)
            var project = Project(id: "HEPH", name: "H", created: Self.created, nextTicketNumber: 0)
            try FileManager.default.createDirectory(at: folder.ticketFolder, withIntermediateDirectories: true)
            try Data("broken".utf8).write(to: folder.ticketFile("HEPH-1"))
            try Data().write(to: folder.ticketFile("HEPH-2"))
            #expect(ProjectFileStore.freeTicketNumber(for: project, in: folder) == 3)
            project.nextTicketNumber = 7
            #expect(ProjectFileStore.freeTicketNumber(for: project, in: folder) == 7)
            #expect(ProjectFileStore.freeBundleNumber(for: project, in: folder) == 1)
        }
    }

    @Test(".hephaestus/.gitignore holds the line chats/")
    func gitignore() throws {
        try withTemporaryDirectory { root in
            let folder = ProjectFolder(root: root)
            try folder.ensureGitignore()
            #expect(try String(contentsOf: folder.gitignoreFile, encoding: .utf8) == "chats/\n")
            #expect(try folder.ensureGitignore() == nil)
            try Data("attachments/".utf8).write(to: folder.gitignoreFile)
            try folder.ensureGitignore()
            #expect(try String(contentsOf: folder.gitignoreFile, encoding: .utf8) == "attachments/\nchats/\n")
        }
    }

    @Test("Loaded file names match their patterns case-sensitively")
    func fileNames() {
        #expect(ProjectFolder.ticketID(fromFileName: "HEPH-12.yml") == "HEPH-12")
        #expect(ProjectFolder.ticketID(fromFileName: "heph-12.yml") == nil)
        #expect(ProjectFolder.ticketID(fromFileName: "HEPH-12.yml.orig") == nil)
        #expect(ProjectFolder.bundleID(fromFileName: "HEPH-B2.yml") == "HEPH-B2")
        #expect(ProjectFolder.chatID(fromMetaFileName: "3F2504E0-4F89-11D3-9A0C-0305E82C3301.yml") != nil)
        #expect(ProjectFolder.chatID(fromMetaFileName: "3f2504e0-4f89-11d3-9a0c-0305e82c3301.yml") == nil)
        #expect(ProjectFolder.chatID(fromMetaFileName: "3F2504E0-4F89-11D3-9A0C-0305E82C3301.jsonl") == nil)
    }
}
