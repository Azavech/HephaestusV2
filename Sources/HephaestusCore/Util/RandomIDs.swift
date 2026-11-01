import Foundation
import Security

/// Generation of the random identifiers and secrets of docs/data-model.md › Ids.
public enum RandomIDs {
    /// A new UUID in the uppercase form the engine writes.
    public static func uuidString() -> String {
        UUID().uuidString.uppercased()
    }

    /// `count` bytes from `SecRandomCopyBytes`.
    public static func bytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return bytes
    }

    /// The external MCP token: 64 lowercase hexadecimal characters encoding 32 random bytes.
    public static func externalToken() -> String {
        bytes(32).map { byte in
            let text = String(byte, radix: 16)
            return byte < 16 ? "0" + text : text
        }.joined()
    }

    /// The Crockford base32 alphabet of pairing codes.
    public static let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A pairing code in display form, `XXXX-XXXX-XXXX-XXXX`: 16 Crockford base32 characters
    /// encoding 80 random bits (docs/architecture.md › Security overview).
    public static func pairingCode() -> String {
        let random = bytes(10)
        var characters: [Character] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in random {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                characters.append(crockfordAlphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        var groups: [String] = []
        for start in stride(from: 0, to: characters.count, by: 4) {
            groups.append(String(characters[start..<start + 4]))
        }
        return groups.joined(separator: "-")
    }
}
