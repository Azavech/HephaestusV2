import Foundation
import Testing
@testable import HephaestusCore

/// docs/remote.md › JSON encoding, › Server checks, › Client checks, › Session messages.
@Suite("Sync messages")
struct SyncMessageTests {
    static let nonce = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    static let ownID = "9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6"

    private func hello(_ fields: [String: String]) -> Data {
        var object: [String: String] = [
            "type": #""hello""#, "protocol": "1", "deviceID": #""6b1d3f0a-5c2e-4e8b-9a7d-2f4c6e8a0b1c""#,
            "deviceName": #""MacBook""#, "appVersion": #""0.4.0""#, "nonce": "\"\(Self.nonce)\"",
        ]
        for (key, value) in fields {
            object[key] = value.isEmpty ? nil : value
        }
        let body = object.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return Data("{\(body)}".utf8)
    }

    private func helloCheck(_ fields: [String: String]) -> SyncCloseCode? {
        if case .failure(let code) = SyncMessageCheck.hello(hello(fields), ownDeviceID: Self.ownID) { return code }
        return nil
    }

    @Test("A valid hello: the device id in any case is kept uppercase")
    func validHello() throws {
        guard case .success(let values) = SyncMessageCheck.hello(hello([:]), ownDeviceID: Self.ownID) else {
            Issue.record("hello refused")
            return
        }
        #expect(values.deviceID == "6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C")
        #expect(values.deviceName == "MacBook")
        #expect(values.appVersion == "0.4.0")
        #expect(values.nonce.count == 32)
    }

    @Test("Hello checks in the order of docs/remote.md › Server checks")
    func helloChecks() {
        #expect(helloCheck(["type": #""auth""#]) == .protocolError)
        #expect(helloCheck(["protocol": #""1""#]) == .protocolError)
        #expect(helloCheck(["protocol": ""]) == .protocolError)
        #expect(helloCheck(["protocol": "2"]) == .unsupportedProtocol)
        // protocol is checked before the other fields.
        #expect(helloCheck(["protocol": "2", "deviceID": "3", "nonce": ""]) == .unsupportedProtocol)
        #expect(helloCheck(["deviceID": #""not-a-uuid""#]) == .protocolError)
        #expect(helloCheck(["deviceName": #""""#]) == .protocolError)
        #expect(helloCheck(["deviceName": "7"]) == .protocolError)
        #expect(helloCheck(["appVersion": ""]) == .protocolError)
        #expect(helloCheck(["nonce": #""AAEC""#]) == .protocolError)
        #expect(helloCheck(["deviceID": "\"\(Self.ownID.lowercased())\""]) == .sameDevice)
        // A malformed nonce is checked before the own device id.
        #expect(helloCheck(["deviceID": "\"\(Self.ownID)\"", "nonce": #""x""#]) == .protocolError)
        #expect(SyncMessageCheck.hello(Data("[1]".utf8), ownDeviceID: Self.ownID).failureCode == .protocolError)
        #expect(SyncMessageCheck.hello(Data("not json".utf8), ownDeviceID: Self.ownID).failureCode == .protocolError)
    }

    @Test("Auth and challenge checks")
    func authAndChallenge() {
        #expect(SyncMessageCheck.auth(Data(#"{"type":"auth","proof":"\#(Self.nonce)"}"#.utf8)).failureCode == nil)
        #expect(SyncMessageCheck.auth(Data(#"{"type":"auth"}"#.utf8)).failureCode == .protocolError)
        #expect(SyncMessageCheck.auth(Data(#"{"type":"hello","proof":"\#(Self.nonce)"}"#.utf8)).failureCode == .protocolError)
        #expect(SyncMessageCheck.challenge(Data(#"{"type":"challenge","nonce":"\#(Self.nonce)","proof":"\#(Self.nonce)"}"#.utf8)).failureCode == nil)
        #expect(SyncMessageCheck.challenge(Data(#"{"type":"challenge","nonce":"\#(Self.nonce)"}"#.utf8)).failureCode == .protocolError)
    }

