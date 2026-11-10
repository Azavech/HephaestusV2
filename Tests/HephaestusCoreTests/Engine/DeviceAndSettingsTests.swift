import Foundation
import Testing
@testable import HephaestusCore

/// `device.info`, `snapshot.get`, `settings.get`, `settings.update` and `claude.status` through
/// `LocalEngineConnection` (docs/engine-api.md › Device and snapshot, › Settings, › Claude).
@Suite("Device, snapshot and settings")
struct DeviceAndSettingsTests {
    static let deviceID = "D3B07384-D113-4EC6-A3F4-1F6E2B5A9C80"

    /// Writes a device.yml with a known id and the name `Studio`.
    static func writeDevice(_ directory: DataDirectory) throws {
        try Data("schema: 1\nid: \(deviceID.lowercased())\nname: Studio\n".utf8).write(to: directory.deviceFile)
    }

    @Test("device.info returns the device of device.yml, the configuration's version and protocol 1")
    func deviceInfo() async throws {
        try await withTestEngine(prepare: Self.writeDevice) { engine, connection, _ in
            let info = try await connection.call(DeviceInfoMethod.self)
            #expect(info == DeviceInfo(id: Self.deviceID, name: "Studio", appVersion: "0.0.0", build: 0, protocolVersion: 1))
            #expect(engine.deviceID == Self.deviceID)
            #expect(connection.deviceInfo == info)
            #expect(String(decoding: try EngineJSON.encode(info), as: UTF8.self)
                == #"{"appVersion":"0.0.0","build":0,"id":"D3B07384-D113-4EC6-A3F4-1F6E2B5A9C80","name":"Studio","protocolVersion":1}"#)
        }
    }

    @Test("device.info uses the computer name when device.yml has no name")
    func computerName() async throws {
        try await withTestEngine { engine, connection, _ in
            let info = try await connection.call(DeviceInfoMethod.self)
            let computerName = await engine.computerName
            #expect(info.name == computerName)
            #expect(!info.name.isEmpty)
        }
    }

    @Test("snapshot.get holds the device, the lists, the settings and the Claude status")
    func snapshot() async throws {
        try await withTestEngine(prepare: Self.writeDevice) { _, connection, _ in
            let snapshot = try await connection.call(SnapshotGet.self)
            #expect(snapshot.device == (try await connection.call(DeviceInfoMethod.self)))
            #expect(snapshot.projects.isEmpty)
            // The library holds only the internal skills (docs/skills.md › Internal skills).
            #expect(snapshot.skills.map(\.name) == InternalSkills.names)
            #expect(snapshot.settings == HostSettings())
            #expect(snapshot.claude == ClaudeStatus.detecting)
            let json = try jsonValue(String(decoding: try EngineJSON.encode(snapshot), as: UTF8.self))
            #expect(json.objectValue?["claude"] == (try jsonValue(#"{"available": false, "checking": true}"#)))
            #expect(Set(json.objectValue?.keys.map { $0 } ?? []) == ["device", "projects", "skills", "settings", "claude"])
        }
    }

    @Test("claude.status returns the status while detection is not finished")
    func claudeStatus() async throws {
        try await withTestEngine { _, connection, _ in
            let status = try await connection.call(ClaudeStatusMethod.self)
            #expect(status == ClaudeStatus(available: false, checking: true))
            #expect(String(decoding: try EngineJSON.encode(status), as: UTF8.self) == #"{"available":false,"checking":true}"#)
        }
    }

