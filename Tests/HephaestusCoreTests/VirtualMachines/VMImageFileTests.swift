import Foundation
import Testing
@testable import HephaestusCore

/// docs/data-model.md › Image metadata file and docs/virtual-machines.md › Storage.
@Suite("Image metadata files")
struct VMImageFileTests {
    static let id = UUID(uuidString: "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F")!

    static func image(_ id: UUID = VMImageFileTests.id, state: VMImageState = .ready, created: String = "2026-11-09T14:03:00Z") -> VMImage {
        VMImage(id: id, version: "27.2.1", build: "26B131", state: state, created: ISODate.date(from: created)!)
    }

    @Test("An image is written with its keys in the order of the field table, without the keys that are never stored")
    func write() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            var image = Self.image()
            image.progress = 0.42
            image.diskBytes = 1_000
            image.diskGB = 32
            try VMImageStore.write(image, to: directory)
            let file = folder.appendingPathComponent("VirtualMachines/Images/\(Self.id.uuidString)/image.yml")
            #expect(try String(contentsOf: file, encoding: .utf8) == """
                schema: 1
                id: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
                version: 27.2.1
                build: 26B131
                state: ready
                failure: null
                created: 2026-11-09T14:03:00Z

                """)
            #expect(VMImageStore.files(of: Self.id, in: directory).metadata.path == file.path)
            #expect(VMImageStore.loadAll(directory, log: nil) == [Self.image()])
        }
    }

    @Test("A version that YAML would read as a number, the failure and the unknown keys survive a rewrite")
    func roundTrip() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            let file = VMImageStore.files(of: Self.id, in: directory).metadata
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("""
                id: 5b8e7f60-3c1d-4a2b-9e8f-7a6b5c4d3e2f
                version: '26.6'
                build: 25G72
                state: failed
                failure: The app quit before the image was ready.
                created: 2026-11-08T09:30:00Z
                note: kept
                progress: 0.5
                """.utf8).write(to: file)
            let image = try #require(VMImageStore.loadAll(directory, log: nil).first)
            #expect(image.id == Self.id)
            #expect(image.version == "26.6")
            #expect(image.state == .failed)
            #expect(image.failure == "The app quit before the image was ready.")
            #expect(image.progress == nil)
            #expect(image.unknownKeys == ["note": "kept"])
            try VMImageStore.write(image, to: directory)
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("version: '26.6'\n"))
            #expect(text.hasSuffix("created: 2026-11-08T09:30:00Z\nnote: kept\n"))
            #expect(!text.contains("progress"))
            #expect(VMImageStore.loadAll(directory, log: nil) == [image])
        }
    }

    @Test("The engine API adds progress, diskBytes and diskGB")
    func apiKeys() throws {
        var image = Self.image(state: .downloading)
        image.progress = 0.426
        image.diskBytes = 123
        image.diskGB = 32
        let json = try jsonValue(String(decoding: try EngineJSON.encode(image), as: UTF8.self))
        #expect(json == (try jsonValue("""
            {"build": "26B131", "created": "2026-11-09T14:03:00Z", "diskBytes": 123, "diskGB": 32, "failure": null,
             "id": "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F", "progress": 0.426, "schema": 1, "state": "downloading",
             "version": "27.2.1"}
            """)))
        #expect(try EngineJSON.decode(VMImage.self, from: try EngineJSON.encode(image)) == image)
        #expect(image.percentage == 42)
        image.progress = nil
        #expect(image.percentage == 0)
        #expect(try jsonValue(String(decoding: try EngineJSON.encode(image), as: UTF8.self)).objectValue?["progress"] == nil)
        image.progress = 1
        #expect(image.percentage == 100)
        image.progress = 0.999
        #expect(image.percentage == 99)
    }

    @Test("Folders that hold no valid image are skipped, and the images come oldest first")
    func loading() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            #expect(VMImageStore.loadAll(directory, log: nil).isEmpty)
            let older = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
            let sameDate = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4E")!
            try VMImageStore.write(Self.image(), to: directory)
            try VMImageStore.write(Self.image(older, created: "2026-11-08T09:30:00Z"), to: directory)
            try VMImageStore.write(Self.image(sameDate, created: "2026-11-08T09:30:00Z"), to: directory)

            let images = directory.vmImagesFolder
            // Not a UUID.
            try FileManager.default.createDirectory(at: images.appendingPathComponent("notes"), withIntermediateDirectories: true)
            // No image.yml.
            let empty = UUID()
            try FileManager.default.createDirectory(at: directory.vmImageFolder(empty), withIntermediateDirectories: true)
            // Not valid.
            let invalid = UUID()
            try FileManager.default.createDirectory(at: directory.vmImageFolder(invalid), withIntermediateDirectories: true)
            try Data("id: [".utf8).write(to: VMImageStore.files(of: invalid, in: directory).metadata)
            // An unknown state.
            let unknownState = UUID()
            try FileManager.default.createDirectory(at: directory.vmImageFolder(unknownState), withIntermediateDirectories: true)
            try Data("id: \(unknownState.uuidString)\nversion: '27'\nbuild: X\ncores: 2\nmemoryGB: 4\ndiskGB: 64\nstate: paused\ncreated: 2026-11-08T09:30:00Z\n".utf8)
                .write(to: VMImageStore.files(of: unknownState, in: directory).metadata)
            // The id of another folder.
            let misplaced = UUID()
            try FileManager.default.createDirectory(at: directory.vmImageFolder(misplaced), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: VMImageStore.files(of: Self.id, in: directory).metadata,
                                             to: VMImageStore.files(of: misplaced, in: directory).metadata)

            // A file of `Images/` is no folder of an image.
            try Data().write(to: images.appendingPathComponent(".DS_Store"))

            let log = MemoryLog()
            #expect(VMImageStore.loadAll(directory, log: log).map(\.id) == [older, sameDate, Self.id])
            #expect(FileManager.default.fileExists(atPath: directory.vmImageFolder(invalid).path))
            // Each skipped folder is logged once; the file is not.
            let lines = log.entries.map(\.message)
            #expect(log.entries.allSatisfy { $0.level == .warn && $0.component == .storage })
            #expect(lines.count == 5)
            #expect(lines.contains("\(images.appendingPathComponent("notes").path) is skipped: its name is not a UUID"))
            #expect(lines.contains("\(directory.vmImageFolder(empty).path) has no image.yml and is skipped"))
            #expect(lines.contains { $0.hasPrefix("\(VMImageStore.files(of: invalid, in: directory).metadata.path) is skipped: ") })
            #expect(lines.contains { $0.hasPrefix("\(VMImageStore.files(of: unknownState, in: directory).metadata.path) is skipped: ") })
            #expect(lines.contains("\(VMImageStore.files(of: misplaced, in: directory).metadata.path) is skipped: its id is not the name of its folder"))
        }
    }

    @Test("The disk use of an image is the space of the files of its folder")
    func diskBytes() throws {
        try withTemporaryDirectory { folder in
            #expect(VMImageStore.diskBytes(of: folder.appendingPathComponent("missing")) == 0)
            try Data(repeating: 7, count: 100_000).write(to: folder.appendingPathComponent("Disk.img"))
            try Data(repeating: 7, count: 100_000).write(to: folder.appendingPathComponent("Restore.ipsw"))
            #expect(VMImageStore.diskBytes(of: folder) >= 200_000)
        }
    }

    @Test("The ranges of a virtual machine's values on a Mac, its disk from the image's, and the message of a value outside its range")
    func limits() throws {
        let limits = VMImageLimits(processorCount: 14, physicalMemory: 36 * 1024 * 1024 * 1024)
        #expect(limits.cores == 2...14)
        #expect(limits.memoryGB == 4...36)
        #expect(limits.diskGB == 32...2048)
        #expect(limits.diskGB(imageDiskGB: 32) == 32...2048)
        #expect(limits.diskGB(imageDiskGB: 64) == 64...2048)
        try limits.check(cores: 2, memoryGB: 4, diskGB: 32, imageDiskGB: 32)
        try limits.check(cores: 14, memoryGB: 36, diskGB: 2048, imageDiskGB: 64)
        #expect(throws: ValidationError.invalid("cores", "use a number from 2 to 14")) {
            try limits.check(cores: 1, memoryGB: 1, diskGB: 1, imageDiskGB: 32)
        }
        #expect(throws: ValidationError.invalid("memoryGB", "use a number from 4 to 36")) {
            try limits.check(cores: 2, memoryGB: 37, diskGB: 1, imageDiskGB: 32)
        }
        #expect(throws: ValidationError.invalid("diskGB", "use a number from 64 to 2048")) {
            try limits.check(cores: 2, memoryGB: 4, diskGB: 63, imageDiskGB: 64)
        }
        #expect(throws: ValidationError.invalid("diskGB", "use a number from 32 to 2048")) {
            try limits.check(cores: 2, memoryGB: 4, diskGB: 2049, imageDiskGB: 32)
        }
        #expect(VMImageLimits.message("cores", limits.cores) == "cores: use a number from 2 to 14.")
        // A Mac smaller than the defaults still accepts them.
        let small = VMImageLimits(processorCount: 1, physicalMemory: 2 * 1024 * 1024 * 1024)
        #expect(small.cores == 2...2)
        #expect(small.memoryGB == 4...4)
        #expect(VMImageLimits.imageDiskGB == 32)
        #expect(VMImageLimits.gigabytes(ofBytes: 32 * VMImageLimits.bytesPerGB) == 32)
        #expect(VMImageLimits.gigabytes(ofBytes: 32 * VMImageLimits.bytesPerGB + 1) == 33)
    }

    @Test("An image.yml with the cores, memoryGB and diskGB of an earlier version loads; cores and memoryGB stay as unknown keys")
    func oldValues() throws {
        try withTemporaryDirectory { folder in
            let directory = DataDirectory(url: folder)
            let file = VMImageStore.files(of: Self.id, in: directory).metadata
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("""
                schema: 1
                id: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
                version: 27.2.1
                build: 26B131
                cores: 2
                memoryGB: 4
                diskGB: 64
                state: ready
                failure: null
                created: 2026-11-09T14:03:00Z
                """.utf8).write(to: file)
            let image = try #require(VMImageStore.loadAll(directory, log: nil).first)
            #expect(image.state == .ready && image.version == "27.2.1")
            #expect(image.diskGB == 0)
            #expect(image.unknownKeys == ["cores": .int(2), "memoryGB": .int(4)])
            try VMImageStore.write(image, to: directory)
            let written = try String(contentsOf: file, encoding: .utf8)
            #expect(written.contains("cores: 2") && written.contains("memoryGB: 4") && !written.contains("diskGB"))
            // The disk size comes from Disk.img.
            let disk = VMImageStore.files(of: Self.id, in: directory).disk
            try Data().write(to: disk)
            let handle = try FileHandle(forWritingTo: disk)
            try handle.truncate(atOffset: 64 * VMImageLimits.bytesPerGB)
            try handle.close()
            #expect(VMImageStore.diskGB(of: VMImageStore.files(of: Self.id, in: directory)) == 64)
        }
    }

    @Test("Paths of docs/virtual-machines.md › Storage")
    func paths() {
        let directory = DataDirectory(url: URL(fileURLWithPath: "/Users/example/Library/Application Support/HephaestusV2"))
        let root = directory.url.path
        let files = VMImageStore.files(of: Self.id, in: directory)
        let folder = root + "/VirtualMachines/Images/5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F"
        #expect(directory.vmImagesFolder.path == root + "/VirtualMachines/Images")
        #expect(files.folder.path == folder)
        #expect(files.metadata.path == folder + "/image.yml")
        #expect(files.restoreImage.path == folder + "/Restore.ipsw")
        #expect(files.hardwareModel.path == folder + "/HardwareModel")
        #expect(files.machineIdentifier.path == folder + "/MachineIdentifier")
        #expect(files.auxiliaryStorage.path == folder + "/AuxiliaryStorage")
        #expect(files.disk.path == folder + "/Disk.img")
        #expect(directory.guestShareFolder.path == root + "/Runtime/guest")
        #expect(GuestTools.installCommand == #"sh "/Volumes/My Shared Files/install.sh""#)
    }
}