    @Test("Requests: id range, method and params")
    func requests() throws {
        func input(_ text: String) -> Result<SyncMessageCheck.ServerInput, SyncCloseCode> {
            SyncMessageCheck.serverInput(Data(text.utf8))
        }
        #expect(try input(#"{"type":"request","id":1,"method":"settings.get"}"#).get()
            == .request(id: 1, method: "settings.get", params: Data("{}".utf8)))
        #expect(try input(#"{"type":"request","id":2,"method":"settings.get","params":null}"#).get()
            == .request(id: 2, method: "settings.get", params: Data("{}".utf8)))
        #expect(try input(#"{"type":"request","id":9007199254740991,"method":"a.b","params":{"b":1,"a":"x/y"}}"#).get()
            == .request(id: 9_007_199_254_740_991, method: "a.b", params: Data(#"{"a":"x/y","b":1}"#.utf8)))
        #expect(input(#"{"type":"request","id":0,"method":"a.b"}"#).failureCode == .protocolError)
        #expect(input(#"{"type":"request","id":9007199254740992,"method":"a.b"}"#).failureCode == .protocolError)
        #expect(input(#"{"type":"request","id":"1","method":"a.b"}"#).failureCode == .protocolError)
        #expect(input(#"{"type":"request","method":"a.b"}"#).failureCode == .protocolError)
        #expect(input(#"{"type":"request","id":1,"method":3}"#).failureCode == .protocolError)
        #expect(input(#"{"type":"request","id":1,"method":"a.b","params":[1]}"#).failureCode == .protocolError)
        #expect(input(#"{"type":"request","id":1,"method":"a.b","params":"x"}"#).failureCode == .protocolError)
        #expect(try input(#"{"type":"response","id":1,"result":{}}"#).get() == .ignored(type: "response"))
        #expect(try input(#"{"type":"whatever"}"#).get() == .ignored(type: "whatever"))
        #expect(input(#"{"id":1}"#).failureCode == .protocolError)
        #expect(input("[]").failureCode == .protocolError)
    }

    @Test("Responses carry exactly one of result and error; events decode")
    func clientInputs() throws {
        func input(_ text: String) -> Result<SyncMessageCheck.ClientInput, SyncCloseCode> {
            SyncMessageCheck.clientInput(Data(text.utf8))
        }
        #expect(try input(#"{"type":"response","id":1,"result":{}}"#).get() == .response(id: 1, outcome: .success(.object([:]))))
        #expect(try input(#"{"type":"response","id":1,"result":null}"#).get() == .response(id: 1, outcome: .success(.null)))
        #expect(try input(#"{"type":"response","id":3,"error":{"code":"forbidden","message":"This tab is locked."}}"#).get()
            == .response(id: 3, outcome: .failure(EngineError(.forbidden, "This tab is locked."))))
        #expect(input(#"{"type":"response","id":1}"#).failureCode == .protocolError)
        #expect(input(#"{"type":"response","id":1,"result":{},"error":{"code":"internal","message":"x"}}"#).failureCode == .protocolError)
        #expect(input(#"{"type":"response","id":1,"error":{"code":"nope","message":"x"}}"#).failureCode == .protocolError)
        let event = #"{"event":{"data":{"projectID":"HEPH","ticketID":"HEPH-12"},"name":"ticket.deleted","origin":{"actor":"user","deviceID":"6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C"}},"type":"event"}"#
        guard case .event(let envelope) = try input(event).get() else {
            Issue.record("not an event")
            return
        }
        #expect(envelope.name == "ticket.deleted")
        #expect(envelope.origin == .user(deviceID: "6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C"))
        #expect(input(#"{"type":"event","event":{"name":"x"}}"#).failureCode == .protocolError)
        #expect(try input(#"{"type":"request","id":1,"method":"a.b"}"#).get() == .ignored(type: "request"))
    }

    @Test("Messages built from encoded bytes equal the Codable encoding")
    func builtBytes() throws {
        let envelope = try EngineJSON.encode(EngineEventEnvelope(name: "ticket.deleted", origin: .system,
                                                                 data: ["projectID": "HEPH", "ticketID": "HEPH-12"]))
        let built = SyncMessageBytes.event(envelope: envelope)
        let encoded = try SyncMessage.event(.init(event: try EngineJSON.decode(JSONValue.self, from: envelope))).encoded()
        #expect(built == encoded)

        let result = try EngineJSON.encode(["b": 2, "a": 1] as JSONValue)
        #expect(SyncMessageBytes.response(id: 7, result: result)
            == (try SyncMessage.response(.init(id: 7, result: ["a": 1, "b": 2])).encoded()))
        #expect(String(decoding: try SyncMessageBytes.response(id: 3, error: EngineError(.forbidden, "This tab is locked.")), as: UTF8.self)
            == #"{"error":{"code":"forbidden","message":"This tab is locked."},"id":3,"type":"response"}"#)
        let params = try EngineJSON.encode(["projectID": "HEPH", "tabID": "7C9E6679-7425-40DE-944B-E07FC1F90AE7"] as JSONValue)
        #expect(try SyncMessageBytes.request(id: 3, method: "webTabs.close", params: params)
            == (try SyncMessage.request(.init(id: 3, method: "webTabs.close", params: try EngineJSON.decode(JSONValue.self, from: params))).encoded()))
    }

    @Test("SyncMessage decodes every type and round-trips")
    func roundTrip() throws {
        let messages: [SyncMessage] = [
            .hello(.init(deviceID: "6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C", deviceName: "MacBook", appVersion: "0.4.0", nonce: Self.nonce)),
            .challenge(.init(nonce: Self.nonce, proof: Self.nonce)),
            .auth(.init(proof: Self.nonce)),
            .welcome(.init(device: DeviceInfo(id: Self.ownID, name: "Studio", appVersion: "0.4.0", build: 57), snapshot: ["projects": []])),
            .request(.init(id: 1, method: "settings.get", params: [:])),
            .response(.init(id: 1, result: [:])),
            .response(.init(id: 2, error: EngineError(.notFound, "Unknown method x.y."))),
            .event(.init(event: ["name": "skills.changed", "origin": ["actor": "system"], "data": []])),
        ]
        for message in messages {
            let data = try message.encoded()
            #expect(try EngineJSON.decode(SyncMessage.self, from: data) == message, "\(String(decoding: data, as: UTF8.self))")
            #expect(SyncMessageCheck.jsonObject(data)?["type"] == .string(message.type))
        }
        // An absent or null params decodes as {}.
        let request = try EngineJSON.decode(SyncMessage.self, from: Data(#"{"type":"request","id":4,"method":"a.b","params":null}"#.utf8))
        #expect(request == .request(.init(id: 4, method: "a.b", params: [:])))
        #expect(throws: (any Error).self) { try EngineJSON.decode(SyncMessage.self, from: Data(#"{"type":"bye"}"#.utf8)) }
    }

    @Test("Close codes and their Network.framework form")
    func closeCodes() {
        #expect(SyncCloseCode.allCases.map(\.rawValue) == [1000, 1001, 1002, 1009, 1011, 4001, 4002, 4003, 4004, 4005, 4006, 4007, 4008, 4009])
        for code in SyncCloseCode.allCases {
            #expect(SyncCloseCode.number(of: code.webSocketCode) == code.rawValue)
        }
    }

    @Test("The failure messages and phases of docs/remote.md › Messages")
    func failureMessages() {
        let name = "Studio"
        #expect(SyncFailure.received(4002).phase(name: name, nextAttempt: nil)
            == .needsPairing(message: "The pairing code for Studio is not correct. Choose Add Device\u{2026} and enter the code shown in Settings > Devices on Studio."))
        #expect(SyncFailure.received(4003).phase(name: name, nextAttempt: nil)
            == .needsPairing(message: "Studio has a new pairing code. Choose Add Device\u{2026} and enter the code shown in Settings > Devices on Studio."))
        #expect(SyncFailure.received(4003).sheetMessage(name: name) == "The pairing code is not correct.")
        #expect(SyncFailure.received(4002).sheetMessage(name: name) == "The pairing code is not correct.")
        #expect(SyncFailure.received(4007).phase(name: name, nextAttempt: nil) == .sameDevice(message: "This address belongs to this Mac."))
        #expect(SyncFailure.received(4008).phase(name: name, nextAttempt: nil) == .replaced(message: "This Mac opened a newer connection to Studio."))
        #expect(SyncFailure.received(4001).message(name: name) == "Studio uses another version of the sync protocol. Update HephaestusV2 on both Macs.")
        #expect(SyncFailure.received(4006).message(name: name) == "Studio did not answer.")
        #expect(SyncFailure.received(1001).message(name: name) == "Studio stopped accepting remote devices.")
        #expect(SyncFailure.received(1006).message(name: name) == "The connection to Studio was lost.")
        for code: UInt16 in [1002, 1009, 1011, 4004, 4005, 4009, 1000, 3000] {
            #expect(SyncFailure.received(code).message(name: name) == "The connection to Studio failed (code \(code)).")
            #expect(SyncFailure.received(code).retries)
        }
        #expect(SyncFailure.noStoredCode.message(name: name)
            == "There is no pairing code for Studio. Choose Add Device\u{2026} and enter the code shown in Settings > Devices on Studio.")
        #expect(SyncFailure.connecting(.posix(.ECONNREFUSED), path: nil, host: "studio.local").message(name: name)
            == "Studio is not accepting connections. Check that remote devices are allowed in Settings > Devices on Studio.")
        for code: POSIXErrorCode in [.ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN] {
            #expect(SyncFailure.connecting(.posix(code), path: nil, host: "studio.local").message(name: name) == "Can't reach Studio.")
        }
        #expect(SyncFailure.connecting(.dns(-65554), path: nil, host: "studio.local").message(name: name) == "Can't find studio.local.")
        #expect(SyncFailure.connecting(.dns(-65570), path: nil, host: "studio.local").message(name: name)
            == "HephaestusV2 is not allowed to use the local network. Allow it in System Settings > Privacy & Security > Local Network.")
        #expect(SyncFailure.anotherDevice(address: "127.0.0.1:47821").message(name: name) == "Another device answered at 127.0.0.1:47821.")
        #expect(SyncFailure.sent(.authenticationFailed) == .wrongCode)
        #expect(SyncFailure.sent(.handshakeTimeout) == .handshakeTimeout)
        #expect(SyncFailure.sent(.decryptionFailed) == .protocolFailure(code: 4004))
    }

    @Test("Backoff: 1, 2, 4, 8, 16, 30 s, then 30 s")
    func backoff() {
        let timings = SyncTimings.standard
        #expect((1...9).map { timings.backoffDelay(after: $0) } == [1, 2, 4, 8, 16, 30, 30, 30, 30])
    }

    @Test("Addresses: host:port, IPv6 in brackets, ws URLs")
    func addresses() {
        #expect(SyncAddress.display(host: "studio.local", port: 47821) == "studio.local:47821")
        #expect(SyncAddress.display(host: "2001:db8::5", port: 47821) == "[2001:db8::5]:47821")
        #expect(SyncAddress.webSocketURL(host: "192.168.1.20", port: 47821)?.absoluteString == "ws://192.168.1.20:47821/")
        #expect(SyncAddress.webSocketURL(host: "::1", port: 8080)?.absoluteString == "ws://[::1]:8080/")
        let hostPort = SyncAddress.hostPort(of: .hostPort(host: "127.0.0.1", port: 5000))
        #expect(hostPort?.host == "127.0.0.1")
        #expect(hostPort?.port == 5000)
    }
}

extension Result {
    /// The failure, or nil on success.
    var failureCode: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
