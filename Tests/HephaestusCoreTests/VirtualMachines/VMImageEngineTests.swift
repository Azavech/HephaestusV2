import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › Virtual machine images and docs/virtual-machines.md › Adding an image,
/// with a stand-in for ipsw.me, the download and the installer.
@Suite("Virtual machine images")
struct VMImageEngineTests {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The Internet connection appears to be offline." }
    }

    // MARK: vmImages.versions

    @Test("vmImages.versions returns the list of ipsw.me, newest first")
    func versions() async throws {
        try await withVMEngine { _, connection, provisioner, _ in
            let versions = try await connection.call(VMImagesVersions.self)
            #expect(versions.map(\.build) == ["26B131", "26B123", "25G83", "24G90", "22A380", "21F79"])
            #expect(provisioner.listCalls == 1)
        }
    }

    @Test("vmImages.versions fails with unavailable when ipsw.me cannot be read")
    func versionsUnavailable() async throws {
        try await withVMEngine { _, connection, provisioner, _ in
            provisioner.list = .failure(Failure())
            #expect(await engineError { try await connection.call(VMImagesVersions.self) }
                == EngineError(.unavailable, "The macOS versions cannot be read from ipsw.me: The Internet connection appears to be offline."))
            provisioner.list = .failure(VMImageFailure("HTTP 503"))
            #expect(await engineError { try await connection.call(VMImagesVersions.self) }
                == EngineError(.unavailable, "The macOS versions cannot be read from ipsw.me: HTTP 503."))
            provisioner.list = .success(Data("<html>".utf8))
            #expect(await engineError { try await connection.call(VMImagesVersions.self) }
                == EngineError(.unavailable, "The macOS versions cannot be read from ipsw.me: unexpected answer."))
        }
    }

    @Test("A test engine without its own provisioner reaches nothing")
    func defaultProvisioner() async throws {
        try await withTestEngine { _, connection, _ in
            let images = try await connection.call(VMImagesList.self)
            #expect(images.isEmpty)
            #expect(await engineError { try await connection.call(VMImagesVersions.self) }?.code == .unavailable)
            #expect(await engineError { try await addImage(connection) }?.code == .unavailable)
        }
    }

    // MARK: vmImages.setAccount

    @Test("vmImages.setAccount stores the guest account in image.yml in every state and emits vmImages.changed once per change")
    func setAccount() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            provisioner.downloadHold = TestHold()
            let image = try await addImage(connection)
            let events = connection.events
            let stored = try await connection.call(VMImagesSetAccount.self, .init(imageID: image.id, userName: " tester ", password: "test 1"))
            #expect(stored.state == .downloading)
            #expect(stored.userName == "tester" && stored.password == "test 1")
            let changed = try #require(await firstImages(on: events) { $0.first?.userName == "tester" })
            #expect(changed.first?.password == "test 1")
            let file = VMImageStore.files(of: image.id, in: engine.dataDirectory).metadata
            #expect(try String(contentsOf: file, encoding: .utf8).contains("userName: tester\npassword: test 1\n"))

            // An absent value keeps the stored one; an empty one removes it.
            let kept = try await connection.call(VMImagesSetAccount.self, .init(imageID: image.id, password: ""))
            #expect(kept.userName == "tester" && kept.password == nil)
            #expect(try String(contentsOf: file, encoding: .utf8).contains("userName: tester\npassword: null\n"))
            #expect(try await connection.call(VMImagesList.self).first?.password == nil)

            #expect(await engineError {
                try await connection.call(VMImagesSetAccount.self, .init(imageID: image.id, userName: "a\nb"))
            } == EngineError(.invalid, "userName: use one line."))
            #expect(await engineError {
                try await connection.call(VMImagesSetAccount.self, .init(imageID: image.id, password: "a\nb"))
            } == EngineError(.invalid, "password: use one line."))
            let missing = UUID()
            #expect(await engineError {
                try await connection.call(VMImagesSetAccount.self, .init(imageID: missing, userName: "x"))
            } == EngineError(.notFound, "Image \(missing.uuidString) not found."))
            #expect(try await connection.call(VMImagesList.self).first?.userName == "tester")

            // The account survives a change of state, which rewrites the file.
            provisioner.downloadHold?.release()
            _ = try #require(await firstImages(on: connection.events) { $0.first?.state == .needsSetup })
            let list = try await connection.call(VMImagesList.self)
            #expect(list.first?.userName == "tester")
            #expect(VMImageStore.loadAll(engine.dataDirectory, log: nil).first?.userName == "tester")
        }
    }

    // MARK: vmImages.add

    @Test("vmImages.add takes the build alone, and checks the Mac, then the build")
    func addErrors() async throws {
        try await withVMEngine { _, connection, provisioner, _ in
            func add(_ build: String) async -> EngineError? {
                await engineError {
                    try await connection.call(VMImagesAdd.self, VMImagesAdd.Params(build: build))
                }
            }
            #expect(await add("99Z99") == EngineError(.notFound, "macOS build 99Z99 not found."))
            #expect(provisioner.downloads.isEmpty)
            let images = try await connection.call(VMImagesList.self)
            #expect(images.isEmpty)

            provisioner.supportsVirtualMachines = false
            #expect(await add("26B131") == EngineError(.unavailable, "Virtual machines need a Mac with Apple silicon."))
        }
    }

    @Test("vmImages.add reads the list when the engine has none, and again for a build the kept list lacks")
    func addReadsTheList() async throws {
        try await withVMEngine { _, connection, provisioner, _ in
            provisioner.downloadHold = TestHold()
            _ = try await addImage(connection, build: "21F79")
            #expect(provisioner.listCalls == 1)
            _ = try await addImage(connection, build: "22A380")
            #expect(provisioner.listCalls == 1)
            #expect(await engineError { try await addImage(connection, build: "99Z99") }?.code == .notFound)
            #expect(provisioner.listCalls == 2)
        }
    }

    @Test("An added image downloads, installs and waits for its setup; its IPSW is deleted once the install ends")
    func addDownloadsAndInstalls() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let downloadHold = TestHold()
            let installHold = TestHold()
            provisioner.downloadHold = downloadHold
            provisioner.installHold = installHold
            provisioner.downloadFractions = [0.105, 0.42, 0.429, 0.2, 1]
            provisioner.installFractions = [0.635]
            let events = connection.events

            _ = try await connection.call(SettingsUpdate.self, .init(defaultVMCores: 3, defaultVMMemoryGB: 5))
            let added = try await connection.call(VMImagesAdd.self, VMImagesAdd.Params(build: "26B123"))
            #expect(added.state == .downloading)
            #expect(added.version == "27.2" && added.build == "26B123")
            #expect(added.diskGB == 0 && added.unknownKeys.isEmpty)
            #expect(added.progress == 0 && added.percentage == 0)
            #expect(added.failure == nil)
            let files = VMImageStore.files(of: added.id, in: engine.dataDirectory)
            #expect(try ProjectFileStore.decodeYAML(VMImage.self, at: files.metadata).state == .downloading)

            // The percentage of the download: 10, 42, then 100; a lower fraction changes nothing.
            let downloaded = try #require(await firstImages(on: events) { $0.first?.percentage == 100 && $0.first?.state == .downloading })
            #expect(downloaded.first?.diskBytes ?? 0 > 0)
            #expect(FileManager.default.fileExists(atPath: files.restoreImage.path))
            #expect(provisioner.downloads.map(\.build) == ["26B123"])

            let installing = connection.events
            downloadHold.release()
            let installed = try #require(await firstImages(on: installing) { $0.first?.state == .installing && $0.first?.percentage == 63 })
            #expect(installed.first?.progress == 0.635)
            #expect(try ProjectFileStore.decodeYAML(VMImage.self, at: files.metadata).state == .installing)
            #expect(await engine.runningVMCount == 1)
            let request = try #require(provisioner.installs.first)
            // The install runs with the default values of Settings, on a disk of 32 GB.
            #expect(request == VMImageInstallRequest(version: "27.2", files: files, cores: 3, memoryGB: 5, diskGB: 32))
            #expect(FileManager.default.fileExists(atPath: files.restoreImage.path))

            let finishing = connection.events
            installHold.release()
            let ready = try #require(await firstImages(on: finishing) { $0.first?.state == .needsSetup })
            #expect(ready.first?.progress == nil)
            #expect(!FileManager.default.fileExists(atPath: files.restoreImage.path))
            #expect(FileManager.default.fileExists(atPath: files.disk.path))
            #expect(try ProjectFileStore.decodeYAML(VMImage.self, at: files.metadata).state == .needsSetup)
            #expect(await engine.runningVMCount == 0)
            #expect(try await connection.call(VMImagesList.self).map(\.state) == [.needsSetup])
        }
    }

    @Test("Each whole percentage of a download emits vmImages.changed once, in order, and never goes back")
    func percentages() async throws {
        try await withVMEngine { _, connection, provisioner, _ in
            provisioner.downloadHold = TestHold()
            provisioner.downloadFractions = [0.101, 0.105, 0.109, 0.2, 0.2, 0.15, 0.3]
            let events = connection.events
            _ = try await addImage(connection)
            // The new image, then 10 %, 20 % and 30 %: 0.105, 0.109, the second 0.2 and 0.15 emit nothing.
            let log = EventLog()
            _ = await firstElement(of: events) { envelope in
                guard envelope.name == VMImagesChangedEvent.name else { return false }
                log.append(envelope)
                return log.envelopes.count == 4
            }
            let changes = log.envelopes.compactMap { try? $0.payload(VMImagesChangedEvent.self).first }
            #expect(changes.map(\.percentage) == [0, 10, 20, 30])
            #expect(changes.allSatisfy { $0.state == .downloading })
        }
    }

    @Test("A failed download sets the image to failed with the message, and leaves no IPSW")
    func downloadFailure() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            provisioner.downloadFailure = Failure()
            let events = connection.events
            let added = try await addImage(connection)
            let images = try #require(await firstImages(on: events) { $0.first?.state == .failed })
            #expect(images.first?.failure == "The Internet connection appears to be offline.")
            #expect(images.first?.progress == nil)
            let files = VMImageStore.files(of: added.id, in: engine.dataDirectory)
            #expect(!FileManager.default.fileExists(atPath: files.restoreImage.path))
            let stored = try ProjectFileStore.decodeYAML(VMImage.self, at: files.metadata)
            #expect(stored.state == .failed && stored.failure == "The Internet connection appears to be offline.")
            #expect(provisioner.installs.isEmpty)
            #expect(await engine.runningVMCount == 0)
        }
    }

    @Test("A failed install sets the image to failed, deletes the IPSW and frees its virtual machine")
    func installFailure() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            provisioner.installFailure = VMImageFailure("This Mac cannot run macOS 27.2.1.")
            let events = connection.events
            let added = try await addImage(connection)
            let images = try #require(await firstImages(on: events) { $0.first?.state == .failed })
            #expect(images.first?.failure == "This Mac cannot run macOS 27.2.1.")
            let files = VMImageStore.files(of: added.id, in: engine.dataDirectory)
            #expect(!FileManager.default.fileExists(atPath: files.restoreImage.path))
            #expect(FileManager.default.fileExists(atPath: files.metadata.path))
            #expect(await engine.runningVMCount == 0)
        }
    }

    // MARK: Running virtual machines

    @Test("A third install waits while 2 virtual machines run, and starts when one ends")
    func installsWaitForAFreeVirtualMachine() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let hold = TestHold()
            provisioner.installHold = hold
            let events = connection.events
            let first = try await addImage(connection, build: "26B131")
            let second = try await addImage(connection, build: "26B123")
            let third = try await addImage(connection, build: "25G83")
            let waiting = try #require(await firstImages(on: events) { images in
                images.count == 3 && images.allSatisfy { $0.state == .installing }
            })
            #expect(waiting.count == 3)
            // Two installs run; the third has no virtual machine yet and shows 0 %.
            await waitUntil { hold.waitingCount == 2 }
            #expect(hold.waitingCount == 2)
            #expect(await engine.runningVMCount == 2)
            #expect(provisioner.installs.count == 2)
            let list = try await connection.call(VMImagesList.self)
            let started = Set(provisioner.installs.map { $0.files.folder.lastPathComponent })
            let waitingImage = try #require(list.first { !started.contains($0.id.uuidString) })
            #expect(waitingImage.percentage == 0)
            #expect(Set(list.map(\.id)) == [first.id, second.id, third.id])

            let finishing = connection.events
            hold.release()
            let done = try #require(await firstImages(on: finishing) { images in images.allSatisfy { $0.state == .needsSetup } })
            #expect(done.count == 3)
            #expect(provisioner.installs.count == 3)
            #expect(await engine.runningVMCount == 0)
        }
    }

    // MARK: vmImages.delete

    @Test("vmImages.delete ends the download and deletes the image's folder")
    func deleteWhileDownloading() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            provisioner.downloadHold = TestHold()
            let added = try await addImage(connection)
            let folder = engine.dataDirectory.vmImageFolder(added.id)
            #expect(FileManager.default.fileExists(atPath: folder.path))
            let events = connection.events
            _ = try await connection.call(VMImagesDelete.self, VMImagesDelete.Params(imageID: added.id))
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect(try await connection.call(VMImagesList.self).isEmpty)
            #expect(await firstImages(on: events) { $0.isEmpty } != nil)
            #expect(provisioner.installs.isEmpty)
            #expect(await engineError { try await connection.call(VMImagesDelete.self, VMImagesDelete.Params(imageID: added.id)) }
                == EngineError(.notFound, "Image \(added.id.uuidString) not found."))
        }
    }

    @Test("vmImages.delete ends an install that waits or runs and frees its virtual machine")
    func deleteWhileInstalling() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let hold = TestHold()
            provisioner.installHold = hold
            let events = connection.events
            let first = try await addImage(connection, build: "26B131")
            let second = try await addImage(connection, build: "26B123")
            let third = try await addImage(connection, build: "25G83")
            _ = try #require(await firstImages(on: events) { $0.count == 3 && $0.allSatisfy { $0.state == .installing } })
            await waitUntil { hold.waitingCount == 2 }
            for id in [first.id, second.id, third.id] {
                _ = try await connection.call(VMImagesDelete.self, VMImagesDelete.Params(imageID: id))
            }
            #expect(try await connection.call(VMImagesList.self).isEmpty)
            #expect(await engine.runningVMCount == 0)
            #expect(!FileManager.default.fileExists(atPath: engine.dataDirectory.vmImageFolder(first.id).path))
        }
    }

    @Test("vmImages.delete deletes a failed image and one that waits for its setup")
    func deleteIdleImages() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let installed = try await addInstalledImage(connection)
            provisioner.downloadFailure = Failure()
            let events = connection.events
            let failed = try await addImage(connection, build: "26B123")
            _ = try #require(await firstImages(on: events) { $0.contains { $0.id == failed.id && $0.state == .failed } })
            for id in [installed.id, failed.id] {
                _ = try await connection.call(VMImagesDelete.self, VMImagesDelete.Params(imageID: id))
                #expect(!FileManager.default.fileExists(atPath: engine.dataDirectory.vmImageFolder(id).path))
            }
            #expect(try await connection.call(VMImagesList.self).isEmpty)
        }
    }

    // MARK: Launch

    @Test("At launch an image that was downloading or installing becomes failed and its IPSW is deleted")
    func interruptedImages() async throws {
        let downloading = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
        let installing = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4E")!
        let waiting = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4F")!
        try await withVMEngine(prepare: { directory in
            for (id, state, created) in [(downloading, VMImageState.downloading, "2026-11-08T09:30:00Z"),
                                         (installing, .installing, "2026-11-08T09:31:00Z"),
                                         (waiting, .needsSetup, "2026-11-08T09:32:00Z")] {
                try VMImageStore.write(VMImageFileTests.image(id, state: state, created: created), to: directory)
                try Data("ipsw".utf8).write(to: VMImageStore.files(of: id, in: directory).restoreImage)
            }
        }) { engine, connection, provisioner, _ in
            let images = try await connection.call(VMImagesList.self)
            #expect(images.map(\.id) == [downloading, installing, waiting])
            #expect(images.map(\.state) == [.failed, .failed, .needsSetup])
            #expect(images[0].failure == "The app quit before the image was ready.")
            #expect(images[1].failure == "The app quit before the image was ready.")
            for id in [downloading, installing] {
                let files = VMImageStore.files(of: id, in: engine.dataDirectory)
                #expect(!FileManager.default.fileExists(atPath: files.restoreImage.path))
                #expect(try ProjectFileStore.decodeYAML(VMImage.self, at: files.metadata).state == .failed)
            }
            #expect(provisioner.downloads.isEmpty)
        }
    }

    @Test("Quitting ends the downloads without failing their images")
    func shutdownEndsDownloads() async throws {
        var folderOfImage: URL?
        try await withVMEngine { engine, connection, provisioner, _ in
            provisioner.downloadHold = TestHold()
            let added = try await addImage(connection)
            folderOfImage = engine.dataDirectory.vmImageFolder(added.id)
            await engine.shutdown()
            // The image keeps its state: the next launch makes it failed.
            let stored = try ProjectFileStore.decodeYAML(VMImage.self, at: VMImageStore.files(of: added.id, in: engine.dataDirectory).metadata)
            #expect(stored.state == .downloading)
        }
        #expect(folderOfImage != nil)
    }
}
