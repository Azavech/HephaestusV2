import Foundation
import Network
import Testing
@testable import HephaestusCore

/// A method that completes when its test lets it.
private enum SlowMethod: EngineMethod {
    static let name = "test.slow"
    typealias Params = Empty
    typealias Result = Empty
}

/// The server side of the protocol, driven by a raw WebSocket client (docs/remote.md › Server
/// checks, › Request handling, › Event delivery, › Server connection states).
@Suite("Sync server")
struct SyncServerTests {
    private static let nonce = SyncCrypto.randomNonce().base64EncodedString()

    private func hello(deviceID: String = RandomIDs.uuidString(), deviceName: String = "MacBook", protocolVersion: String = "1") -> String {
        #"{"appVersion":"0.0.0","deviceID":"\#(deviceID)","deviceName":"\#(deviceName)","nonce":"\#(Self.nonce)","protocol":\#(protocolVersion),"type":"hello"}"#
    }

    /// Runs `body` with a started test engine and the port of its sync server.
    private func withServer(_ timings: SyncTimings = .fast, _ body: (Engine, Int) async throws -> Void) async throws {
        try await withTestEngine { engine, _, _ in
            await engine.syncServer.setTimings(timings)
            try await body(engine, try await syncPort(of: engine))
        }
    }

    @Test("The test server listens on 127.0.0.1 at a port chosen by the system")
    func listening() async throws {
        try await withServer { engine, port in
            #expect(port > 0)
            #expect(await engine.syncServer.status.sessions.isEmpty)
            let logText = try String(contentsOf: engine.dataDirectory.engineLogFile, encoding: .utf8)
            #expect(logText.contains("INFO sync: listening on port \(port)"))
        }
    }

