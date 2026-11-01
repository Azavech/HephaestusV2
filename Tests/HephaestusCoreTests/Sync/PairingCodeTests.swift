import Foundation
import Testing
@testable import HephaestusCore

/// docs/remote.md › Pairing code and › Code normalization.
@Suite("Pairing code")
struct PairingCodeTests {
    @Test("The example of docs/remote.md › Code normalization")
    func normalization() throws {
        let code = try #require(PairingCode(userInput: "7h0k 4xq2-m9ld tz5c"))
        #expect(code.normalized == "7H0K4XQ2M91DTZ5C")
        #expect(code.display == "7H0K-4XQ2-M91D-TZ5C")
        #expect(PairingCode(userInput: code.display) == code)
    }

    @Test("Codes without 16 characters of the alphabet are refused")
    func invalidCodes() {
        for input in ["", "7H0K-4XQ2-M91D-TZ5", "7H0K-4XQ2-M91D-TZ5CC", "7H0K-4XQ2-M91D-TZ5U", "7H0K_4XQ2_M91D_TZ5C", "7H0K-4XQ2-M91D-TZ5É"] {
            #expect(PairingCode(userInput: input) == nil, "\(input)")
        }
    }

    @Test("Generated codes are valid display forms")
    func generation() {
        let code = PairingCode.generate()
        #expect(Identifiers.isPairingCode(code.display))
        #expect(code.normalized.count == 16)
    }
}
