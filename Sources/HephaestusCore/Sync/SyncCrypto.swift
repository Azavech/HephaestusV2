import CryptoKit
import Foundation

/// The key derivation and the proofs of the sync handshake (docs/remote.md › Cryptography):
/// HKDF-SHA256 for every key, HMAC-SHA256 for the proofs, compared in constant time. `K`, the
/// session keys, the nonces and the proofs are never written to disk or to logs.
public enum SyncCrypto {
    /// Length of `nc`, `ns`, `K`, the session keys and the proofs.
    public static let byteCount = 32

    static let pairingSalt = Data("hephaestus-v2".utf8)
    static let pairingInfo = Data("pairing".utf8)
    static let serverLabel = Data("server".utf8)
    static let clientLabel = Data("client".utf8)
    static let c2sInfo = Data("c2s".utf8)
    static let s2cInfo = Data("s2c".utf8)

    /// `K` = HKDF-SHA256(code, salt "hephaestus-v2", info "pairing"), 32 bytes. It depends only
    /// on the normalized code.
    public static func pairingKey(code: PairingCode) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.normalized.utf8)), salt: pairingSalt,
                               info: pairingInfo, outputByteCount: byteCount)
    }

    /// HMAC-SHA256(K, "server" ‖ nc ‖ ns), sent in `challenge`.
    public static func serverProof(key: SymmetricKey, clientNonce: Data, serverNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: serverLabel + clientNonce + serverNonce, using: key))
    }

    /// HMAC-SHA256(K, "client" ‖ nc ‖ ns), sent in `auth`.
    public static func clientProof(key: SymmetricKey, clientNonce: Data, serverNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: clientLabel + clientNonce + serverNonce, using: key))
    }

    /// Whether `proof` is the server proof, compared in constant time.
    public static func isValidServerProof(_ proof: Data, key: SymmetricKey, clientNonce: Data, serverNonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: serverLabel + clientNonce + serverNonce, using: key)
    }

    /// Whether `proof` is the client proof, compared in constant time.
    public static func isValidClientProof(_ proof: Data, key: SymmetricKey, clientNonce: Data, serverNonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: clientLabel + clientNonce + serverNonce, using: key)
    }

    /// `kC2S` and `kS2C` = HKDF-SHA256(K, salt nc ‖ ns, info "c2s" / "s2c"), unique to one
    /// connection.
    public static func sessionKeys(key: SymmetricKey, clientNonce: Data, serverNonce: Data) -> (c2s: SymmetricKey, s2c: SymmetricKey) {
        let salt = clientNonce + serverNonce
        let c2s = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: c2sInfo, outputByteCount: byteCount)
        let s2c = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: s2cInfo, outputByteCount: byteCount)
        return (c2s, s2c)
    }

    /// 32 random bytes from the operating system CSPRNG, a new `nc` or `ns`.
    public static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// A `nonce` or `proof` field: standard base64 with padding, decoded with
    /// `Data(base64Encoded:)` without options, exactly 32 bytes; nil for any other form
    /// (docs/remote.md › Base64).
    public static func decodeBase64Field(_ text: String) -> Data? {
        guard let data = Data(base64Encoded: text), data.count == byteCount else { return nil }
        return data
    }
}

/// A frame that fails a check of docs/remote.md › Receiving a frame, or a sealer whose counter is
/// exhausted.
public enum FrameError: Error, Sendable, Hashable {
    /// The frame is shorter than 28 bytes: close 4004.
    case tooShort
    /// Bytes 0–3 are not zero: close 4004.
    case badNoncePrefix
    /// The counter differs from the expected counter: close 4005.
    case unexpectedCounter
    /// `ChaChaPoly.open` failed: close 4004.
    case authenticationFailed
    /// The sender's next counter would be 2^64: close 1000 instead of sealing.
    case counterExhausted

    /// The close code of the failed check.
    public var closeCode: SyncCloseCode {
        switch self {
        case .tooShort, .badNoncePrefix, .authenticationFailed: return .decryptionFailed
        case .unexpectedCounter: return .unexpectedCounter
        case .counterExhausted: return .normal
        }
    }
}

/// The sending half of one direction (docs/remote.md › Frame sealing): one key and one counter,
/// starting at 0. The frame is `00 00 00 00` ‖ counter (UInt64 big-endian) ‖ ciphertext ‖ tag,
/// CryptoKit's `ChaChaPoly.SealedBox.combined` with no additional data.
public struct FrameSealer: Sendable {
    /// Bytes added to a plaintext: the 12-byte nonce and the 16-byte tag.
    public static let overhead = 28

    private let key: SymmetricKey
    /// The counter of the next frame; nil once 2^64 − 1 has been used.
    public private(set) var nextCounter: UInt64?

    public init(key: SymmetricKey, firstCounter: UInt64 = 0) {
        self.key = key
        self.nextCounter = firstCounter
    }

    /// Seals the next frame and adds 1 to the counter. Throws `counterExhausted` when the next
    /// counter would be 2^64: the side then closes with 1000.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        guard let counter = nextCounter else { throw FrameError.counterExhausted }
        let nonce = try ChaChaPoly.Nonce(data: FrameSealer.nonceBytes(counter))
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        nextCounter = counter == .max ? nil : counter + 1
        return box.combined
    }

    /// The 12 nonce bytes of a counter.
    static func nonceBytes(_ counter: UInt64) -> Data {
        var nonce = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { nonce.append(contentsOf: $0) }
        return nonce
    }
}

/// The receiving half of one direction (docs/remote.md › Receiving a frame): the next expected
/// counter, starting at 0, and the checks in their order.
public struct FrameOpener: Sendable {
    private let key: SymmetricKey
    /// The counter the next frame must carry; nil after 2^64 − 1 was received.
    public private(set) var expectedCounter: UInt64?

    public init(key: SymmetricKey, firstCounter: UInt64 = 0) {
        self.key = key
        self.expectedCounter = firstCounter
    }

    /// Checks a binary frame and returns its plaintext: length at least 28 bytes, zero prefix,
    /// the expected counter, then the tag; the expected counter then becomes counter + 1.
    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= FrameSealer.overhead else { throw FrameError.tooShort }
        let bytes = [UInt8](frame.prefix(12))
        guard bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0 else { throw FrameError.badNoncePrefix }
        let counter = bytes[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard let expected = expectedCounter, counter == expected else { throw FrameError.unexpectedCounter }
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: frame), using: key)
        } catch {
            throw FrameError.authenticationFailed
        }
        expectedCounter = counter == .max ? nil : counter + 1
        return plaintext
    }
}
