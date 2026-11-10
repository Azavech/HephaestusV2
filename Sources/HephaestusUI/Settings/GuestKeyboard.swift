// OWNER: ui-shell — `Type Password`: the keys of a password pressed through the screen of a
// virtual machine (docs/virtual-machines.md › Type Password).
import AppKit
import Carbon.HIToolbox
import HephaestusCore
import Observation
import SwiftUI
import Virtualization

/// One key press: the virtual key code of a key and the modifiers that type its character.
struct GuestKeyStroke: Hashable, Sendable {
    var keyCode: UInt16
    var shift = false
    var option = false
}

/// The keys that type each character on a keyboard layout: for each character, the first key of
/// the key codes 0 to 127 that types it alone, else with Shift, else with Option, else with both.
/// A dead key, which types nothing by itself, types no character.
struct KeyboardLayoutKeys {
    /// The modifier states tried, in this order: none, Shift, Option, Shift and Option.
    static let modifierStates: [(shift: Bool, option: Bool)] = [(false, false), (true, false), (false, true), (true, true)]

    private(set) var strokes: [Character: GuestKeyStroke] = [:]

    /// `translate` gives the text that a key types with these modifiers, nil for a dead key or a
    /// key that types nothing.
    init(translate: (_ keyCode: UInt16, _ shift: Bool, _ option: Bool) -> String?) {
        for state in Self.modifierStates {
            for keyCode in UInt16(0)..<128 {
                guard let text = translate(keyCode, state.shift, state.option), text.count == 1, let character = text.first,
                      strokes[character] == nil, Self.isPrintable(character) else { continue }
                strokes[character] = GuestKeyStroke(keyCode: keyCode, shift: state.shift, option: state.option)
            }
        }
    }

    /// The key presses of a text; the first character that no key types fails.
    func strokes(for text: String) -> Result<[GuestKeyStroke], GuestKeyboardError> {
        var result: [GuestKeyStroke] = []
        for character in text {
            guard let stroke = strokes[character] else { return .failure(.cannotType(character)) }
            result.append(stroke)
        }
        return .success(result)
    }

    /// A character that a key types into a text: not a control character.
    private static func isPrintable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7F }
    }

    /// The keys of the keyboard layout of this Mac now, read with `UCKeyTranslate`; nil when the
    /// current input source has no layout data.
    static func current() -> KeyboardLayoutKeys? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { buffer -> KeyboardLayoutKeys? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            return KeyboardLayoutKeys { keyCode, shift, option in
                var modifiers: UInt32 = 0
                if shift { modifiers |= UInt32(shiftKey >> 8) }
                if option { modifiers |= UInt32(optionKey >> 8) }
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType, 0,
                                            &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }
}

/// The failure of `Type Password`.
enum GuestKeyboardError: LocalizedError, Equatable {
    /// The keyboard layout of this Mac has no key for the character.
    case cannotType(Character)
    /// No screen of a virtual machine shows.
    case noScreen

    var errorDescription: String? {
        switch self {
        case .cannotType(let character): return "The keyboard layout of this Mac cannot type “\(character)”."
        case .noScreen: return "The screen of the virtual machine is not shown."
        }
    }
}

/// The keyboard of `Type Password` for one screen of a virtual machine: it presses keys through
/// the framework's `VZVirtualMachineView`, as the user's keyboard does, so that they reach the
/// guest without its agent. Main actor only.
@MainActor
@Observable
final class GuestKeyboard {
    /// The title of the button and of its failure alert, `Type Password failed`.
    static let title = "Type Password"
    /// The time between two events, so that the guest takes every key.
    static let eventInterval: Duration = .milliseconds(10)

    /// The screen; set by `VirtualMachineScreen`.
    @ObservationIgnored weak var view: VZVirtualMachineView?
    /// True while a password is being typed.
    private(set) var isTyping = false

