import Foundation
import Testing
@testable import HephaestusCore

/// A method that no engine registers.
private enum UnknownMethod: EngineMethod {
    static let name = "nope.nope"
    typealias Params = Empty
    typealias Result = Empty
}

/// A method that returns more than 32 MiB of JSON.
private enum HugeResult: EngineMethod {
    static let name = "test.huge"
    typealias Params = Empty
    typealias Result = String
}

/// An event whose payload is larger than 32 MiB.
private enum HugeEvent: EngineEvent {
    static let name = SkillsChangedEvent.name
    typealias Payload = String
}

/// Two engines on 127.0.0.1: the remote one pairs with the main one and works through a
/// `RemoteEngineConnection` (docs/remote.md, docs/development.md › Test targets).
@Suite("Sync loopback")
struct SyncLoopbackTests {
    @Test("Add Device: the welcome saves the record and its code, and the attempt becomes the connection")
    func pairing() async throws {
        try await withTwoEngines { main, _, remote, log in
            let connection = try await pair(remote, with: main, log: log)
            defer { connection.close() }
            let port = try await syncPort(of: main)
            #expect(connection.phase == .connected)
            #expect(connection.state == .connected)
            #expect(connection.deviceInfo == (await main.localDeviceInfo()))
            #expect(connection.device.name == "Studio")
            #expect(connection.device.id.uuidString == main.deviceID)

            let record = try #require(remote.pairedDevices.devices.first)
            #expect(remote.pairedDevices.devices.count == 1)
            #expect(record.id.uuidString == main.deviceID)
            #expect(record.name == "Studio")
            #expect(record.host == "127.0.0.1")
            #expect(record.port == port)
            #expect(record.lastConnected != nil)
            #expect(remote.pairedDevices.code(forDeviceID: main.deviceID) == (await main.syncServer.pairingCode))
            // Written to the files of the data directory.
            let files = try DeviceFileStore.loadAll(remote.dataDirectory, log: nil)
            #expect(files.remotes.remotes == remote.pairedDevices.devices)
            #expect(files.secrets.remoteSecrets[main.deviceID] == (await main.syncServer.pairingCode).display)

            // The main device lists the session.
            #expect(await eventually { await main.syncServer.status.sessions.count == 1 })
            let session = try #require(await main.syncServer.status.sessions.first)
            #expect(session.deviceID == remote.deviceID)
            #expect(session.deviceName == "MacBook")
            #expect(session.appVersion == "0.0.0")
            #expect(session.remoteAddress.hasPrefix("127.0.0.1:"))
            #expect(main.syncServer.remoteDeviceName(deviceID: remote.deviceID) == "MacBook")
            #expect(await main.userDeviceName(deviceID: remote.deviceID) == "MacBook")
            #expect(await main.userDeviceName(deviceID: main.deviceID) == "Studio")

            let lines = log.entries.map(\.message)
            #expect(lines.contains("connecting to 127.0.0.1:\(port) at 127.0.0.1:\(port)"))
            #expect(lines.contains("connected to Studio"))
            #expect(log.entries.allSatisfy { $0.component == .sync })
        }
    }

