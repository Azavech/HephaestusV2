import Carbon.HIToolbox
import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/ui.md › Virtual Machines (Guest Account section) and docs/virtual-machines.md › Type
/// Password.
@Suite("Guest account")
struct GuestAccountTests {
    static let image = VMImage(id: UUID(uuidString: "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F")!, version: "27.2.1", build: "26B131",
                               state: .ready, userName: "tester", password: "test",
                               created: Date(timeIntervalSince1970: 0))

    @Test("The section's texts")
    @MainActor
    func texts() {
        #expect(GuestAccountPresentation.sectionLabel == "Guest Account")
        #expect(GuestAccountPresentation.userNameLabel == "User name")
        #expect(GuestAccountPresentation.passwordLabel == "Password")
        #expect(GuestKeyboard.title == "Type Password")
    }

    @Test("The section sends only the values that differ from the stored ones")
    func changes() {
        let image = Self.image
        #expect(GuestAccountPresentation.changes(of: image, userName: "tester", password: "test") == nil)
        // The user name is compared trimmed, as it is stored.
        #expect(GuestAccountPresentation.changes(of: image, userName: " tester ", password: "test") == nil)
        #expect(GuestAccountPresentation.changes(of: image, userName: "tester", password: "other")
            == VMImagesSetAccount.Params(imageID: image.id, password: "other"))
        #expect(GuestAccountPresentation.changes(of: image, userName: "", password: "test")
            == VMImagesSetAccount.Params(imageID: image.id, userName: ""))
        var empty = image
        empty.userName = nil
        empty.password = nil
        #expect(GuestAccountPresentation.changes(of: empty, userName: "", password: "") == nil)
        #expect(GuestAccountPresentation.changes(of: empty, userName: "a", password: "b")
            == VMImagesSetAccount.Params(imageID: image.id, userName: "a", password: "b"))
    }

    /// A small layout: key 0 types a/A/å/Å, key 1 types 1/!, key 2 is a dead key, key 3 types é
    /// with Option only, key 36 types Return.
    static let layout = KeyboardLayoutKeys { keyCode, shift, option in
        switch (keyCode, shift, option) {
        case (0, false, false): return "a"
        case (0, true, false): return "A"
        case (0, false, true): return "å"
        case (0, true, true): return "Å"
        case (1, false, false): return "1"
        case (1, true, false): return "!"
        case (2, _, _): return nil
        case (3, false, true): return "é"
        case (36, _, _): return "\r"
        case (49, false, false): return " "
        default: return nil
        }
    }

    @Test("Each character is pressed with its key and the fewest modifiers of the layout")
    func strokes() throws {
        let strokes = try Self.layout.strokes(for: "aA1! éÅ").get()
        #expect(strokes == [
            GuestKeyStroke(keyCode: 0), GuestKeyStroke(keyCode: 0, shift: true), GuestKeyStroke(keyCode: 1),
            GuestKeyStroke(keyCode: 1, shift: true), GuestKeyStroke(keyCode: 49), GuestKeyStroke(keyCode: 3, option: true),
            GuestKeyStroke(keyCode: 0, shift: true, option: true),
        ])
        // A control character is no key of a password; a character without a key fails the whole text.
        #expect(Self.layout.strokes[Character("\r")] == nil)
        #expect(Self.layout.strokes(for: "a€") == .failure(.cannotType("€")))
        #expect(GuestKeyboardError.cannotType("€").localizedDescription == "The keyboard layout of this Mac cannot type “€”.")
    }

    @Test("The first key of the layout wins: a digit of the main row before the keypad")
    func firstKeyWins() throws {
        let layout = KeyboardLayoutKeys { keyCode, shift, option in
            guard !shift, !option else { return nil }
            return keyCode == 18 || keyCode == 83 ? "1" : nil
        }
        #expect(try layout.strokes(for: "1").get() == [GuestKeyStroke(keyCode: 18)])
    }

    @Test("The keyboard layout of this Mac types the letters and digits")
    func currentLayout() throws {
        let layout = try #require(KeyboardLayoutKeys.current())
        // Every layout of a Mac keyboard types a space with the space bar.
        #expect(try layout.strokes(for: " ").get() == [GuestKeyStroke(keyCode: UInt16(kVK_Space))])
    }

    @Test("Type Password is enabled while a password is stored")
    @MainActor
    func enabled() {
        let keyboard = GuestKeyboard()
        #expect(keyboard.canType("test"))
        #expect(!keyboard.canType(nil))
        #expect(!keyboard.canType(""))
    }
}
