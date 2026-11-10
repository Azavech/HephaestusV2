import Foundation
import Testing
@testable import HephaestusCore

/// docs/virtual-machines.md › Default image.
@Suite("Default image of virtual machines")
struct VMDefaultImageTests {
    @Test("The first image that becomes Ready is the default while no image is the default")
    func firstReadyImage() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == nil)
            let first = try await addInstalledImage(connection, build: "26B131")
            // An image that waits for its setup is not the default.
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == nil)

            let events = connection.events
            let session = try await engine.beginImageSetup(first.id)
            let machine = try #require(provisioner.machines.last)
            await MainActor.run { machine.agentConnects(sip: .disabled) }
            await session.finish()
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == first.id)
            let updated = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: events))
            #expect(try updated.payload(SettingsUpdatedEvent.self).defaultVMImage == first.id)
            #expect(updated.origin == .user(deviceID: engine.deviceID))
            let stored = try ProjectFileStore.decodeYAML(HostSettings.self, at: engine.dataDirectory.settingsFile)
            #expect(stored.defaultVMImage == first.id)

            // A second Ready image does not replace it.
            let second = try await addReadyImage(engine, connection, provisioner, build: "26B123")
            #expect(second.state == .ready)
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == first.id)
        }
    }

    @Test("settings.update accepts only a Ready image as the default")
    func settingsUpdate() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let first = try await addReadyImage(engine, connection, provisioner, build: "26B131")
            let second = try await addReadyImage(engine, connection, provisioner, build: "26B123")
            let waiting = try await addInstalledImage(connection, build: "25G83")
            let refused = EngineError(.invalid, "defaultVMImage: use the id of an image that is Ready.")

            let events = connection.events
            let updated = try await connection.call(SettingsUpdate.self, SettingsUpdate.Params(defaultVMImage: .set(second.id)))
            #expect(updated.defaultVMImage == second.id)
            let event = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: events))
            #expect(try event.payload(SettingsUpdatedEvent.self).defaultVMImage == second.id)
            let text = try String(contentsOf: engine.dataDirectory.settingsFile, encoding: .utf8)
            #expect(text.contains("defaultVMImage: \(second.id.uuidString)\n"))

            #expect(await engineError {
                try await connection.call(SettingsUpdate.self, SettingsUpdate.Params(defaultVMImage: .set(waiting.id)))
            } == refused)
            #expect(await engineError {
                try await connection.call(SettingsUpdate.self, SettingsUpdate.Params(defaultVMImage: .set(UUID())))
            } == refused)
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == second.id)

            // Another key changes with the default image in place, and null leaves no default.
            #expect(try await connection.call(SettingsUpdate.self, SettingsUpdate.Params(formatSwiftOnSave: true)).defaultVMImage == second.id)
            #expect(try await connection.call(SettingsUpdate.self, SettingsUpdate.Params(defaultVMImage: .clear)).defaultVMImage == nil)
            #expect(try await connection.call(SettingsUpdate.self, SettingsUpdate.Params(defaultVMImage: .set(first.id))).defaultVMImage == first.id)
        }
    }

    @Test("Deleting the default image leaves no default until another image becomes Ready")
    func deleteDefault() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let first = try await addReadyImage(engine, connection, provisioner, build: "26B131")
            let second = try await addReadyImage(engine, connection, provisioner, build: "26B123")
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == first.id)

            let events = connection.events
            _ = try await connection.call(VMImagesDelete.self, VMImagesDelete.Params(imageID: first.id))
            // settings.updated, without default image, comes before the vmImages.changed without the image.
            let seen = EventLog()
            _ = await firstElement(of: events) { envelope in
                seen.append(envelope)
                return (try? envelope.payload(VMImagesChangedEvent.self).map(\.id)) == [second.id]
            }
            let cleared = seen.envelopes.firstIndex { (try? $0.payload(SettingsUpdatedEvent.self))?.defaultVMImage == nil && $0.name == SettingsUpdatedEvent.name }
            #expect(cleared != nil && cleared! < seen.envelopes.count - 1)
            #expect(seen.envelopes.last?.name == VMImagesChangedEvent.name)
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == nil)
            #expect(try await connection.call(VMImagesList.self).map(\.id) == [second.id])

            // Deleting an image that is not the default changes no setting.
            let third = try await addReadyImage(engine, connection, provisioner, build: "25G83")
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == third.id)
            _ = try await connection.call(VMImagesDelete.self, VMImagesDelete.Params(imageID: second.id))
            #expect(try await connection.call(SettingsGet.self).defaultVMImage == third.id)
        }
    }

    @Test("At launch a default image that is not Ready is cleared")
    func staleDefaultAtLaunch() async throws {
        let waiting = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
        try await withVMEngine(prepare: { directory in
            try VMImageStore.write(VMImageFileTests.image(waiting, state: .needsSetup), to: directory)
            try DeviceFileStore.write(HostSettings(defaultVMImage: waiting), to: directory)
        }) { engine, connection, _, _ in
            let settings = try await connection.call(SettingsGet.self)
            #expect(settings.defaultVMImage == nil)
            #expect(try ProjectFileStore.decodeYAML(HostSettings.self, at: engine.dataDirectory.settingsFile).defaultVMImage == nil)
        }
        let ready = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4E")!
        try await withVMEngine(prepare: { directory in
            try VMImageStore.write(VMImageFileTests.image(ready, state: .ready), to: directory)
            try DeviceFileStore.write(HostSettings(defaultVMImage: ready), to: directory)
        }) { _, connection, _, _ in
            let settings = try await connection.call(SettingsGet.self)
            #expect(settings.defaultVMImage == ready)
        }
        try await withVMEngine(prepare: { directory in
            try DeviceFileStore.write(HostSettings(defaultVMImage: UUID()), to: directory)
        }) { _, connection, _, _ in
            let settings = try await connection.call(SettingsGet.self)
            #expect(settings.defaultVMImage == nil)
        }
    }
}
