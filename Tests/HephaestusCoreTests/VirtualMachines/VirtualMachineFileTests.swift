import Foundation
import Testing
@testable import HephaestusCore

/// docs/data-model.md › VM metadata file, docs/virtual-machines.md › Storage, › Clone and
/// › Virtual machine states.
@Suite("VM metadata files")
struct VirtualMachineFileTests {
    static let id = UUID(uuidString: "7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C")!
    static let imageID = UUID(uuidString: "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F")!
    static let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    static func machine(_ id: UUID = VirtualMachineFileTests.id, startedBy: VMStarter = .user,
                        created: String = "2026-11-10T09:12:00Z") -> VirtualMachine {
        VirtualMachine(id: id, name: "Menu checks", imageID: imageID, version: "27.2.1", build: "26B131", cores: 4, memoryGB: 8,
                       startedBy: startedBy, created: ISODate.date(from: created)!)
    }

    @Test("A virtual machine is written with its keys in the order of the field table, without the keys that are never stored")
    func write() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            var machine = Self.machine()
            machine.state = .running
            machine.startedAt = ISODate.date(from: "2026-11-10T09:12:03Z")
            try VirtualMachineStore.write(machine, to: directory)
            let file = folder.appendingPathComponent("VirtualMachines/Machines/\(Self.id.uuidString)/vm.yml")
            #expect(try String(contentsOf: file, encoding: .utf8) == """
                schema: 1
                id: 7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C
                name: Menu checks
                imageID: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
                version: 27.2.1
                build: 26B131
                cores: 4
                memoryGB: 8
                diskGB: null
                growContainer: false
                startedBy: user
                projectID: null
                chatID: null
                created: 2026-11-10T09:12:00Z

                """)
            #expect(VirtualMachineStore.metadataFile(of: Self.id, in: directory).path == file.path)
            // A virtual machine read from its file is stopped.
            #expect(VirtualMachineStore.loadAll(directory, log: nil) == [Self.machine()])
        }
    }

    @Test("A virtual machine that Claude started keeps its project and its chat, and the unknown keys survive a rewrite")
    func claudeRoundTrip() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            let file = VirtualMachineStore.metadataFile(of: Self.id, in: directory)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("""
                id: 7d2c1a90-5e4b-4f3a-8b6c-1d0e9f8a7b6c
                name: Settings check
                imageID: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
                version: '26.6'
                build: 25G72
                cores: 2
                memoryGB: 4
                startedBy: claude
                projectID: DEMO
                chatID: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
                created: 2026-11-10T10:40:00Z
                note: kept
                state: running
                startedAt: 2026-11-10T10:40:02Z
                """.utf8).write(to: file)
            let machine = try #require(VirtualMachineStore.loadAll(directory, log: nil).first)
            #expect(machine.id == Self.id)
            #expect(machine.version == "26.6")
            #expect(machine.startedBy == .claude(projectID: "DEMO", chatID: Self.chatID))
            #expect(machine.isDeletedWhenStopped)
            // The keys that are never stored are ignored in a file.
            #expect(machine.state == .stopped)
            #expect(machine.startedAt == nil)
            #expect(machine.unknownKeys == ["note": "kept"])
            try VirtualMachineStore.write(machine, to: directory)
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("startedBy: claude\nprojectID: DEMO\nchatID: 3F2504E0-4F89-11D3-9A0C-0305E82C3301\n"))
            #expect(text.hasSuffix("created: 2026-11-10T10:40:00Z\nnote: kept\n"))
            #expect(!text.contains("state") && !text.contains("startedAt"))
            #expect(VirtualMachineStore.loadAll(directory, log: nil) == [machine])
        }
    }

    @Test("A file without the chat of a virtual machine that Claude started, or with another starter, is invalid")
    func invalidStarters() throws {
        func decode(_ starter: String) throws -> VirtualMachine {
            try YAMLCoding.decode(VirtualMachine.self, from: """
                id: 7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C
                name: Menu checks
                imageID: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
                version: 27.2.1
                build: 26B131
                cores: 4
                memoryGB: 8
                \(starter)
                created: 2026-11-10T09:12:00Z