    @Test("settings.get returns settings.yml with the defaults for missing keys")
    func settingsGet() async throws {
        try await withTestEngine(prepare: { directory in
            try Data("schema: 1\nmcpPort: 47830\nformatSwiftOnSave: true\n".utf8).write(to: directory.settingsFile)
        }) { _, connection, _ in
            let settings = try await connection.call(SettingsGet.self)
            #expect(settings == HostSettings(mcpPort: 47830, formatSwiftOnSave: true))
            let json = try jsonValue(String(decoding: try EngineJSON.encode(settings), as: UTF8.self))
            #expect(json == (try jsonValue("""
                {"autoUpdate": true, "claudePath": null, "claudeVMIdleMinutes": 10,
                 "defaultChatSettings": {"contextWindow": "auto", "effort": "high", "model": "default", "permissionMode": "manual",
                                         "ultracode": false},
                 "defaultVMCores": 2, "defaultVMDiskGB": 64, "defaultVMImage": null, "defaultVMMemoryGB": 4,
                 "formatGoOnSave": true, "formatSwiftOnSave": true, "mcpPort": 47830,
                 "notifyAISummary": true, "notifyFinished": true, "notifyNeedsYou": true, "schema": 1,
                 "showHephaestusProject": true, "skillsLibraryPath": null, "syncEnabled": true, "syncPort": 47821, "updateCheckIntervalMinutes": 30}
                """)))
        }
    }

    @Test("settings.update applies the present params, writes settings.yml and emits settings.updated")
    func settingsUpdateRoundTrip() async throws {
        try await withTestEngine { engine, connection, _ in
            let events = connection.events
            _ = try await connection.call(SettingsUpdate.self, .init(claudePath: .set("~/bin/claude"), mcpPort: 47830))
            let updated = try await connection.call(SettingsUpdate.self, .init(claudePath: .clear, syncEnabled: false))
            #expect(updated == HostSettings(mcpPort: 47830, syncEnabled: false))
            #expect(try await connection.call(SettingsGet.self) == updated)
            let stored = try ProjectFileStore.decodeYAML(HostSettings.self, at: engine.dataDirectory.settingsFile)
            #expect(stored == updated)
            let first = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: events))
            #expect(try first.payload(SettingsUpdatedEvent.self).claudePath == "~/bin/claude")
        }
    }

    @Test("Clearable params: an absent key keeps the value, null clears it")
    func clearableParams() async throws {
        try await withTestEngine { (engine, _, _) async throws in
            let actor = Actor.user(deviceID: engine.deviceID)
            func update(_ json: String) async throws -> HostSettings {
                let data = try await engine.dispatch(method: SettingsUpdate.name, params: Data(json.utf8), actor: actor)
                return try EngineJSON.decode(HostSettings.self, from: data)
            }
            #expect(try await update(#"{"claudePath": "/opt/homebrew/bin/claude"}"#).claudePath == "/opt/homebrew/bin/claude")
            #expect(try await update(#"{"mcpPort": 47830}"#).claudePath == "/opt/homebrew/bin/claude")
            #expect(try await update(#"{"claudePath": null}"#).claudePath == nil)
        }
    }

    @Test("showHephaestusProject round-trips and a feedbackProjectID of earlier versions stays as an unknown key")
    func showHephaestusProjectRoundTrip() async throws {
        try await withTestEngine(prepare: { directory in
            try Data("schema: 1\nfeedbackProjectID: HEPH\n".utf8).write(to: directory.settingsFile)
        }) { engine, connection, _ in
            #expect(try await connection.call(SettingsGet.self).showHephaestusProject)
            let updated = try await connection.call(SettingsUpdate.self, .init(showHephaestusProject: false))
            #expect(!updated.showHephaestusProject)
            let text = try String(contentsOf: engine.dataDirectory.settingsFile, encoding: .utf8)
            #expect(text.contains("showHephaestusProject: false"))
            #expect(text.contains("feedbackProjectID: HEPH"))
            let stored = try ProjectFileStore.decodeYAML(HostSettings.self, at: engine.dataDirectory.settingsFile)
            #expect(stored == updated)
            #expect(stored.unknownKeys["feedbackProjectID"] == .string("HEPH"))
            #expect(try await connection.call(SettingsUpdate.self, .init(showHephaestusProject: true)).showHephaestusProject)
        }
    }

    @Test("settings.update refuses values that break the HostSettings rules")
    func settingsUpdateErrors() async throws {
        try await withTestEngine { (engine, connection, _) async throws in
            func update(_ params: SettingsUpdate.Params) async -> EngineError? {
                await engineError { try await connection.call(SettingsUpdate.self, params) }
            }
            #expect(await update(.init(mcpPort: 80)) == EngineError(.invalid, "mcpPort: use a port from 1024 to 65535."))
            #expect(await update(.init(syncPort: HostSettings.defaultMCPPort))?.code == .invalid)
            #expect(await update(.init(updateCheckIntervalMinutes: 2))?.code == .invalid)
            #expect(await update(.init(claudePath: .set("claude")))?.code == .invalid)
            #expect(try await connection.call(SettingsGet.self) == HostSettings())
            #expect(try ProjectFileStore.decodeYAML(HostSettings.self, at: engine.dataDirectory.settingsFile) == HostSettings())
        }
    }

    @Test("A new skills library folder is created and skills.changed follows settings.updated")
    func skillsLibraryPath() async throws {
        try await withTestEngine { _, connection, folder in
            let library = folder.appendingPathComponent("Library/Skills", isDirectory: true)
            let events = connection.events
            _ = try await connection.call(SettingsUpdate.self, .init(skillsLibraryPath: .set(library.path)))
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: library.path, isDirectory: &isDirectory) && isDirectory.boolValue)
            let received = await firstElements(2, of: events)
            #expect(received.map(\.name) == [SettingsUpdatedEvent.name, SkillsChangedEvent.name])
            // The new folder gets the internal skills (docs/skills.md › Settings).
            #expect(try received.last?.payload(SkillsChangedEvent.self).map(\.name) == InternalSkills.names)
        }
    }
}
