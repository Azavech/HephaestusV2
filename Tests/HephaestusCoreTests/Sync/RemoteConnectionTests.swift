import Foundation
import Network
import Testing
@testable import HephaestusCore

/// The client side of the protocol against a scripted server (docs/remote.md › Client checks,
/// › Client state machine, › Keepalive, › Messages).
@Suite("Remote engine connection")
struct RemoteConnectionTests {
    static let mainID = "9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6"
    static let mainInfo = DeviceInfo(id: mainID, name: "Studio", appVersion: "0.4.0", build: 57)

    /// A remote engine paired with a fake main device on `server`, and its connection.
    private func withPairedConnection(server: FakeSyncServer, code: PairingCode, timings: SyncTimings = .fast,
                                      _ body: (RemoteEngineConnection, Engine, MemoryLog) async throws -> Void) async throws {
        try await withTestEngine { remote, _, _ in
            let device = try storePairing(on: remote, deviceID: Self.mainID, port: server.port, code: code)
            let log = MemoryLog()
            let connection = RemoteEngineConnection(device: device, local: await remote.localDeviceInfo(), pairedDevices: remote.pairedDevices,
                                                    browser: remote.deviceBrowser, log: log, timings: timings)
            defer { connection.close() }
            try await body(connection, remote, log)
        }
    }

    private var script: RawPeer.ServerScript {
        RawPeer.ServerScript(code: SyncCryptoTests.code, device: Self.mainInfo)
    }

