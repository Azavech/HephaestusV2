import Foundation
import Testing
@testable import HephaestusCore

/// The shortcut notation, the recorder's keys and the standard macOS shortcuts
/// (docs/chats.md › Shortcut notation, › Shortcut recorder, › Standard macOS shortcuts).
@Suite("Keyboard shortcuts")
struct KeyShortcutTests {
    @Test("The notation: modifiers ⌃ ⌥ ⇧ ⌘ at most once and in this order, then one key")
    func notation() throws {
        for valid in ["⇧⌘K", "⌃⌥K", "⌘↩", "⎋", "F5", "⌃Space", "⌃⌥⇧⌘F20", "⌘⇥", "⌥⌫", "⌘⌦", "⌘←", "⌘→", "⌘↑", "⌘↓", "↖", "↘", "⇞",
                      "⇟", "⌤", "⇧⌘/", "⌘,", "⌘`", "1", "⌘É", "⌘(", "⌘\\", "Space", "F"] {
            let shortcut = try #require(KeyShortcut(valid), "\(valid)")
            #expect(shortcut.notation == valid)
        }
        // Wrong order, a repeated modifier, a modifier alone, a lowercase letter, two keys,
        // white space, a function key above F20, an empty text.
        for invalid in ["⌘⇧K", "⌥⌃K", "⌘⌘K", "⌘", "⌃⌥⇧⌘", "⌘k", "k", "⌘KL", "⌘ ", " ", "⌘ K", "F21", "F0", "", "⌘\n",
                        "⌘\u{F704}", "⌘SPACE", "⌘ß"] {
            #expect(KeyShortcut(invalid) == nil, "\(invalid)")
        }
    }

    @Test("Key caps: one per modifier and one for the key, in the order written")
    func keyCaps() {
        #expect(KeyShortcut("⇧⌘K")?.keyCaps == ["⇧", "⌘", "K"])
        #expect(KeyShortcut.keyCaps(of: "⌃Space") == ["⌃", "Space"])
        #expect(KeyShortcut.keyCaps(of: "⎋") == ["⎋"])
        #expect(KeyShortcut.keyCaps(of: "⌘⇧K") == nil)
    }

    @Test("The answer marker escapes the keys (, ) and \\")
    func marker() {
        #expect(KeyShortcut("⇧⌘K")?.marker == "![](shortcut:⇧⌘K)")
        #expect(KeyShortcut("⌘(")?.marker == "![](shortcut:⌘\\()")
        #expect(KeyShortcut("⌥)")?.marker == "![](shortcut:⌥\\))")
        #expect(KeyShortcut("⌘\\")?.marker == "![](shortcut:⌘\\\\)")
    }

    @Test("A recorded shortcut orders its modifiers")
    func modifiersInOrder() {
        #expect(KeyShortcut(modifiers: [.command, .shift, .control, .option], key: "K")?.notation == "⌃⌥⇧⌘K")
        #expect(KeyShortcut(modifiers: [], key: "⎋")?.notation == "⎋")
        #expect(KeyShortcut(modifiers: [.command], key: "k") == nil)
    }

