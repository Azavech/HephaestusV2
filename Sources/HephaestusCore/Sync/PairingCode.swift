import Foundation

/// A pairing code: 16 characters of Crockford base32, 80 bits (docs/remote.md › Pairing code).
public struct PairingCode: Sendable, Hashable {
    /// The 16 characters, the input of the key derivation (docs/remote.md › Key derivation).
    public let normalized: String

    /// The text the code field shows when the typed code is not valid.
    public static let invalidInputMessage = "Pairing codes have 16 characters, shown as XXXX-XXXX-XXXX-XXXX."

    /// The normalized form of a code a user types or pastes, or of a stored code
    /// (docs/remote.md › Code normalization): `-` and whitespace removed, ASCII letters
    /// uppercased, `O` read as `0`, `I` and `L` as `1`; nil unless 16 characters of the alphabet
    /// remain.
    public init?(userInput: String) {
        var characters: [Character] = []
        for character in userInput where character != "-" && !character.isWhitespace {
            var upper = character
            if character.isASCII, character.isLetter {
                upper = Character(character.uppercased())
            }
            switch upper {
            case "O": upper = "0"
            case "I", "L": upper = "1"
            default: break
            }
            guard RandomIDs.crockfordAlphabet.contains(upper) else { return nil }
            characters.append(upper)
        }
        guard characters.count == 16 else { return nil }
        normalized = String(characters)
    }

    /// `XXXX-XXXX-XXXX-XXXX`: the form stored in `secrets.json` and shown in Settings > Devices.
    public var display: String {
        let characters = Array(normalized)
        return stride(from: 0, to: 16, by: 4).map { String(characters[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// A new random code (docs/remote.md › Pairing code › Generation).
    public static func generate() -> PairingCode {
        PairingCode(userInput: RandomIDs.pairingCode())!
    }
}