    @Test("Phases of a successful connection, then responses matched by id and events")
    func connectAndCall() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        try await withPairedConnection(server: server, code: SyncCryptoTests.code) { connection, _, _ in
            let phases = connection.phaseUpdates
            let peer = try #require(await server.nextPeer())
            var keys = try await peer.serverHandshake(script, snapshot: fakeSnapshot(device: Self.mainInfo))
            let seen = await firstElements(4, of: phases)
            #expect(seen == [.connecting, .helloSent, .authSent, .connected])
            #expect(connection.deviceInfo == Self.mainInfo)

            // Two calls answered in the other order.
            async let first = connection.call(SettingsGet.self)
            async let second = connection.call(DeviceInfoMethod.self)
            var requests: [Int: String] = [:]
            for _ in 0..<2 {
                guard case .binary(let frame)? = await peer.next() else { throw SyncTestError("no request") }
                let object = try #require(SyncMessageCheck.jsonObject(try keys.opener.open(frame)))
                guard case .int(let id)? = object["id"], case .string(let method)? = object["method"] else { throw SyncTestError("bad request") }
                #expect(object["params"] == [:])
                requests[id] = method
            }
            #expect(Set(requests.keys) == [1, 2])
            let infoID = try #require(requests.first { $0.value == "device.info" }?.key)
            let settingsID = try #require(requests.first { $0.value == "settings.get" }?.key)
            peer.sendBinary(try keys.sealer.seal(SyncMessageBytes.response(id: infoID, result: try EngineJSON.encode(Self.mainInfo))))
            peer.sendBinary(try keys.sealer.seal(SyncMessageBytes.response(id: settingsID, result: try EngineJSON.encode(HostSettings()))))
            #expect(try await second == Self.mainInfo)
            #expect(try await first == HostSettings())

            // An error response, a result that does not decode, an unknown event name, an event.
            let events = connection.events
            #expect(try await connection.call(SnapshotGet.self).device == Self.mainInfo)
            async let failing = engineError { try await connection.call(SettingsGet.self) }
            guard case .binary(let third)? = await peer.next() else { throw SyncTestError("no request") }
            _ = try keys.opener.open(third)
            peer.sendBinary(try keys.sealer.seal(try SyncMessageBytes.response(id: 3, error: EngineError(.forbidden, "No."))))
            #expect(await failing == EngineError(.forbidden, "No."))
            async let unexpected = engineError { try await connection.call(SettingsGet.self) }
            guard case .binary(let fourth)? = await peer.next() else { throw SyncTestError("no request") }
            _ = try keys.opener.open(fourth)
            peer.sendBinary(try keys.sealer.seal(SyncMessageBytes.response(id: 4, result: Data("[]".utf8))))
            #expect(await unexpected == EngineError(.internal, "Unexpected result for settings.get."))
            let unknownEvent = EngineEventEnvelope(name: "future.event", origin: .system, data: [:])
            peer.sendBinary(try keys.sealer.seal(SyncMessageBytes.event(envelope: try EngineJSON.encode(unknownEvent))))
            let known = EngineEventEnvelope(name: SkillsChangedEvent.name, origin: .system, data: [])
            peer.sendBinary(try keys.sealer.seal(SyncMessageBytes.event(envelope: try EngineJSON.encode(known))))
            #expect(await firstElement(of: events) == known)
            #expect(connection.phase == .connected)
        }
    }

    @Test("A server proof made with another code: close 4002 without auth, needsPairing")
    func wrongServerProof() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        let otherCode = try #require(PairingCode(userInput: "7H0K-4XQ2-M91D-TZ5D"))
        try await withPairedConnection(server: server, code: otherCode) { connection, _, _ in
            let peer = try #require(await server.nextPeer())
            _ = try await peer.answerHello(script)
            #expect(await peer.closeCode() == 4002)
            let phase = await phase(of: connection) { if case .needsPairing = $0 { return true } else { return false } }
            #expect(phase == .needsPairing(message:
                "The pairing code for Studio is not correct. Choose Add Device\u{2026} and enter the code shown in Settings > Devices on Studio."))
            #expect(connection.nextAttempt == nil)
        }
    }

    @Test("A URL-safe base64 proof: close 1002, waiting with the protocol failure message")
    func urlSafeProof() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        try await withPairedConnection(server: server, code: SyncCryptoTests.code) { connection, _, _ in
            let phases = connection.phaseUpdates
            let peer = try #require(await server.nextPeer())
            var script = self.script
            script.proofText = "cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J_qEiE="
            _ = try await peer.answerHello(script)
            #expect(await peer.closeCode() == 1002)
            let phase = await firstElement(of: phases) { $0.isWaiting }
            #expect(phase?.message == "The connection to Studio failed (code 1002).")
            #expect(phase?.nextAttempt != nil)
        }
    }

    @Test("A challenge larger than 4,096 bytes: close 1009, waiting with the protocol failure message")
    func oversizedChallenge() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        try await withPairedConnection(server: server, code: SyncCryptoTests.code) { connection, _, _ in
            let phases = connection.phaseUpdates
            let peer = try #require(await server.nextPeer())
            guard case .text? = await peer.next() else { throw SyncTestError("no hello") }
            peer.sendText(String(repeating: " ", count: 4_097 - 2) + "{}")
            #expect(await peer.closeCode() == 1009)
            let phase = await firstElement(of: phases) { $0.isWaiting }
            #expect(phase?.message == "The connection to Studio failed (code 1009).")
        }
    }

    @Test("A welcome from another device: close 1000, waiting")
    func anotherDevice() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        try await withPairedConnection(server: server, code: SyncCryptoTests.code) { connection, _, _ in
            let phases = connection.phaseUpdates
            let peer = try #require(await server.nextPeer())
            var script = self.script
            script.device = DeviceInfo(id: "6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C", name: "Other", appVersion: "0.4.0", build: 1)
            _ = try await peer.serverHandshake(script, snapshot: fakeSnapshot(device: script.device))
            #expect(await peer.closeCode() == 1000)
            let phase = await firstElement(of: phases) { $0.isWaiting }
            #expect(phase?.message == "Another device answered at 127.0.0.1:\(server.port).")
            #expect(connection.deviceInfo == nil)
        }
    }

    @Test("No challenge within the deadline: close 4006, the device did not answer")
    func challengeTimeout() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        var timings = SyncTimings.fast
        timings.challengeDeadline = 0.3
        try await withPairedConnection(server: server, code: SyncCryptoTests.code, timings: timings) { connection, _, log in
            let phases = connection.phaseUpdates
            let peer = try #require(await server.nextPeer())
            guard case .text? = await peer.next() else { throw SyncTestError("no hello") }
            #expect(await peer.closeCode() == 4006)
            let phase = await firstElement(of: phases) { $0.isWaiting }
            #expect(phase?.message == "Studio did not answer.")
            #expect(log.entries.map(\.message).contains("connection to Studio ended, code 4006; next attempt in 0.1 s"))
        }
    }

    @Test("Close codes received during the handshake: 4001, 4007")
    func handshakeCloses() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        try await withPairedConnection(server: server, code: SyncCryptoTests.code) { connection, _, _ in
            let phases = connection.phaseUpdates
            let peer = try #require(await server.nextPeer())
            guard case .text? = await peer.next() else { throw SyncTestError("no hello") }
            peer.close(.unsupportedProtocol)
            let incompatible = await firstElement(of: phases) { $0.isWaiting }
            #expect(incompatible?.message == "Studio uses another version of the sync protocol. Update HephaestusV2 on both Macs.")
            let retry = try #require(await server.nextPeer())
            guard case .text? = await retry.next() else { throw SyncTestError("no hello") }
            retry.close(.sameDevice)
            let same = await phase(of: connection) { if case .sameDevice = $0 { return true } else { return false } }
            #expect(same == .sameDevice(message: "This address belongs to this Mac."))
            #expect(connection.nextAttempt == nil)
            // Reconnect Now resets the backoff and tries again.
            connection.reconnectNow()
            #expect(await server.nextPeer() != nil)
        }
    }

    @Test("A malformed response closes with 1002 and fails the pending call")
    func malformedResponse() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        try await withPairedConnection(server: server, code: SyncCryptoTests.code) { connection, _, _ in
            let peer = try #require(await server.nextPeer())
            var keys = try await peer.serverHandshake(script, snapshot: fakeSnapshot(device: Self.mainInfo))
            #expect(await phase(of: connection) { $0 == .connected } == .connected)
            let phases = connection.phaseUpdates
            async let call = engineError { try await connection.call(SettingsGet.self) }
            guard case .binary(let frame)? = await peer.next() else { throw SyncTestError("no request") }
            _ = try keys.opener.open(frame)
            peer.sendBinary(try keys.sealer.seal(Data(#"{"error":{"code":"internal","message":"x"},"id":1,"result":{},"type":"response"}"#.utf8)))
            #expect(await call == EngineError(.unavailable, "Not connected to Studio."))
            #expect(await peer.closeCode() == 1002)
            #expect(await firstElement(of: phases) { $0.isWaiting }?.message == "The connection to Studio failed (code 1002).")
        }
    }

    @Test("A replayed s2c frame closes with 4005; a text frame after auth with 1002")
    func frameChecks() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        try await withPairedConnection(server: server, code: SyncCryptoTests.code) { connection, _, _ in
            let peer = try #require(await server.nextPeer())
            var keys = try await peer.serverHandshake(script, snapshot: fakeSnapshot(device: Self.mainInfo))
            #expect(await phase(of: connection) { $0 == .connected } == .connected)
            let envelope = EngineEventEnvelope(name: SkillsChangedEvent.name, origin: .system, data: [])
            let event = try keys.sealer.seal(SyncMessageBytes.event(envelope: try EngineJSON.encode(envelope)))
            peer.sendBinary(event)
            peer.sendBinary(event)
            #expect(await peer.closeCode() == 4005)

            let retry = try #require(await server.nextPeer(timeout: waitLimit))
            _ = try await retry.serverHandshake(script, snapshot: fakeSnapshot(device: Self.mainInfo))
            #expect(await phase(of: connection) { $0 == .connected } == .connected)
            retry.sendText(#"{"type":"event"}"#)
            #expect(await retry.closeCode() == 1002)
        }
    }

    @Test("Held events are discarded when the connection is lost before snapshot.get")
    func heldEventsDiscarded() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        try await withPairedConnection(server: server, code: SyncCryptoTests.code) { connection, _, _ in
            let events = connection.events
            let peer = try #require(await server.nextPeer())
            var keys = try await peer.serverHandshake(script, snapshot: fakeSnapshot(device: Self.mainInfo))
            #expect(await phase(of: connection) { $0 == .connected } == .connected)
            let lost = EngineEventEnvelope(name: SkillsChangedEvent.name, origin: .system, data: [])
            peer.sendBinary(try keys.sealer.seal(SyncMessageBytes.event(envelope: try EngineJSON.encode(lost))))
            try await Task.sleep(for: .milliseconds(100))
            let phases = connection.phaseUpdates
            peer.cancel()
            #expect(await firstElement(of: phases) { $0.isWaiting }?.message == "The connection to Studio was lost.")

            let retry = try #require(await server.nextPeer(timeout: waitLimit))
            var retryKeys = try await retry.serverHandshake(script, snapshot: fakeSnapshot(device: Self.mainInfo))
            #expect(await phase(of: connection) { $0 == .connected } == .connected)
            let kept = EngineEventEnvelope(name: SettingsUpdatedEvent.name, origin: .system, data: try EngineJSON.jsonValue(HostSettings()))
            retry.sendBinary(try retryKeys.sealer.seal(SyncMessageBytes.event(envelope: try EngineJSON.encode(kept))))
            try await Task.sleep(for: .milliseconds(100))
            _ = try await connection.call(SnapshotGet.self)
            #expect(await firstElement(of: events) == kept)
        }
    }

    @Test("Held events are yielded in their order once the first snapshot.get returned")
    func heldEventsAfterSnapshot() async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        try await withPairedConnection(server: server, code: SyncCryptoTests.code) { connection, _, _ in
            let peer = try #require(await server.nextPeer())
            var keys = try await peer.serverHandshake(script, snapshot: fakeSnapshot(device: Self.mainInfo))
            #expect(await phase(of: connection) { $0 == .connected } == .connected)
            let order = Collected<String>()
            let events = connection.events
            let consumer = Task {
                for await envelope in events {
                    order.append(envelope.name)
                }
            }
            defer { consumer.cancel() }
            let held = [EngineEventEnvelope(name: SkillsChangedEvent.name, origin: .system, data: []),
                        EngineEventEnvelope(name: SettingsUpdatedEvent.name, origin: .system, data: try EngineJSON.jsonValue(HostSettings()))]
            for envelope in held {
                peer.sendBinary(try keys.sealer.seal(SyncMessageBytes.event(envelope: try EngineJSON.encode(envelope))))
            }
            // A response sent after the events: once its call returned, the client has them.
            async let settings = connection.call(SettingsGet.self)
            guard case .binary(let frame)? = await peer.next(timeout: waitLimit) else { throw SyncTestError("no request") }
            guard case .int(let id)? = try #require(SyncMessageCheck.jsonObject(try keys.opener.open(frame)))["id"] else {
                throw SyncTestError("bad request")
            }
            peer.sendBinary(try keys.sealer.seal(SyncMessageBytes.response(id: id, result: try EngineJSON.encode(HostSettings()))))
            #expect(try await settings == HostSettings())
            #expect(order.values.isEmpty)

            #expect(try await connection.call(SnapshotGet.self).device == Self.mainInfo)
            #expect(await eventually(timeout: waitLimit) { order.values.count == held.count })
            #expect(order.values == [SkillsChangedEvent.name, SettingsUpdatedEvent.name])
        }
    }

    @Test("A server that answers no ping: the client cancels after the silence limit")
    func clientSilence() async throws {
        let server = try await FakeSyncServer(autoReplyPing: false)
        defer { server.stop() }
        var timings = SyncTimings.fast
        timings.pingInterval = 0.2
        timings.clientSilence = 0.6
        try await withPairedConnection(server: server, code: SyncCryptoTests.code, timings: timings) { connection, _, _ in
            // Recorded before the welcome: the session lasts 0.6 s, less than a loaded machine can
            // take to look at it.
            let recorder = PhaseRecorder(connection)
            let peer = try #require(await server.nextPeer())
            _ = try await peer.serverHandshake(script, snapshot: fakeSnapshot(device: Self.mainInfo))
            #expect(await eventually(timeout: waitLimit) { recorder.phases(from: { $0 == .connected }).contains { $0.isWaiting } })
            let lost = recorder.phases(from: { $0 == .connected }).first { $0.isWaiting }
            #expect(lost?.message == "The connection to Studio was lost.")
            // Cancelled without a close frame.
            #expect(await peer.closeCode() == SyncCloseCode.abnormalClosure)
        }
    }

    @Test("No WebSocket upgrade within the connect timeout: the device cannot be reached")
    func connectTimeout() async throws {
        // A TCP listener that accepts and never answers the upgrade request.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        let held = Collected<NWConnection>()
        listener.newConnectionHandler = { connection in
            held.append(connection)
            connection.start(queue: .global())
        }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnceThrowing(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(Int(listener.port!.rawValue)))
                case .failed(let error): once.resume(.failure(error))
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.tcp"))
        }
        defer {
            listener.cancel()
            held.values.forEach { $0.cancel() }
        }
        // A connect timeout of 3 s leaves a loaded machine time to accept the TCP connection first.
        var timings = SyncTimings.fast
        timings.connect = 3
        try await withTestEngine { remote, _, _ in
            let device = try storePairing(on: remote, deviceID: Self.mainID, port: port, code: SyncCryptoTests.code)
            let connection = RemoteEngineConnection(device: device, local: await remote.localDeviceInfo(), pairedDevices: remote.pairedDevices,
                                                    browser: remote.deviceBrowser, log: MemoryLog(), timings: timings)
            defer { connection.close() }
            let phase = await phase(of: connection, timeout: waitLimit) { $0.isWaiting }
            #expect(phase?.message == "Can't reach Studio.")
            #expect(!held.values.isEmpty)
        }
    }

    @Test("Add Device attempts: a typed address is saved, cancelling closes with 1000, a refusal fails")
    func addDeviceAttempts() async throws {
        // Outside the ephemeral range, so that no other test's listener takes the port once the
        // server stops.
        let server = try await withUnusedTestPort { try await FakeSyncServer(port: $0) }
        defer { server.stop() }
        try await withTestEngine { remote, _, _ in
            let local = await remote.localDeviceInfo()
            // A typed address: any device id is accepted, and the record is saved.
            async let added = RemoteEngineConnection.attempt(.address(host: "127.0.0.1", port: server.port), code: SyncCryptoTests.code,
                                                             local: local, pairedDevices: remote.pairedDevices, browser: remote.deviceBrowser,
                                                             log: MemoryLog(), timings: .fast)
            let peer = try #require(await server.nextPeer())
            _ = try await peer.serverHandshake(script, snapshot: fakeSnapshot(device: Self.mainInfo))
            let connection = try await added
            defer { connection.close() }
            #expect(connection.phase == .connected)
            #expect(remote.pairedDevices.devices.map(\.id.uuidString) == [Self.mainID])
            #expect(remote.pairedDevices.code(forDeviceID: Self.mainID) == SyncCryptoTests.code)

            // Cancelling an attempt in progress.
            let task = Task {
                try await RemoteEngineConnection.attempt(.address(host: "127.0.0.1", port: server.port), code: SyncCryptoTests.code,
                                                         local: local, pairedDevices: remote.pairedDevices, browser: remote.deviceBrowser,
                                                         log: MemoryLog(), timings: .fast)
            }
            let waiting = try #require(await server.nextPeer())
            guard case .text? = await waiting.next() else { throw SyncTestError("no hello") }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(await waiting.closeCode() == 1000)

            // Nothing listens: the sheet shows the refusal and nothing more is saved.
            server.stop()
            #expect(await eventually(timeout: waitLimit) { await refusesConnections(port: server.port) })
            await #expect(throws: AddDeviceFailure(message:
                "127.0.0.1:\(server.port) is not accepting connections. Check that remote devices are allowed in Settings > Devices on 127.0.0.1:\(server.port).")) {
                _ = try await RemoteEngineConnection.attempt(.address(host: "127.0.0.1", port: server.port), code: SyncCryptoTests.code,
                                                             local: local, pairedDevices: remote.pairedDevices, browser: remote.deviceBrowser,
                                                             log: MemoryLog(), timings: .fast)
            }
            #expect(remote.pairedDevices.devices.count == 1)
        }
    }

    @Test("An attempt that fails before any connection still logs its start")
    func attemptLoggedAtStart() async throws {
        try await withTestEngine { remote, _, _ in
            let log = MemoryLog()
            // No ws:// URL can be made for this host: the attempt fails before connecting.
            await #expect(throws: AddDeviceFailure(message: "Can't find [.")) {
                _ = try await RemoteEngineConnection.attempt(.address(host: "[", port: 1), code: SyncCryptoTests.code,
                                                             local: await remote.localDeviceInfo(), pairedDevices: remote.pairedDevices,
                                                             browser: remote.deviceBrowser, log: log, timings: .fast)
            }
            #expect(log.entries.map(\.message) == ["connecting to [:1 at [:1", "connection to [:1 ended, code 1006"])
        }
    }
}
