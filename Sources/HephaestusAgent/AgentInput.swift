import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The methods `click`, `drag`, `scroll`, `type` and `key`: mouse and keyboard events posted with
/// Core Graphics (docs/virtual-machines.md › Methods). They need the Accessibility permission.
enum AgentInput {
    static let permissionMessage = "The agent has no Accessibility permission."

    private static func checkPermission() throws {
        guard AXIsProcessTrusted() else { throw AgentError(permissionMessage) }
    }

    private static func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private static func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func post(_ event: CGEvent?) throws {
        guard let event else { throw AgentError("The event could not be created.") }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Mouse

    static func click(_ params: AgentParams) throws -> AgentResult {
        try checkPermission()
        let point = AgentScreen.point(x: try params.number("x"), y: try params.number("y"))
        let count = try params.integer("count", default: 1, in: 1...3)
        let right: Bool
        switch try params.optionalString("button") ?? "left" {
        case "left": right = false
        case "right": right = true
        default: throw AgentError("button: use left or right.")
        }
        let button: CGMouseButton = right ? .right : .left
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let source = source()
        try post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
        pause(0.05)
        for index in 1...count {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                try post(event)
                pause(0.03)
            }
        }
        return AgentResult()
    }

    static func drag(_ params: AgentParams) throws -> AgentResult {
        try checkPermission()
        let from = AgentScreen.point(x: try params.number("fromX"), y: try params.number("fromY"))
        let to = AgentScreen.point(x: try params.number("toX"), y: try params.number("toY"))
        let source = source()
        try post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left))
        pause(0.05)
        try post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
        pause(0.1)
        let steps = 20
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
            try post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
            pause(0.015)
        }
        pause(0.1)
        try post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
        return AgentResult()
    }

    static func scroll(_ params: AgentParams) throws -> AgentResult {
        try checkPermission()
        let point = AgentScreen.point(x: try params.number("x"), y: try params.number("y"))
        let scale = AgentScreen.scale()
        let deltaX = (try params.optionalNumber("deltaX") ?? 0) / scale
        let deltaY = (try params.optionalNumber("deltaY") ?? 0) / scale
        let source = source()
        try post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
        pause(0.05)
        // A positive wheel value scrolls up or left: a positive delta scrolls down or right.
        try post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                         wheel1: wheel(-deltaY), wheel2: wheel(-deltaX), wheel3: 0))
        return AgentResult()
    }

    /// A wheel value: the delta rounded, held within what a wheel event carries.
    static func wheel(_ delta: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), delta.rounded())))
    }

    // MARK: Keyboard

    /// Types the text as Unicode characters, whatever the keyboard layout; a line break types
    /// Return and a tab Tab.
    static func type(_ params: AgentParams) throws -> AgentResult {
        try checkPermission()
        let text = try params.string("text")
        let source = source()
        for character in text {
            if character.isNewline {
                try press(keyCode: CGKeyCode(kVK_Return), flags: [], source: source)
            } else if character == "\t" {
                try press(keyCode: CGKeyCode(kVK_Tab), flags: [], source: source)
            } else {
                let units = Array(String(character).utf16)
                for keyDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                    event?.flags = []
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    try post(event)
                }
            }
            pause(0.008)
        }
        return AgentResult()
    }

    static func key(_ params: AgentParams) throws -> AgentResult {
        try checkPermission()
        let name = try params.string("key")
        var flags: CGEventFlags = []
        for modifier in try params.strings("modifiers") {
            switch modifier {
            case "control": flags.insert(.maskControl)
            case "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "command": flags.insert(.maskCommand)
            default: throw AgentError("modifiers: use control, option, shift or command.")
            }
        }
        guard let key = keyCode(named: name) else { throw AgentError("Unknown key \(name).") }
        if key.shift {
            flags.insert(.maskShift)
        }
        try press(keyCode: key.code, flags: flags, source: source())
        return AgentResult()
    }

    private static func press(keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) throws {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            try post(event)
            pause(0.01)
        }
    }

    /// The keys with a name.
    static let namedKeys: [String: Int] = [
        "return": kVK_Return, "enter": kVK_ANSI_KeypadEnter, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete,
        "forwardDelete": kVK_ForwardDelete, "escape": kVK_Escape, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End, "pageUp": kVK_PageUp,
        "pageDown": kVK_PageDown, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13,
        "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
    ]

    /// The keys of the ANSI layout, used only when the keyboard layout cannot be read.
    static let ansiKeys: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "`": kVK_ANSI_Grave, " ": kVK_Space,
    ]

    /// The key code of a key name, or of one character as the keyboard layout types it, without
    /// Shift when the layout has it so, else with Shift. A letter is matched in either case.
    static func keyCode(named name: String) -> (code: CGKeyCode, shift: Bool)? {
        if let code = namedKeys[name] {
            return (CGKeyCode(code), false)
        }
        guard name.count == 1, let character = name.lowercased().first else { return nil }
        return keyCode(of: character, in: layoutKeys())
    }

    /// The key that types `character` in a keyboard layout. A layout that was read and does not
    /// type the character has no key for it: its ANSI key would type something else there.
    static func keyCode(of character: Character,
                        in layout: (plain: [Character: CGKeyCode], shifted: [Character: CGKeyCode])) -> (code: CGKeyCode, shift: Bool)? {
        if let code = layout.plain[character] { return (code, false) }
        if let code = layout.shifted[character] { return (code, true) }
        if layout.plain.isEmpty, layout.shifted.isEmpty, let code = ansiKeys[character] { return (CGKeyCode(code), false) }
        return nil
    }

    /// The characters of the current keyboard layout, lowercased, with the key codes that type
    /// them without modifier and with Shift. The Text Input Source calls run on the main thread.
    private static func layoutKeys() -> (plain: [Character: CGKeyCode], shifted: [Character: CGKeyCode]) {
        if Thread.isMainThread {
            return readLayoutKeys()
        }
        return DispatchQueue.main.sync { readLayoutKeys() }
    }

    private static func readLayoutKeys() -> (plain: [Character: CGKeyCode], shifted: [Character: CGKeyCode]) {
        var plain: [Character: CGKeyCode] = [:]
        var shifted: [Character: CGKeyCode] = [:]
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return (plain, shifted)
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        layoutData.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            let keyboardType = UInt32(LMGetKbdType())
            for keyCode in 0..<128 {
                for (modifiers, isShifted) in [(UInt32(0), false), (UInt32(shiftKey >> 8), true)] {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), modifiers, keyboardType,
                                                0, &deadKeyState, characters.count, &length, &characters)
                    // A dead key types nothing by itself: it waits for the key it combines with.
                    guard status == noErr, deadKeyState == 0, length > 0,
                          let character = String(utf16CodeUnits: characters, count: length).lowercased().first,
                          !character.isNewline, character != "\t", !character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                        continue
                    }
                    if isShifted {
                        if shifted[character] == nil { shifted[character] = CGKeyCode(keyCode) }
                    } else if plain[character] == nil {
                        plain[character] = CGKeyCode(keyCode)
                    }
                }
            }
        }
        return (plain, shifted)
    }
}
