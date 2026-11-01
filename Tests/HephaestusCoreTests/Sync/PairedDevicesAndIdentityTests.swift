import Foundation
import Network
import Testing
@testable import HephaestusCore

/// docs/remote.md › Paired devices, › Removing a device, › Browsing, › Device identity.
@Suite("Paired devices and device identity")
struct PairedDevicesAndIdentityTests {
    static let studioID = UUID(uuidString: "9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6")!
    static let macBookID = UUID(uuidString: "6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C")!

    @Test("Pairing again replaces the record at its place and its code")
    func saveKeepsPlace() async throws {
        try await withTestEngine { engine, _, _ in
            let store = engine.pairedDevices
            let updates = store.deviceUpdates
            let first = PairingCode.generate()
            try store.save(RemoteDevice(id: Self.studioID, name: "Studio", host: "studio.local", port: 47821), code: first)
            try store.save(RemoteDevice(id: Self.macBookID, name: "MacBook", host: "2001:db8::5", port: 47821), code: PairingCode.generate())
            let second = PairingCode.generate()
            try store.save(RemoteDevice(id: Self.studioID, name: "Studio 2", host: "192.168.1.20", port: 47900), code: second)
            #expect(store.devices.map(\.name) == ["Studio 2", "MacBook"])
            #expect(store.devices.first?.host == "192.168.1.20")
            #expect(store.code(forDeviceID: Self.studioID.uuidString.lowercased()) == second)
            #expect(store.device(id: Self.macBookID.uuidString.lowercased())?.host == "2001:db8::5")
            let seen = await firstElements(4, of: updates)
            #expect(seen.map { $0.map(\.name) } == [[], ["Studio"], ["Studio", "MacBook"], ["Studio 2", "MacBook"]])

            let files = try DeviceFileStore.loadAll(engine.dataDirectory, log: nil)
            #expect(files.remotes.remotes == store.devices)
            #expect(files.secrets.remoteSecrets == [Self.studioID.uuidString: second.display,
                                                   Self.macBookID.uuidString: try #require(store.code(forDeviceID: Self.macBookID.uuidString)).display])
            // An invalid record is refused and nothing is saved.
            #expect(throws: ValidationError.self) {
                try store.save(RemoteDevice(id: UUID(), name: "Bad", host: "[::1]", port: 47821), code: first)
            }
            #expect(store.devices.count == 2)
            #expect(engine.secrets.current.remoteSecrets.count == 2)
        }
    }

    @Test("Every welcome updates the name and lastConnected, and a Bonjour address")
    func recordWelcome() async throws {
        try await withTestEngine { engine, _, _ in
            let store = engine.pairedDevices
            try store.save(RemoteDevice(id: Self.studioID, name: "Studio", host: "studio.local", port: 47821), code: PairingCode.generate())
            let date = try #require(ISODate.apiDate(from: "2026-10-31T14:03:07.412Z"))
            try store.recordWelcome(deviceID: Self.studioID.uuidString, name: "Studio Pro", host: nil, port: nil, at: date)
            #expect(store.devices.first?.name == "Studio Pro")
            #expect(store.devices.first?.host == "studio.local")
            #expect(store.devices.first?.lastConnected == ISODate.apiDate(from: "2026-10-31T14:03:07Z"))
            try store.recordWelcome(deviceID: Self.studioID.uuidString, name: "Studio Pro", host: "192.168.1.20", port: 47830, at: date)
            #expect(store.devices.first?.host == "192.168.1.20")
            #expect(store.devices.first?.port == 47830)
            // A device removed meanwhile is not added again.
            try store.recordWelcome(deviceID: Self.macBookID.uuidString, name: "MacBook", host: nil, port: nil, at: date)
            #expect(store.devices.count == 1)
            let text = try String(contentsOf: engine.dataDirectory.remotesFile, encoding: .utf8)
            #expect(text.contains("lastConnected: 2026-10-31T14:03:07Z"))
            #expect(text.contains("name: Studio Pro"))
        }
    }

    @Test("Removing deletes the record and its code")
    func remove() async throws {
        try await withTestEngine { engine, _, _ in
            let store = engine.pairedDevices
            try store.save(RemoteDevice(id: Self.studioID, name: "Studio", host: "studio.local", port: 47821), code: PairingCode.generate())
            try store.save(RemoteDevice(id: Self.macBookID, name: "MacBook", host: "macbook.local", port: 47821), code: PairingCode.generate())
            try store.remove(deviceID: Self.studioID.uuidString.lowercased())
            #expect(store.devices.map(\.id) == [Self.macBookID])
            #expect(store.code(forDeviceID: Self.studioID.uuidString) == nil)
            let files = try DeviceFileStore.loadAll(engine.dataDirectory, log: nil)
            #expect(files.remotes.remotes.map(\.id) == [Self.macBookID])
            #expect(files.secrets.remoteSecrets.keys.sorted() == [Self.macBookID.uuidString])
            try store.remove(deviceID: Self.studioID.uuidString)
            #expect(store.devices.count == 1)
        }
    }

    @Test("Browse results: invalid ids and this device are ignored, ids merged, names defaulted")
    func browseResults() {
        func service(_ name: String) -> NWEndpoint {
            .service(name: name, type: DeviceBrowser.serviceType, domain: "local.", interface: nil)
        }
        let own = "11111111-2222-3333-4444-555555555555"
        let results: [DeviceBrowser.Result] = [
            .init(sequence: 3, endpoint: service("Studio (2)"), instanceName: "Studio (2)",
                  txt: ["id": Self.studioID.uuidString.lowercased(), "name": "Second", "proto": "1"]),
            .init(sequence: 1, endpoint: service("Studio"), instanceName: "Studio",
                  txt: ["id": Self.studioID.uuidString, "name": "Studio", "proto": "1"]),
            .init(sequence: 2, endpoint: service("Old"), instanceName: "Old Mac", txt: ["id": Self.macBookID.uuidString, "name": ""]),
            .init(sequence: 4, endpoint: service("Self"), instanceName: "Self", txt: ["id": own, "proto": "1"]),
            .init(sequence: 5, endpoint: service("NoID"), instanceName: "NoID", txt: ["proto": "1"]),
            .init(sequence: 6, endpoint: service("BadID"), instanceName: "BadID", txt: ["id": "studio", "proto": "1"]),
        ]
        let devices = DeviceBrowser.devices(from: results, ownDeviceID: own.lowercased())
        #expect(devices.map(\.id) == [Self.macBookID.uuidString, Self.studioID.uuidString])
        #expect(devices.map(\.name) == ["Old Mac", "Studio"])
        #expect(devices[1].endpoint == service("Studio"))
        #expect(devices[1].isCompatible)
        #expect(!devices[0].isCompatible)
        #expect(devices[0].proto == nil)
        #expect(DiscoveredDevice(id: "x", name: "x", proto: "2", endpoint: service("x")).isCompatible == false)
    }

    @Test("Renaming the device: trimmed, stored in device.yml, empty uses the computer name")
    func rename() async throws {
        try await withTestEngine { engine, _, _ in
            try await engine.renameDevice(to: "  Studio  ")
            let info = await engine.localDeviceInfo()
            #expect(info.name == "Studio")
            #expect(await engine.deviceNameSetting() == "Studio")
            #expect(try String(contentsOf: engine.dataDirectory.deviceFile, encoding: .utf8).contains("name: Studio"))
            #expect(engine.deviceBrowser.helloName(for: info) == "Studio")
            let stale = DeviceInfo(id: info.id, name: "Old", appVersion: info.appVersion, build: info.build)
            #expect(engine.deviceBrowser.helloName(for: stale) == "Studio")

            let error = await engineError { try await engine.renameDevice(to: String(repeating: "a", count: 64)) }
            #expect(error?.code == .invalid)
            #expect(await engineError { try await engine.renameDevice(to: "Two\nlines") }?.code == .invalid)
            #expect(await engine.localDeviceInfo().name == "Studio")

            try await engine.renameDevice(to: "   ")
            #expect(await engine.deviceNameSetting() == (await engine.computerName))
            #expect(try DeviceFileStore.loadAll(engine.dataDirectory, log: nil).device.name == nil)
        }
    }
}