    @Test("Recorded keys: the named keys by key code, else the unmodified character in uppercase")
    func recordedKeys() {
        #expect(KeyShortcut.recordedKey(keyCode: 0x24, unmodifiedCharacters: "\r") == "↩")
        #expect(KeyShortcut.recordedKey(keyCode: 0x4C, unmodifiedCharacters: "\u{3}") == "⌤")
        #expect(KeyShortcut.recordedKey(keyCode: 0x35, unmodifiedCharacters: "\u{1B}") == "⎋")
        #expect(KeyShortcut.recordedKey(keyCode: 0x30, unmodifiedCharacters: "\t") == "⇥")
        #expect(KeyShortcut.recordedKey(keyCode: 0x31, unmodifiedCharacters: " ") == "Space")
        #expect(KeyShortcut.recordedKey(keyCode: 0x33, unmodifiedCharacters: "\u{7F}") == "⌫")
        #expect(KeyShortcut.recordedKey(keyCode: 0x75, unmodifiedCharacters: "\u{F728}") == "⌦")
        #expect(KeyShortcut.recordedKey(keyCode: 0x7B, unmodifiedCharacters: "\u{F702}") == "←")
        #expect(KeyShortcut.recordedKey(keyCode: 0x7E, unmodifiedCharacters: "\u{F700}") == "↑")
        #expect(KeyShortcut.recordedKey(keyCode: 0x73, unmodifiedCharacters: "\u{F729}") == "↖")
        #expect(KeyShortcut.recordedKey(keyCode: 0x79, unmodifiedCharacters: "\u{F72D}") == "⇟")
        #expect(KeyShortcut.recordedKey(keyCode: 0x60, unmodifiedCharacters: "\u{F708}") == "F5")
        #expect(KeyShortcut.recordedKey(keyCode: 0x5A, unmodifiedCharacters: "\u{F717}") == "F20")
        #expect(KeyShortcut.recordedKey(keyCode: 0x28, unmodifiedCharacters: "k") == "K")
        #expect(KeyShortcut.recordedKey(keyCode: 0x2C, unmodifiedCharacters: "/") == "/")
        #expect(KeyShortcut.recordedKey(keyCode: 0x12, unmodifiedCharacters: "1") == "1")
        // Help, the keypad Clear key, a private-use character, no character.
        #expect(KeyShortcut.recordedKey(keyCode: 0x72, unmodifiedCharacters: "\u{F746}") == nil)
        #expect(KeyShortcut.recordedKey(keyCode: 0x47, unmodifiedCharacters: "\u{F739}") == nil)
        #expect(KeyShortcut.recordedKey(keyCode: 0x6E, unmodifiedCharacters: "\u{F735}") == nil)
        #expect(KeyShortcut.recordedKey(keyCode: 0x28, unmodifiedCharacters: "") == nil)
        #expect(KeyShortcut.recordedKey(keyCode: 0x28, unmodifiedCharacters: nil) == nil)
    }

    /// The rows of the table of docs/chats.md › Standard macOS shortcuts.
    static func documentedStandardShortcuts() throws -> [StandardShortcuts.Entry] {
        let chats = try Repository.doc("chats.md")
        let start = try #require(chats.range(of: "\n### Standard macOS shortcuts\n"))
        let end = try #require(chats.range(of: "\n### ", range: start.upperBound..<chats.endIndex))
        let rows = chats[start.upperBound..<end.lowerBound].components(separatedBy: "\n").filter { $0.hasPrefix("| ") }
        // The header and the separator, then one row per shortcut: a code span, or plain text with
        // the grave accent written `&#96;`.
        return rows.dropFirst(2).map { line in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            var shortcut = cells[0].replacingOccurrences(of: "&#96;", with: "`")
            if shortcut.hasPrefix("`"), shortcut.hasSuffix("`") {
                shortcut = String(shortcut.dropFirst().dropLast())
            }
            return StandardShortcuts.Entry(shortcut: shortcut, action: cells[1])
        }
    }

    @Test("The standard macOS shortcuts are the table of the docs, each in the notation and listed once")
    func standardShortcuts() throws {
        let documented = try Self.documentedStandardShortcuts()
        #expect(documented.count == 68)
        #expect(documented == StandardShortcuts.entries)
        for entry in StandardShortcuts.entries {
            #expect(KeyShortcut(entry.shortcut)?.notation == entry.shortcut, "\(entry.shortcut)")
        }
        #expect(Set(StandardShortcuts.entries.map(\.shortcut)).count == StandardShortcuts.entries.count)
        #expect(StandardShortcuts.action(for: "⌘Space") == "Spotlight")
        #expect(StandardShortcuts.action(for: "⌥⌘⎋") == "Force Quit")
        #expect(StandardShortcuts.action(for: "⌘`") == "Switch Windows")
        #expect(StandardShortcuts.action(for: "⌃⌥K") == nil)
    }
}
