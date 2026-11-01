import CryptoKit
import Foundation
import Testing
@testable import HephaestusCore

/// The values of docs/remote.md › Worked example, reproduced exactly.
@Suite("Sync crypto vectors")
struct SyncCryptoTests {
    static let code = PairingCode(userInput: "7h0k 4xq2-m9ld tz5c")!
    static let nc = Data((0x00..<0x20).map { UInt8($0) })
    static let ns = Data((0x20..<0x40).map { UInt8($0) })
    static let clientID = "6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C"
    static let serverID = "9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6"

    static var key: SymmetricKey { SyncCrypto.pairingKey(code: code) }

    @Test("Inputs: normalized code, code bytes and nonces in base64")
    func inputs() {
        #expect(Self.code.normalized == "7H0K4XQ2M91DTZ5C")
        #expect(Self.code.display == "7H0K-4XQ2-M91D-TZ5C")
        #expect(hex(Data(Self.code.normalized.utf8)) == "3748304b345851324d393144545a3543")
        #expect(hex(Self.nc) == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        #expect(Self.nc.base64EncodedString() == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
        #expect(Self.ns.base64EncodedString() == "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=")
    }

    @Test("K, the proofs and the session keys")
    func derivedValues() {
        let key = Self.key
        #expect(hex(key) == "dffc53ef75ca2d84369e02d4c4c0d44a486d1c50ee9379409867952663353607")
        #expect(hex(SyncCrypto.serverLabel + Self.nc + Self.ns)
            == "736572766572000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
        let serverProof = SyncCrypto.serverProof(key: key, clientNonce: Self.nc, serverNonce: Self.ns)
        #expect(hex(serverProof) == "710a6498231725691589b0e14956213ab003bae1e9aabdee7d0b47d09fea1221")
        #expect(serverProof.base64EncodedString() == "cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J/qEiE=")
        #expect(hex(SyncCrypto.clientLabel + Self.nc + Self.ns)
            == "636c69656e74000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
        let clientProof = SyncCrypto.clientProof(key: key, clientNonce: Self.nc, serverNonce: Self.ns)
        #expect(hex(clientProof) == "dada68020eb881f7366092e486eb92e28625dc63951ba281eb106b49e0c3ac23")
        #expect(clientProof.base64EncodedString() == "2tpoAg64gfc2YJLkhuuS4oYl3GOVG6KB6xBrSeDDrCM=")
        let keys = SyncCrypto.sessionKeys(key: key, clientNonce: Self.nc, serverNonce: Self.ns)
        #expect(hex(keys.c2s) == "1944025e521f6b9807f9cd06bfd89dadfab329cf9228b62d84fff4548c98ea5c")
        #expect(hex(keys.s2c) == "b3f9caf68c6ebaa06e18f2503f39395b41c3dfaa09316422107e8de2ee7d91a1")
        #expect(SyncCrypto.isValidServerProof(serverProof, key: key, clientNonce: Self.nc, serverNonce: Self.ns))
        #expect(SyncCrypto.isValidClientProof(clientProof, key: key, clientNonce: Self.nc, serverNonce: Self.ns))
        #expect(!SyncCrypto.isValidClientProof(serverProof, key: key, clientNonce: Self.nc, serverNonce: Self.ns))
    }