    /// `Type Password` is enabled while a password is stored and nothing is being typed.
    func canType(_ password: String?) -> Bool {
        !(password ?? "").isEmpty && !isTyping
    }

    /// Gives the screen the keyboard focus, then presses the keys of the text on the keyboard
    /// layout of this Mac, without Return. A character that the layout cannot type fails before
    /// any key is pressed.
    func type(_ text: String) async throws {
        guard !isTyping else { return }
        guard let view, let window = view.window else { throw GuestKeyboardError.noScreen }
        let layout = KeyboardLayoutKeys.current() ?? KeyboardLayoutKeys { _, _, _ in nil }
        let strokes = try layout.strokes(for: text).get()
        isTyping = true
        defer { isTyping = false }
        window.makeFirstResponder(view)
        for (stroke, character) in zip(strokes, text) {
            await press(stroke, character: String(character), in: view, window: window)
        }
    }

    /// One key: the modifiers down, the key down and up, the modifiers up.
    private func press(_ stroke: GuestKeyStroke, character: String, in view: VZVirtualMachineView, window: NSWindow) async {
        var flags: NSEvent.ModifierFlags = []
        if stroke.shift {
            flags.insert(.shift)
            flags.insert(NSEvent.ModifierFlags(rawValue: Self.leftShiftDeviceBit))
            await send(.flagsChanged, keyCode: UInt16(kVK_Shift), flags: flags, characters: "", to: view, window: window)
        }
        if stroke.option {
            flags.insert(.option)
            flags.insert(NSEvent.ModifierFlags(rawValue: Self.leftOptionDeviceBit))
            await send(.flagsChanged, keyCode: UInt16(kVK_Option), flags: flags, characters: "", to: view, window: window)
        }
        await send(.keyDown, keyCode: stroke.keyCode, flags: flags, characters: character, to: view, window: window)
        await send(.keyUp, keyCode: stroke.keyCode, flags: flags, characters: character, to: view, window: window)
        if stroke.option {
            flags.remove(.option)
            flags.remove(NSEvent.ModifierFlags(rawValue: Self.leftOptionDeviceBit))
            await send(.flagsChanged, keyCode: UInt16(kVK_Option), flags: flags, characters: "", to: view, window: window)
        }
        if stroke.shift {
            flags.remove(.shift)
            flags.remove(NSEvent.ModifierFlags(rawValue: Self.leftShiftDeviceBit))
            await send(.flagsChanged, keyCode: UInt16(kVK_Shift), flags: flags, characters: "", to: view, window: window)
        }
    }

    /// The device-dependent bits of the left Shift and Option keys (`NX_DEVICELSHIFTKEYMASK`,
    /// `NX_DEVICELALTKEYMASK`): the framework passes a modifier to the guest only with them.
    private static let leftShiftDeviceBit: UInt = 0x02
    private static let leftOptionDeviceBit: UInt = 0x20

    private func send(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String,
                      to view: VZVirtualMachineView, window: NSWindow) async {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return }
        switch type {
        case .flagsChanged: view.flagsChanged(with: event)
        case .keyDown: view.keyDown(with: event)
        default: view.keyUp(with: event)
        }
        // Not cancelled, so that every modifier pressed is released.
        try? await Task.sleep(for: Self.eventInterval)
    }
}

/// The `Type Password` button of the setup view and of the detail of a virtual machine: it types
/// `password`, the password of the image, through `keyboard`; disabled without a password, while
/// it types and when `enabled` is false. A failure goes to `failed`.
struct TypePasswordButton: View {
    let keyboard: GuestKeyboard
    let password: String?
    var enabled = true
    let failed: (Error) -> Void

    var body: some View {
        Button(GuestKeyboard.title) {
            guard let password else { return }
            Task {
                do {
                    try await keyboard.type(password)
                } catch {
                    failed(error)
                }
            }
        }
        .disabled(!enabled || !keyboard.canType(password))
    }
}