    @Test("A remote call runs exactly like a local one, with the user actor of the remote device")
    func remoteCalls() async throws {
        try await withTwoEngines { main, mainLocal, remote, _ in
            let connection = try await pair(remote, with: main)
            defer { connection.close() }
            #expect(try await connection.call(SettingsGet.self) == (try await mainLocal.call(SettingsGet.self)))
            #expect(try await connection.call(DeviceInfoMethod.self) == (try await mainLocal.call(DeviceInfoMethod.self)))

            // Dispatcher errors are the same.
            let remoteUnknown = await engineError { try await connection.call(UnknownMethod.self) }
            let localUnknown = await engineError { try await mainLocal.call(UnknownMethod.self) }
            #expect(remoteUnknown == EngineError(.notFound, "Unknown method nope.nope."))
            #expect(remoteUnknown == localUnknown)
            var invalid = SettingsUpdate.Params()
            invalid.mcpPort = 80
            let remoteInvalid = await engineError { try await connection.call(SettingsUpdate.self, invalid) }
            let localInvalid = await engineError { try await mainLocal.call(SettingsUpdate.self, invalid) }
            #expect(remoteInvalid?.code == .invalid)
            #expect(remoteInvalid == localInvalid)

            // A mutation: the event reaches every connection with the remote device's user actor.
            let localEvents = mainLocal.events
            _ = try await connection.call(SnapshotGet.self)
            let remoteEvents = connection.events
            var change = SettingsUpdate.Params()
            change.updateCheckIntervalMinutes = 45
            let updated = try await connection.call(SettingsUpdate.self, change)
            #expect(updated.updateCheckIntervalMinutes == 45)
            let local = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: localEvents))
            #expect(local.origin == .user(deviceID: remote.deviceID))
            let remoteEvent = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: remoteEvents))
            #expect(remoteEvent == local)
            #expect(try remoteEvent.payload(SettingsUpdatedEvent.self).updateCheckIntervalMinutes == 45)
        }
    }

    @Test("The first snapshot.get after a welcome is the welcome's snapshot; events wait for it")
    func welcomeSnapshot() async throws {
        try await withTwoEngines { main, mainLocal, remote, _ in
            let connection = try await pair(remote, with: main)
            defer { connection.close() }
            let probe = connection.events
            var change = SettingsUpdate.Params()
            change.updateCheckIntervalMinutes = 60
            _ = try await mainLocal.call(SettingsUpdate.self, change)
            // Held until the first snapshot.get returns.
            #expect(await firstElement(of: probe, timeout: .milliseconds(400)) == nil)
            let events = connection.events
            let kept = try await connection.call(SnapshotGet.self)
            #expect(kept.device == (await main.localDeviceInfo()))
            #expect(kept.settings.updateCheckIntervalMinutes == 30)
            let event = try #require(await firstEvent(named: SettingsUpdatedEvent.name, on: events))
            #expect(event.origin == .user(deviceID: main.deviceID))
            // The next snapshot.get reaches the main device.
            let current = try await connection.call(SnapshotGet.self)
            #expect(current.settings.updateCheckIntervalMinutes == 60)
        }
    }

    @Test("A wrong pairing code fails the attempt with the sheet's message and saves nothing")
    func wrongCode() async throws {
        try await withTwoEngines { main, _, remote, _ in
            var other = PairingCode.generate()
            while other == (await main.syncServer.pairingCode) {
                other = PairingCode.generate()
            }
            await #expect(throws: AddDeviceFailure(message: "The pairing code is not correct.")) {
                _ = try await pair(remote, with: main, code: other)
            }
            #expect(remote.pairedDevices.devices.isEmpty)
            #expect(remote.secrets.current.remoteSecrets.isEmpty)
            #expect(await main.syncServer.status.sessions.isEmpty)
        }
    }

    @Test("Connecting to this Mac's own address: close 4007")
    func sameDevice() async throws {
        try await withTwoEngines { _, _, remote, _ in
            await #expect(throws: AddDeviceFailure(message: "This address belongs to this Mac.")) {
                _ = try await pair(remote, with: remote)
            }
            #expect(remote.pairedDevices.devices.isEmpty)
        }
    }

    @Test("Regenerate closes every connection with 4003; the new code pairs again")
    func regenerate() async throws {
        try await withTwoEngines { main, _, remote, _ in
            let connection = try await pair(remote, with: main)
            defer { connection.close() }
            let code = try await main.syncServer.regeneratePairingCode()
            #expect(await main.syncServer.pairingCode == code)
            let needsPairing = await phase(of: connection) { if case .needsPairing = $0 { return true } else { return false } }
            #expect(needsPairing == .needsPairing(message:
                "Studio has a new pairing code. Choose Add Device\u{2026} and enter the code shown in Settings > Devices on Studio."))
            #expect(connection.state == .disconnected(reason: needsPairing?.message ?? ""))
            #expect(connection.nextAttempt == nil)
            #expect(await eventually { await main.syncServer.status.sessions.isEmpty })
            // Reconnect Now retries with the stored (old) code: 4002 from this side.
            connection.reconnectNow()
            let refused = await phase(of: connection) { $0.message?.hasPrefix("The pairing code for Studio") == true }
            #expect(refused != nil)
            let again = try await pair(remote, with: main, code: code)
            defer { again.close() }
            #expect(again.phase == .connected)
            #expect(remote.pairedDevices.devices.count == 1)
            #expect(remote.pairedDevices.code(forDeviceID: main.deviceID) == code)
        }
    }

    @Test("A newer session of the same device closes the older one with 4008")
    func replaced() async throws {
        try await withTwoEngines { main, _, remote, _ in
            let first = try await pair(remote, with: main)
            defer { first.close() }
            let second = try await pair(remote, with: main)
            defer { second.close() }
            let phase = await phase(of: first) { if case .replaced = $0 { return true } else { return false } }
            #expect(phase == .replaced(message: "This Mac opened a newer connection to Studio."))
            #expect(second.phase == .connected)
            #expect(await eventually { await main.syncServer.status.sessions.count == 1 })
            // Pairing again keeps the record's place and does not add one.
            #expect(remote.pairedDevices.devices.count == 1)
        }
    }

    @Test("The server stops (1001), refuses, then a retry reconnects with the backoff")
    func serverStopsAndRestarts() async throws {
        try await withTwoEngines { main, mainLocal, remote, log in
            // A port outside the ephemeral range, so that no other test's listener takes it
            // while the stopped server leaves it unused.
            await main.syncServer.start(port: try unusedTestPort(), interface: .loopback, advertises: false,
                                        deviceName: "Studio", engine: main)
            let connection = try await pair(remote, with: main, log: log)
            defer { connection.close() }
            _ = try await connection.call(SnapshotGet.self)
            // Watched from before the stop: the phase lasts 0.1 s, until the next attempt.
            let phases = connection.phaseUpdates
            var off = SettingsUpdate.Params()
            off.syncEnabled = false
            _ = try await mainLocal.call(SettingsUpdate.self, off)
            #expect(await main.syncServer.status == SyncServerStatus())
            let stopped = await firstElement(of: phases) { $0.message == "Studio stopped accepting remote devices." }
            #expect(stopped?.nextAttempt != nil)
            #expect(stopped?.connectionState == .disconnected(reason: "Studio stopped accepting remote devices."))
            let refused = await phase(of: connection) { $0.message?.contains("is not accepting connections") == true }
            #expect(refused?.message == "Studio is not accepting connections. Check that remote devices are allowed in Settings > Devices on Studio.")
            // Calls fail at once while not connected.
            #expect(await engineError { try await connection.call(SettingsGet.self) } == EngineError(.unavailable, "Not connected to Studio."))

            var on = SettingsUpdate.Params()
            on.syncEnabled = true
            _ = try await mainLocal.call(SettingsUpdate.self, on)
            // Port 0 gives a new port: the record follows it, as a new pairing would.
            let port = try await syncPort(of: main)
            let record = try #require(remote.pairedDevices.devices.first)
            try remote.pairedDevices.save(RemoteDevice(id: record.id, name: record.name, host: "127.0.0.1", port: port),
                                          code: try #require(remote.pairedDevices.code(forDeviceID: main.deviceID)))
            #expect(await phase(of: connection, timeout: waitLimit) { $0 == .connected } == .connected)
            #expect(try await connection.call(SnapshotGet.self).device.id == main.deviceID)
            let lines = log.entries.map(\.message)
            #expect(lines.contains("connection to Studio ended, code 1001; next attempt in 0.1 s"))
            #expect(lines.contains { $0.hasPrefix("connection to Studio ended, code 1006; next attempt in 0.2 s") })
        }
    }

    @Test("A silent session is cancelled by the server; the client reconnects")
    func serverSilence() async throws {
        try await withTwoEngines { main, _, remote, _ in
            var server = SyncTimings.fast
            server.serverSilence = 0.6
            await main.syncServer.setTimings(server)
            let device = try storePairing(on: remote, deviceID: main.deviceID, port: try await syncPort(of: main),
                                          code: await main.syncServer.pairingCode)
            var client = SyncTimings.fast
            client.pingInterval = 30
            let connection = RemoteEngineConnection(device: device, local: await remote.localDeviceInfo(), pairedDevices: remote.pairedDevices,
                                                    browser: remote.deviceBrowser, log: MemoryLog(), timings: client)
            defer { connection.close() }
            // Recorded from the start: the first session lasts 0.6 s, less than a loaded machine
            // can take to look at it.
            let recorder = PhaseRecorder(connection)
            #expect(await eventually(timeout: waitLimit) { recorder.phases.contains(.connected) })
            // The sessions accepted from now on stay open, so that a call can reach one.
            await main.syncServer.setTimings(.fast)
            #expect(await eventually(timeout: waitLimit) { recorder.phases(from: { $0 == .connected }).contains { $0.isWaiting } })
            let lost = recorder.phases(from: { $0 == .connected }).first { $0.isWaiting }
            #expect(lost?.message == "The connection to Studio was lost.")
            // A session accepted before the timings changed can be cancelled before the call
            // reaches it; the client then reconnects once more.
            #expect(await eventually(timeout: waitLimit) { (try? await connection.call(SnapshotGet.self))?.device.name == "Studio" })
        }
    }

    @Test("Pings keep a session alive past the server's silence limit")
    func keepalive() async throws {
        try await withTwoEngines { main, _, remote, _ in
            // A ping every 0.25 s against a silence limit of 3 s leaves a loaded machine 2.75 s to
            // deliver one. The session is watched for longer than the limit.
            var server = SyncTimings.fast
            server.serverSilence = 3
            await main.syncServer.setTimings(server)
            let connection = try await pair(remote, with: main)
            defer { connection.close() }
            let phases = await elements(of: connection.phaseUpdates, during: .seconds(4))
            #expect(phases == [.connected])
            #expect(connection.phase == .connected)
            #expect(await main.syncServer.status.sessions.count == 1)
        }
    }

    @Test("Closing by the app: 1000, phase closed, streams finish, calls fail")
    func closeByApp() async throws {
        try await withTwoEngines { main, _, remote, _ in
            let connection = try await pair(remote, with: main)
            let states = connection.stateUpdates
            let events = connection.events
            #expect(await eventually { await main.syncServer.status.sessions.count == 1 })
            connection.close()
            #expect(connection.phase == .closed)
            #expect(connection.state == .disconnected(reason: "Closed."))
            #expect(await firstElements(3, of: states).count == 2)
            #expect(await firstElement(of: events) == nil)
            #expect(await engineError { try await connection.call(SettingsGet.self) } == EngineError(.unavailable, "Not connected to Studio."))
            #expect(await eventually { await main.syncServer.status.sessions.isEmpty })
            connection.reconnectNow()
            try await Task.sleep(for: .milliseconds(200))
            #expect(connection.phase == .closed)
            let logText = try String(contentsOf: main.dataDirectory.engineLogFile, encoding: .utf8)
            #expect(logText.contains("INFO sync: MacBook (\(remote.deviceID)) connected from 127.0.0.1:"))
            #expect(logText.contains("INFO sync: MacBook (\(remote.deviceID)) disconnected, code 1000"))
        }
    }

    @Test("A paired device without a stored code starts in needsPairing; Reconnect Now keeps it")
    func noStoredCode() async throws {
        try await withTwoEngines { main, _, remote, _ in
            let device = try storePairing(on: remote, deviceID: main.deviceID, port: try await syncPort(of: main), code: nil)
            let connection = RemoteEngineConnection(device: device, local: await remote.localDeviceInfo(), pairedDevices: remote.pairedDevices,
                                                    browser: remote.deviceBrowser, log: MemoryLog(), timings: .fast)
            defer { connection.close() }
            let message = "There is no pairing code for Studio. Choose Add Device\u{2026} and enter the code shown in Settings > Devices on Studio."
            #expect(connection.phase == .needsPairing(message: message))
            connection.reconnectNow()
            try await Task.sleep(for: .milliseconds(200))
            #expect(connection.phase == .needsPairing(message: message))
            #expect(await main.syncServer.status.sessions.isEmpty)
        }
    }

    @Test("A paired device with its code connects on creation and updates its record at the welcome")
    func pairedConnection() async throws {
        try await withTwoEngines { main, _, remote, _ in
            let code = await main.syncServer.pairingCode
            let device = try storePairing(on: remote, deviceID: main.deviceID, name: "Old name", port: try await syncPort(of: main), code: code)
            let connection = RemoteEngineConnection(device: device, local: await remote.localDeviceInfo(), pairedDevices: remote.pairedDevices,
                                                    browser: remote.deviceBrowser, log: MemoryLog(), timings: .fast)
            defer { connection.close() }
            #expect(await phase(of: connection) { $0 == .connected } == .connected)
            #expect(remote.pairedDevices.devices.first?.name == "Studio")
            #expect(remote.pairedDevices.devices.first?.lastConnected != nil)
            #expect(connection.device.name == "Studio")
        }
    }

    @Test("A request larger than 32 MB is not sent")
    func oversizedRequest() async throws {
        try await withTwoEngines { main, _, remote, _ in
            let connection = try await pair(remote, with: main)
            defer { connection.close() }
            var huge = SettingsUpdate.Params()
            huge.claudePath = .set("/" + String(repeating: "a", count: 33_554_432))
            #expect(await engineError { try await connection.call(SettingsUpdate.self, huge) }
                == EngineError(.invalid, "The request is larger than 32 MB."))
            #expect(connection.phase == .connected)
            #expect(try await connection.call(SettingsGet.self).claudePath == nil)
        }
    }

    @Test("Responses and events over 32 MiB are not sent to remote devices")
    func oversizedOutput() async throws {
        try await withTwoEngines { main, mainLocal, remote, _ in
            await main.register(HugeResult.self, actors: [.user]) { _, _ in String(repeating: "a", count: 33_554_432) }
            let connection = try await pair(remote, with: main)
            defer { connection.close() }
            #expect(await engineError { try await connection.call(HugeResult.self) }
                == EngineError(.unavailable, "The result of test.huge is larger than 32 MB and cannot be sent to a remote device."))

            _ = try await connection.call(SnapshotGet.self)
            let remoteEvents = connection.events
            let localEvents = mainLocal.events
            await main.emit(HugeEvent.self, String(repeating: "b", count: 33_554_432), origin: .system)
            await main.emit(SkillsChangedEvent.self, [], origin: .system)
            // Other events of the engines' background work may come first. The 32 MiB event
            // takes a debug build a while to encode and decode.
            let remoteEvent = try #require(await firstElement(of: remoteEvents, timeout: waitLimit) { $0.name == SkillsChangedEvent.name })
            #expect(remoteEvent.data == [])
            let local = try #require(await firstElement(of: localEvents, timeout: waitLimit) { $0.name == SkillsChangedEvent.name })
            #expect(local.data.stringValue?.count == 33_554_432)
            let logText = try String(contentsOf: main.dataDirectory.engineLogFile, encoding: .utf8)
            #expect(logText.contains("WARN sync: event skills.changed of 33554520 bytes not sent to \(remote.deviceID)"))
            #expect(connection.phase == .connected)
        }
    }

    @Test("The device name: renaming changes the hello of later connections")
    func renaming() async throws {
        try await withTwoEngines { main, _, remote, _ in
            try await remote.renameDevice(to: "  Laptop  ")
            #expect(await remote.localDeviceInfo().name == "Laptop")
            let connection = try await pair(remote, with: main)
            defer { connection.close() }
            #expect(main.syncServer.remoteDeviceName(deviceID: remote.deviceID) == "Laptop")
            #expect(await eventually { await main.syncServer.status.sessions.first?.deviceName == "Laptop" })
        }
    }
}