    @Test("The handshake frames as EngineJSON writes them")
    func handshakeFrames() throws {
        let hello = SyncMessage.hello(.init(deviceID: Self.clientID, deviceName: "MacBook", appVersion: "0.4.0",
                                            nonce: Self.nc.base64EncodedString()))
        #expect(String(decoding: try hello.encoded(), as: UTF8.self)
            == #"{"appVersion":"0.4.0","deviceID":"6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C","deviceName":"MacBook","nonce":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","protocol":1,"type":"hello"}"#)
        let serverProof = SyncCrypto.serverProof(key: Self.key, clientNonce: Self.nc, serverNonce: Self.ns)
        let challenge = SyncMessage.challenge(.init(nonce: Self.ns.base64EncodedString(), proof: serverProof.base64EncodedString()))
        #expect(String(decoding: try challenge.encoded(), as: UTF8.self)
            == #"{"nonce":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=","proof":"cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J/qEiE=","type":"challenge"}"#)
        let clientProof = SyncCrypto.clientProof(key: Self.key, clientNonce: Self.nc, serverNonce: Self.ns)
        let auth = SyncMessage.auth(.init(proof: clientProof.base64EncodedString()))
        #expect(String(decoding: try auth.encoded(), as: UTF8.self) == #"{"proof":"2tpoAg64gfc2YJLkhuuS4oYl3GOVG6KB6xBrSeDDrCM=","type":"auth"}"#)
    }

    static let c2sPlaintext = #"{"id":1,"method":"chats.interrupt","params":{"chatID":"3F2504E0-4F89-11D3-9A0C-0305E82C3301"},"type":"request"}"#
    static let c2sFrame = "0000000000000000000000004d3e91efdf8a47d32b1bbf5845937f4fe3c85ea0f01fb09cbcf5fd4d5870a30bcca59e0f837a93975be061fa28090853c9fe13b709197cd1b74a69a09b08b7c2bd198572a87b86f2fd3a3a74f13910cd68b1f6bb9f1c6e3e557f6194e2d05c008f1c53b863c8eb739d62a31cebef7333c7ee2a06ea7478f357229db6ac35a1"
    static let s2cPlaintext = #"{"id":1,"result":{},"type":"response"}"#
    static let s2cFrame = "00000000000000000000000156067e70412b54e510ad3f01681acc0a26b64ab9c6763a0b4b1b6950212b5d3de460919ec024bbc80aa4ba8c396b322802fa303443c3"

    @Test("The encrypted frames c2s #0 and s2c #1")
    func encryptedFrames() throws {
        let keys = SyncCrypto.sessionKeys(key: Self.key, clientNonce: Self.nc, serverNonce: Self.ns)
        #expect(Self.c2sPlaintext.utf8.count == 111)
        #expect(Self.s2cPlaintext.utf8.count == 38)

        var clientSealer = FrameSealer(key: keys.c2s)
        let c2s = try clientSealer.seal(Data(Self.c2sPlaintext.utf8))
        #expect(c2s.count == 139)
        #expect(hex(c2s) == Self.c2sFrame)
        #expect(hex(c2s.prefix(12)) == "000000000000000000000000")
        #expect(hex(c2s.dropFirst(12).dropLast(16))
            == "4d3e91efdf8a47d32b1bbf5845937f4fe3c85ea0f01fb09cbcf5fd4d5870a30bcca59e0f837a93975be061fa28090853c9fe13b709197cd1b74a69a09b08b7c2bd198572a87b86f2fd3a3a74f13910cd68b1f6bb9f1c6e3e557f6194e2d05c008f1c53b863c8eb739d62a31cebef73")
        #expect(hex(c2s.suffix(16)) == "33c7ee2a06ea7478f357229db6ac35a1")
        #expect(clientSealer.nextCounter == 1)

        var serverSealer = FrameSealer(key: keys.s2c, firstCounter: 1)
        let s2c = try serverSealer.seal(Data(Self.s2cPlaintext.utf8))
        #expect(s2c.count == 66)
        #expect(hex(s2c) == Self.s2cFrame)
        #expect(hex(s2c.prefix(12)) == "000000000000000000000001")
        #expect(hex(s2c.dropFirst(12).dropLast(16)) == "56067e70412b54e510ad3f01681acc0a26b64ab9c6763a0b4b1b6950212b5d3de460919ec024")
        #expect(hex(s2c.suffix(16)) == "bbc80aa4ba8c396b322802fa303443c3")