    @Test("Hello checks close with their codes, without a reply")
    func helloChecks() async throws {
        try await withServer { engine, port in
            let cases: [(String, UInt16)] = [
                (hello(protocolVersion: "2"), 4001),
                (hello(deviceID: engine.deviceID), 4007),
                (hello(deviceID: engine.deviceID.lowercased()), 4007),
                (#"{"type":"auth","proof":"\#(Self.nonce)"}"#, 1002),
                ("not json", 1002),
                (hello(protocolVersion: #""1""#), 1002),
                (String(repeating: " ", count: 4_097 - 2) + "{}", 1009),
            ]
            for (text, code) in cases {
                let peer = RawPeer(port: port)
                #expect(await peer.waitReady())
                peer.sendText(text)
                #expect(await peer.closeCode() == code, "\(text.prefix(60))")
            }
            let binary = RawPeer(port: port)
            #expect(await binary.waitReady())
            binary.sendBinary(Data(hello().utf8))
            #expect(await binary.closeCode() == 1002)
            let logText = try String(contentsOf: engine.dataDirectory.engineLogFile, encoding: .utf8)
            #expect(logText.contains("WARN sync: handshake from 127.0.0.1:"))
            #expect(logText.contains("closed with 4001"))
        }
    }

    @Test("A wrong client proof closes with 4002; a malformed auth with 1002")
    func authChecks() async throws {
        try await withServer { _, port in
            for (auth, code) in [(#"{"type":"auth","proof":"\#(Self.nonce)"}"#, UInt16(4002)),
                                 (#"{"type":"auth","proof":"abc"}"#, 1002),
                                 (#"{"type":"hello"}"#, 1002)] {
                let peer = RawPeer(port: port)
                #expect(await peer.waitReady())
                peer.sendText(hello())
                guard case .text? = await peer.next() else {
                    Issue.record("no challenge")
                    continue
                }
                peer.sendText(auth)
                #expect(await peer.closeCode() == code)
            }
        }
    }

    @Test("A remote device is named by the deviceName of its last valid hello, authenticated or not")
    func deviceNameFromHello() async throws {
        try await withServer { engine, port in
            let deviceID = RandomIDs.uuidString()
            #expect(engine.syncServer.remoteDeviceName(deviceID: deviceID) == nil)
            #expect(await engine.userDeviceName(deviceID: deviceID) == deviceID)

            let refused = RawPeer(port: port)
            #expect(await refused.waitReady())
            refused.sendText(hello(deviceID: deviceID, deviceName: "Laptop"))
            guard case .text? = await refused.next() else {
                Issue.record("no challenge")
                return
            }
            #expect(engine.syncServer.remoteDeviceName(deviceID: deviceID) == "Laptop")
            #expect(await engine.userDeviceName(deviceID: deviceID) == "Laptop")
            refused.sendText(#"{"type":"auth","proof":"\#(Self.nonce)"}"#)
            #expect(await refused.closeCode() == 4002)
            #expect(engine.syncServer.remoteDeviceName(deviceID: deviceID) == "Laptop")

            // A hello that fails a check names nothing.
            let invalid = RawPeer(port: port)
            #expect(await invalid.waitReady())
            invalid.sendText(hello(deviceID: deviceID, deviceName: "Other", protocolVersion: "2"))
            #expect(await invalid.closeCode() == 4001)
            #expect(engine.syncServer.remoteDeviceName(deviceID: deviceID.lowercased()) == "Laptop")

            let session = RawPeer(port: port)
            _ = try await session.clientHandshake(code: await engine.syncServer.pairingCode, deviceID: deviceID.lowercased(), deviceName: "Desk")
            #expect(engine.syncServer.remoteDeviceName(deviceID: deviceID) == "Desk")
        }
    }

    @Test("Handshake deadlines close with 4006")
    func deadlines() async throws {
        var timings = SyncTimings.fast
        timings.helloDeadline = 0.3
        timings.authDeadline = 0.3
        try await withServer(timings) { _, port in
            let silent = RawPeer(port: port)
            #expect(await silent.waitReady())
            #expect(await silent.closeCode() == 4006)

            let noAuth = RawPeer(port: port)
            #expect(await noAuth.waitReady())
            noAuth.sendText(hello())
            guard case .text? = await noAuth.next() else {
                Issue.record("no challenge")
                return
            }
            #expect(await noAuth.closeCode() == 4006)
        }
    }

    @Test("A session: requests, frame checks and unknown messages")
    func session() async throws {
        try await withServer { engine, port in
            let code = await engine.syncServer.pairingCode
            let peer = RawPeer(port: port)
            var session = try await peer.clientHandshake(code: code)
            #expect(session.welcome.device == (await engine.localDeviceInfo()))
            #expect(try EngineJSON.decode(Snapshot.self, from: session.welcome.snapshot).device.id == engine.deviceID)

            // A request without params, then an unknown type, which is ignored.
            let first = try session.sealer.seal(Data(#"{"id":1,"method":"settings.get","type":"request"}"#.utf8))
            peer.sendBinary(first)
            guard case .binary(let answer)? = await peer.next() else {
                Issue.record("no response")
                return
            }
            let response = String(decoding: try session.opener.open(answer), as: UTF8.self)
            #expect(response.hasPrefix(#"{"id":1,"result":{"autoUpdate":"#))
            peer.sendBinary(try session.sealer.seal(Data(#"{"type":"greeting"}"#.utf8)))
            peer.sendBinary(try session.sealer.seal(Data(#"{"id":2,"method":"nope.nope","params":null,"type":"request"}"#.utf8)))
            guard case .binary(let unknown)? = await peer.next() else {
                Issue.record("no response")
                return
            }
            #expect(String(decoding: try session.opener.open(unknown), as: UTF8.self)
                == #"{"error":{"code":"notFound","message":"Unknown method nope.nope."},"id":2,"type":"response"}"#)
            let logText = try String(contentsOf: engine.dataDirectory.engineLogFile, encoding: .utf8)
            #expect(logText.contains("WARN sync: ignored message type greeting from "))

            // The first frame again: unexpected counter.
            peer.sendBinary(first)
            #expect(await peer.closeCode() == 4005)
            #expect(await eventually { await engine.syncServer.status.sessions.isEmpty })
        }
    }

    @Test("Frame and message failures in a session: 4004, 1002 for text and bad requests")
    func sessionFailures() async throws {
        try await withServer { engine, port in
            let code = await engine.syncServer.pairingCode
            let tampered = RawPeer(port: port)
            var session = try await tampered.clientHandshake(code: code)
            var frame = try session.sealer.seal(Data(#"{"id":1,"method":"settings.get","type":"request"}"#.utf8))
            frame[frame.count - 1] ^= 1
            tampered.sendBinary(frame)
            #expect(await tampered.closeCode() == 4004)

            let text = RawPeer(port: port)
            _ = try await text.clientHandshake(code: code)
            text.sendText(#"{"id":1,"method":"settings.get","type":"request"}"#)
            #expect(await text.closeCode() == 1002)

            let badParams = RawPeer(port: port)
            var third = try await badParams.clientHandshake(code: code)
            badParams.sendBinary(try third.sealer.seal(Data(#"{"id":1,"method":"settings.get","params":[1],"type":"request"}"#.utf8)))
            #expect(await badParams.closeCode() == 1002)

            let short = RawPeer(port: port)
            _ = try await short.clientHandshake(code: code)
            short.sendBinary(Data(count: 20))
            #expect(await short.closeCode() == 4004)
        }
    }

    /// Requests that complete at once are answered in the order they started; 16 sessions run
    /// side by side so that requests started out of order would show.
    @Test("Requests start in the order they are received, without waiting for the previous ones", arguments: 0..<16)
    func requestOrder(session index: Int) async throws {
        try await withServer { engine, port in
            let release = Collected<Bool>()
            await engine.register(SlowMethod.self, actors: [.user]) { _, _ in
                while release.values.isEmpty {
                    try await Task.sleep(for: .milliseconds(10))
                }
                return Empty()
            }
            let peer = RawPeer(port: port)
            var session = try await peer.clientHandshake(code: await engine.syncServer.pairingCode)
            let count = 300
            var frames = [try session.sealer.seal(Data(#"{"id":1,"method":"test.slow","type":"request"}"#.utf8))]
            for id in 2...count {
                frames.append(try session.sealer.seal(Data(#"{"id":\#(id),"method":"nope.nope","type":"request"}"#.utf8)))
            }
            peer.socket.queue.async {
                for frame in frames {
                    peer.socket.sendBinary(frame)
                }
            }
            var ids: [Int] = []
            while ids.count < count, case .binary(let frame)? = await peer.next() {
                let object = try #require(SyncMessageCheck.jsonObject(try session.opener.open(frame)))
                if case .int(let id)? = object["id"] {
                    ids.append(id)
                }
                if ids.count == count - 1 {
                    release.append(true)
                }
            }
            #expect(ids == Array(2...count) + [1])
        }
    }

    @Test("Events emitted while a request is handled are sent before its response")
    func eventsBeforeResponse() async throws {
        try await withServer { engine, port in
            let peer = RawPeer(port: port)
            var session = try await peer.clientHandshake(code: await engine.syncServer.pairingCode)
            peer.sendBinary(try session.sealer.seal(Data(#"{"id":1,"method":"settings.update","params":{"autoUpdate":false},"type":"request"}"#.utf8)))
            guard case .binary(let firstFrame)? = await peer.next(), case .binary(let secondFrame)? = await peer.next() else {
                Issue.record("missing frames")
                return
            }
            let first = try #require(SyncMessageCheck.jsonObject(try session.opener.open(firstFrame)))
            let second = try #require(SyncMessageCheck.jsonObject(try session.opener.open(secondFrame)))
            #expect(first["type"] == "event")
            #expect(first["event"]?.objectValue?["name"] == "settings.updated")
            #expect(second["type"] == "response")
            #expect(second["id"] == 1)
        }
    }

    @Test("Events reach every open session in emission order")
    func eventDelivery() async throws {
        try await withServer { engine, port in
            let code = await engine.syncServer.pairingCode
            let a = RawPeer(port: port)
            var sessionA = try await a.clientHandshake(code: code)
            let b = RawPeer(port: port)
            var sessionB = try await b.clientHandshake(code: code)
            for minutes in [10, 20, 30] {
                var params = SettingsUpdate.Params()
                params.updateCheckIntervalMinutes = minutes
                _ = try await engine.call(SettingsUpdate.self, params, actor: .system)
            }
            for (peer, index) in [(a, 0), (b, 1)] {
                var received: [Int] = []
                while received.count < 3, case .binary(let frame)? = await peer.next() {
                    let plaintext = index == 0 ? try sessionA.opener.open(frame) : try sessionB.opener.open(frame)
                    let object = try #require(SyncMessageCheck.jsonObject(plaintext))
                    let data = object["event"]?.objectValue?["data"]?.objectValue
                    if case .int(let value)? = data?["updateCheckIntervalMinutes"] {
                        received.append(value)
                    }
                }
                #expect(received == [10, 20, 30])
            }
        }
    }

    @Test("Regenerate also closes handshakes in progress with 4003")
    func regenerateHandshakes() async throws {
        try await withServer { engine, port in
            let peer = RawPeer(port: port)
            #expect(await peer.waitReady())
            peer.sendText(hello())
            guard case .text? = await peer.next() else {
                Issue.record("no challenge")
                return
            }
            try await engine.syncServer.regeneratePairingCode()
            #expect(await peer.closeCode() == 4003)
        }
    }

    @Test("A port in use: 5 attempts in the app, then failed with the system's text")
    func bindFailure() async throws {
        try await withServer { engine, port in
            await engine.syncServer.stop()
            #expect(port > 0)
            // Another listener holds a port: the server cannot bind it.
            let occupied = try await FakeSyncServer()
            defer { occupied.stop() }
            await engine.syncServer.start(port: occupied.port, interface: .loopback, advertises: false, deviceName: "Studio", engine: engine)
            #expect(await engine.syncServer.status.state == .failed(message: "Address already in use"))
            let logText = try String(contentsOf: engine.dataDirectory.engineLogFile, encoding: .utf8)
            #expect(logText.contains("ERROR sync: listener failed on port \(occupied.port): Address already in use"))
            #expect(SyncTimings.standard.bindAttempts == 5)
            #expect(SyncTimings.standard.bindRetryDelay == 1)
        }
    }

    @Test("The Bonjour TXT record and the truncations of docs/remote.md › Advertising")
    func advertising() {
        let txt = SyncServer.txtRecord(deviceID: "9d7e2f4a-1b3c-4d5e-8f60-718293a4b5c6", name: "Studio")
        #expect(NWTXTRecord(txt).dictionary == ["id": "9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6", "name": "Studio", "proto": "1"])
        #expect(txt == Data("\u{27}id=9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6\u{0B}name=Studio\u{07}proto=1".utf8))
        #expect(SyncServer.serviceType == "_hephaestus2._tcp")
        #expect(SyncServer.truncated(String(repeating: "é", count: 40), toUTF8Bytes: 63) == String(repeating: "é", count: 31))
        #expect(SyncServer.truncated("Studio", toUTF8Bytes: 63) == "Studio")
        let long = SyncServer.txtRecord(deviceID: "9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6", name: String(repeating: "a", count: 300))
        #expect(long.count == 40 + 256 + 8)
        #expect(long[40] == 255)
    }
}