                """)
        }
        #expect(try decode("startedBy: user").startedBy == .user)
        // The project and the chat of a user's virtual machine are not read.
        #expect(try decode("startedBy: user\nprojectID: DEMO").startedBy == .user)
        #expect(throws: (any Error).self) { try decode("startedBy: claude") }
        #expect(throws: (any Error).self) { try decode("startedBy: claude\nprojectID: DEMO") }
        #expect(throws: (any Error).self) { try decode("startedBy: somebody") }
        #expect(throws: (any Error).self) { try decode("projectID: DEMO") }
    }

    @Test("The engine API adds state and startedAt")
    func apiKeys() throws {
        var machine = Self.machine()
        let stopped = try EngineJSON.decode([String: JSONValue].self, from: EngineJSON.encode(machine))
        #expect(stopped["state"] == "stopped")
        #expect(stopped["startedAt"] == nil)
        #expect(stopped["startedBy"] == "user")
        #expect(stopped["projectID"] == .null && stopped["chatID"] == .null)

        machine.state = .running
        machine.startedAt = ISODate.date(from: "2026-11-10T09:12:03Z")
        machine.startedBy = .claude(projectID: "DEMO", chatID: Self.chatID)
        let data = try EngineJSON.encode(machine)
        let running = try EngineJSON.decode([String: JSONValue].self, from: data)
        #expect(running["state"] == "running")
        #expect(running["startedAt"] == "2026-11-10T09:12:03Z")
        #expect(running["startedBy"] == "claude")
        #expect(running["projectID"] == "DEMO")
        #expect(running["chatID"] == .string(Self.chatID.uuidString))
        #expect(try EngineJSON.decode(VirtualMachine.self, from: data) == machine)
        #expect(machine.stored == Self.machine(startedBy: .claude(projectID: "DEMO", chatID: Self.chatID)))

        let list = VMList(machines: [machine], runningCount: 2)
        #expect(try EngineJSON.decode(VMList.self, from: EngineJSON.encode(list)) == list)
        #expect(!list.canStartOne)
        #expect(VMList(machines: [machine], runningCount: 1).canStartOne)
    }

    @Test("Folders whose name is not a UUID, without vm.yml, with an invalid one or with another id are skipped, and the rest is listed oldest first")
    func loading() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            let older = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
            let other = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4E")!
            try VirtualMachineStore.write(Self.machine(), to: directory)
            try VirtualMachineStore.write(Self.machine(older, created: "2026-11-09T08:00:00Z"), to: directory)
            let machines = directory.virtualMachinesFolder
            try FileManager.default.createDirectory(at: machines.appendingPathComponent("notes"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: machines.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
            let invalid = machines.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
            try Data("name: [".utf8).write(to: invalid.appendingPathComponent("vm.yml"))
            // The id of the file is not the name of its folder.
            let mismatched = machines.appendingPathComponent(other.uuidString)
            try FileManager.default.createDirectory(at: mismatched, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: VirtualMachineStore.metadataFile(of: Self.id, in: directory),
                                             to: mismatched.appendingPathComponent("vm.yml"))
            #expect(VirtualMachineStore.loadAll(directory, log: nil).map(\.id) == [older, Self.id])
            #expect(FileManager.default.fileExists(atPath: invalid.path))
        }
    }

    @Test("The name of a virtual machine is one line of 1 to 100 characters, trimmed")
    func names() throws {
        #expect(try VirtualMachine.checkedName("  Menu checks \n") == "Menu checks")
        #expect(try VirtualMachine.checkedName(String(repeating: "a", count: 100)).count == 100)
        for name in ["", "   ", "two\nlines", String(repeating: "a", count: 101)] {
            #expect(throws: ValidationError.invalid("name", "use 1 to 100 characters on one line")) {
                try VirtualMachine.checkedName(name)
            }
        }
    }

    @Test("A clone holds the bytes of its source and changes without it; an existing destination is not replaced")
    func clone() throws {
        try withTemporaryDirectory { folder in
            let source = folder.appendingPathComponent("Disk.img")
            let copy = folder.appendingPathComponent("Clone.img")
            try Data("disk of the image".utf8).write(to: source)
            try VirtualMachineStore.clone(source, to: copy)
            #expect(try Data(contentsOf: copy) == Data("disk of the image".utf8))
            try Data("disk of the virtual machine".utf8).write(to: copy)
            #expect(try Data(contentsOf: source) == Data("disk of the image".utf8))
            #expect(throws: (any Error).self) { try VirtualMachineStore.clone(source, to: copy) }
            #expect(throws: (any Error).self) {
                try VirtualMachineStore.clone(folder.appendingPathComponent("Missing.img"), to: folder.appendingPathComponent("Other.img"))
            }
        }
    }

    @Test("The folder of a new virtual machine holds the image's files, a clone of its disk and vm.yml")
    func createFolder() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            let image = VMImageStore.files(of: Self.imageID, in: directory)
            try FileManager.default.createDirectory(at: image.folder, withIntermediateDirectories: true)
            for (file, text) in [(image.hardwareModel, "model"), (image.machineIdentifier, "identifier"),
                                 (image.auxiliaryStorage, "auxiliary"), (image.disk, "disk")] {
                try Data(text.utf8).write(to: file)
            }
            try VirtualMachineStore.create(Self.machine(), from: image, in: directory)
            let files = VirtualMachineStore.files(of: Self.id, in: directory)
            #expect(files.folder.path == folder.appendingPathComponent("VirtualMachines/Machines/\(Self.id.uuidString)").path)
            #expect(try String(contentsOf: files.hardwareModel, encoding: .utf8) == "model")
            #expect(try String(contentsOf: files.machineIdentifier, encoding: .utf8) == "identifier")
            #expect(try String(contentsOf: files.auxiliaryStorage, encoding: .utf8) == "auxiliary")
            #expect(try String(contentsOf: files.disk, encoding: .utf8) == "disk")
            #expect(VirtualMachineStore.loadAll(directory, log: nil) == [Self.machine()])

            // An image without one of its files: nothing can start from it.
            try FileManager.default.removeItem(at: image.auxiliaryStorage)
            let other = UUID()
            #expect(throws: (any Error).self) { try VirtualMachineStore.create(Self.machine(other), from: image, in: directory) }
            #expect(!FileManager.default.fileExists(atPath: VirtualMachineStore.metadataFile(of: other, in: directory).path))
        }
    }

    /// Seconds and the text of that running time.
    static let runningTimes: [(Double, String)] = [
        (0, "0 min"), (59.9, "0 min"), (60, "1 min"), (750, "12 min"), (3599, "59 min"), (3600, "1 h 00 min"),
        (3900, "1 h 05 min"), (7199, "1 h 59 min"), (7800, "2 h 10 min"), (96_000, "26 h 40 min"), (-30, "0 min"),
    ]

    @Test("The running time reads <m> min under an hour and <h> h <mm> min after", arguments: runningTimes)
    func runningTime(seconds: Double, text: String) {
        #expect(VMRunningTime.text(seconds: seconds) == text)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(VMRunningTime.text(since: start, now: start.addingTimeInterval(seconds)) == text)
    }
}