        // The request bytes the client builds, and the response bytes the server builds.
        let params = try EngineJSON.encode(ChatsInterrupt.Params(chatID: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!))
        #expect(String(decoding: try SyncMessageBytes.request(id: 1, method: "chats.interrupt", params: params), as: UTF8.self) == Self.c2sPlaintext)
        #expect(String(decoding: SyncMessageBytes.response(id: 1, result: try EngineJSON.encode(Empty())), as: UTF8.self) == Self.s2cPlaintext)

        var serverOpener = FrameOpener(key: keys.c2s)
        #expect(String(decoding: try serverOpener.open(c2s), as: UTF8.self) == Self.c2sPlaintext)
        var clientOpener = FrameOpener(key: keys.s2c, firstCounter: 1)
        #expect(String(decoding: try clientOpener.open(s2c), as: UTF8.self) == Self.s2cPlaintext)
    }

    @Test("Negative cases of the worked example")
    func negativeCases() throws {
        // A client holding the code 7H0K-4XQ2-M91D-TZ5D.
        let otherKey = SyncCrypto.pairingKey(code: try #require(PairingCode(userInput: "7H0K-4XQ2-M91D-TZ5D")))
        let expected = SyncCrypto.serverProof(key: otherKey, clientNonce: Self.nc, serverNonce: Self.ns)
        #expect(expected.base64EncodedString() == "PoxHaveY2Kyz0eGe7vXsZ47Pn5+3omOpNsKn8FRwldI=")
        let received = try #require(SyncCrypto.decodeBase64Field("cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J/qEiE="))
        #expect(!SyncCrypto.isValidServerProof(received, key: otherKey, clientNonce: Self.nc, serverNonce: Self.ns))

        let keys = SyncCrypto.sessionKeys(key: Self.key, clientNonce: Self.nc, serverNonce: Self.ns)
        // The c2s #0 frame a second time: close 4005.
        var opener = FrameOpener(key: keys.c2s)
        let frame = try #require(data(hex: Self.c2sFrame))
        _ = try opener.open(frame)
        #expect(throws: FrameError.unexpectedCounter) { try opener.open(frame) }
        #expect(FrameError.unexpectedCounter.closeCode.rawValue == 4005)

        // The s2c #1 frame with its last byte changed from c3 to c4: close 4004.
        var modified = try #require(data(hex: Self.s2cFrame))
        #expect(modified[modified.count - 1] == 0xc3)
        modified[modified.count - 1] = 0xc4
        var clientOpener = FrameOpener(key: keys.s2c, firstCounter: 1)
        #expect(throws: FrameError.authenticationFailed) { try clientOpener.open(modified) }
        #expect(FrameError.authenticationFailed.closeCode.rawValue == 4004)

        // URL-safe base64 in a challenge: close 1002.
        #expect(SyncCrypto.decodeBase64Field("cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J_qEiE=") == nil)
        let challenge = #"{"nonce":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=","proof":"cQpkmCMXJWkVibDhSVYhOrADuuHpqr3ufQtH0J_qEiE=","type":"challenge"}"#
        #expect(failure(SyncMessageCheck.challenge(Data(challenge.utf8))) == .protocolError)

        // A hello with protocol 2: close 4001. A hello with the server's own id: close 4007.
        let hello2 = #"{"appVersion":"0.4.0","deviceID":"6B1D3F0A-5C2E-4E8B-9A7D-2F4C6E8A0B1C","deviceName":"MacBook","nonce":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","protocol":2,"type":"hello"}"#
        #expect(failure(SyncMessageCheck.hello(Data(hello2.utf8), ownDeviceID: Self.serverID)) == .unsupportedProtocol)
        #expect(SyncCloseCode.unsupportedProtocol.rawValue == 4001)
        let ownHello = #"{"appVersion":"0.4.0","deviceID":"9D7E2F4A-1B3C-4D5E-8F60-718293A4B5C6","deviceName":"MacBook","nonce":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","protocol":1,"type":"hello"}"#
        #expect(failure(SyncMessageCheck.hello(Data(ownHello.utf8), ownDeviceID: Self.serverID)) == .sameDevice)
        #expect(SyncCloseCode.sameDevice.rawValue == 4007)
    }

    @Test("Frame checks in their order: length, prefix, counter, tag")
    func frameChecks() throws {
        let keys = SyncCrypto.sessionKeys(key: Self.key, clientNonce: Self.nc, serverNonce: Self.ns)
        var opener = FrameOpener(key: keys.c2s)
        #expect(throws: FrameError.tooShort) { try opener.open(Data(count: 27)) }
        var frame = try #require(data(hex: Self.c2sFrame))
        frame[2] = 1
        #expect(throws: FrameError.badNoncePrefix) { try opener.open(frame) }
        // A wrong counter is reported before the tag.
        var wrongCounter = try #require(data(hex: Self.c2sFrame))
        wrongCounter[11] = 5
        #expect(throws: FrameError.unexpectedCounter) { try opener.open(wrongCounter) }
        #expect(opener.expectedCounter == 0)
        #expect(FrameError.tooShort.closeCode == .decryptionFailed)
        #expect(FrameError.badNoncePrefix.closeCode == .decryptionFailed)
    }

    @Test("A sealer whose next counter would be 2^64 refuses to seal")
    func counterExhaustion() throws {
        var sealer = FrameSealer(key: SymmetricKey(size: .bits256), firstCounter: .max)
        let last = try sealer.seal(Data("{}".utf8))
        #expect(hex(last.prefix(12)) == "00000000ffffffffffffffff")
        #expect(sealer.nextCounter == nil)
        #expect(throws: FrameError.counterExhausted) { try sealer.seal(Data("{}".utf8)) }
        #expect(FrameError.counterExhausted.closeCode == .normal)
    }

    @Test("Base64 fields: standard alphabet with padding, exactly 32 bytes")
    func base64Fields() {
        let valid = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
        #expect(SyncCrypto.decodeBase64Field(valid) == Self.nc)
        #expect(SyncCrypto.decodeBase64Field(String(valid.dropLast())) == nil)
        #expect(SyncCrypto.decodeBase64Field(" " + valid) == nil)
        #expect(SyncCrypto.decodeBase64Field("AAECAwQFBgcICQoLDA0O\nDxAREhMUFRYXGBkaGxwdHh8=") == nil)
        #expect(SyncCrypto.decodeBase64Field(Data(count: 31).base64EncodedString()) == nil)
        #expect(SyncCrypto.decodeBase64Field(Data(count: 33).base64EncodedString()) == nil)
        #expect(SyncCrypto.randomNonce().count == 32)
        #expect(SyncCrypto.randomNonce() != SyncCrypto.randomNonce())
    }

    @Test("The regeneration snippet of docs/remote.md gives the same bytes")
    func regenerationSnippet() throws {
        let code = Data("7H0K4XQ2M91DTZ5C".utf8)
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: code), salt: Data("hephaestus-v2".utf8),
                                       info: Data("pairing".utf8), outputByteCount: 32)
        #expect(hex(k) == hex(Self.key))
        let kC2S = HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: Self.nc + Self.ns, info: Data("c2s".utf8), outputByteCount: 32)
        var nonce = Data(count: 4)
        withUnsafeBytes(of: UInt64(0).bigEndian) { nonce.append(contentsOf: $0) }
        let frame = try ChaChaPoly.seal(Data(Self.c2sPlaintext.utf8), using: kC2S, nonce: ChaChaPoly.Nonce(data: nonce)).combined
        #expect(hex(frame) == Self.c2sFrame)
    }

    // MARK: Helpers

    private func failure<T>(_ result: Result<T, SyncCloseCode>) -> SyncCloseCode? {
        if case .failure(let code) = result { return code }
        return nil
    }
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func hex(_ key: SymmetricKey) -> String {
    key.withUnsafeBytes { hex(Data($0)) }
}

func data(hex text: String) -> Data? {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return Data(bytes)
}
