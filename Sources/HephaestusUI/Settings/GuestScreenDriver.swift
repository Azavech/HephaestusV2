// OWNER: ui-shell — the screen of a setup virtual machine that the VM tools drive while its agent
// is not connected (docs/virtual-machines.md › Screen of the setup virtual machine).
import AppKit
import Carbon.HIToolbox
import CoreImage
import HephaestusCore
import IOSurface
import Virtualization

/// The provider the app gives the engine: a `GuestScreenDriver` for each setup virtual machine of
/// the framework (docs/architecture.md › Engine configuration).
struct AppGuestScreens: GuestScreenProviding {
    @MainActor func screen(for machine: any GuestMachine) -> (any GuestScreen)? {
        machine.virtualMachine.map { GuestScreenDriver(virtualMachine: $0) }
    }
}

/// A `VZVirtualMachineView` of its own, in a borderless window placed far off every screen and
/// never shown to the user, with the proportions of the setup virtual machine's display. The VM tools
/// read its image and send it the events of the mouse and the keyboard, as the user's go to the
/// screen of the setup view; the windows of the app and their focus are not touched.
@MainActor
final class GuestScreenDriver: GuestScreen {
    /// The display of the setup virtual machine, in pixels (docs/virtual-machines.md › Setup
    /// virtual machine).
    static let displaySize = CGSize(width: 2560, height: 1600)
    /// The time between two events, so that the guest takes each one.
    static let eventInterval: Duration = .milliseconds(10)
    /// The steps of a drag.
    static let dragSteps = 20

    private let window: NSWindow
    private let view: VZVirtualMachineView

    init(virtualMachine: VZVirtualMachine) {
        // The proportions of the display, half its pixels in points, the window far off screen.
        let frame = NSRect(x: -30_000, y: -30_000, width: Self.displaySize.width / 2, height: Self.displaySize.height / 2)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        view = VZVirtualMachineView(frame: NSRect(origin: .zero, size: frame.size))
        view.capturesSystemKeys = true
        view.virtualMachine = virtualMachine
        window.contentView = view
        window.orderFrontRegardless()
    }

    func close() {
        view.virtualMachine = nil
        window.orderOut(nil)
        window.close()
    }

    // MARK: Screenshot

    func screenshot(name: String) async throws -> GuestScreenshot {
        guard let surface = Self.surface(in: view.layer) else {
            throw GuestScreenError("The screen of “\(name)” shows nothing yet.")
        }
        let image = CIImage(ioSurface: surface)
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw GuestScreenError("The screen of “\(name)” shows nothing yet.")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw GuestScreenError("The screen of “\(name)” shows nothing yet.")
        }
        return GuestScreenshot(png: png, width: cgImage.width, height: cgImage.height)
    }

    /// The surface the framework draws the guest's display into: the contents of a layer of the
    /// view. None while the guest's display is off or the virtual machine starts.
    private static func surface(in layer: CALayer?) -> IOSurface? {
        guard let layer else { return nil }
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            return (contents as! IOSurface)
        }
        for sublayer in layer.sublayers ?? [] {
            if let surface = surface(in: sublayer) { return surface }
        }
        return nil
    }

    // MARK: Mouse

    /// The point of the view's window at a pixel of the display, from its top-left corner.
    private func windowPoint(x: Int, y: Int) -> NSPoint {
        let bounds = view.bounds
        let point = NSPoint(x: CGFloat(x) * bounds.width / Self.displaySize.width,
                            y: bounds.height - CGFloat(y) * bounds.height / Self.displaySize.height)
        return view.convert(view.isFlipped ? NSPoint(x: point.x, y: bounds.height - point.y) : point, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 0, pressure: Float = 0) async {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                                             pressure: pressure) else { return }
        switch type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        default: break
        }
        try? await Task.sleep(for: Self.eventInterval)
    }

    func click(x: Int, y: Int, button: String, count: Int) async throws {
        let point = windowPoint(x: x, y: y)
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = button == "right" ? (.rightMouseDown, .rightMouseUp)
                                                                                  : (.leftMouseDown, .leftMouseUp)
        await mouse(.mouseMoved, at: point)
        for click in 1...max(count, 1) {
            await mouse(down, at: point, clickCount: click, pressure: 1)
            await mouse(up, at: point, clickCount: click)
        }
    }

    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws {
        let start = windowPoint(x: fromX, y: fromY)
        let end = windowPoint(x: toX, y: toY)
        await mouse(.mouseMoved, at: start)
        await mouse(.leftMouseDown, at: start, clickCount: 1, pressure: 1)
        for step in 1...Self.dragSteps {
            let fraction = CGFloat(step) / CGFloat(Self.dragSteps)
            let point = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            await mouse(.leftMouseDragged, at: point, clickCount: 1, pressure: 1)
        }
        await mouse(.leftMouseUp, at: end, clickCount: 1)
    }

    func scroll(x: Int, y: Int, deltaX: Int, deltaY: Int) async throws {
        await mouse(.mouseMoved, at: windowPoint(x: x, y: y))
        // Positive values scroll down and right, as the agent's `scroll`.
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-deltaY),
                                    wheel2: Int32(-deltaX), wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent) else { return }
        view.scrollWheel(with: event)
        try? await Task.sleep(for: Self.eventInterval)
    }

    // MARK: Keyboard

    /// The modifiers of the agent's `key` request: the key code of the left key and the device bit
    /// that the framework needs to pass the modifier to the guest.
    private static let modifierKeys: [String: (keyCode: Int, flag: NSEvent.ModifierFlags, deviceBit: UInt)] = [
        "control": (kVK_Control, .control, 0x01), "shift": (kVK_Shift, .shift, 0x02),
        "command": (kVK_Command, .command, 0x08), "option": (kVK_Option, .option, 0x20),
    ]

    /// The keys that the agent's `key` request names with a word.
    static let namedKeys: [String: Int] = [
        "return": kVK_Return, "enter": kVK_ANSI_KeypadEnter, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete,
        "forwardDelete": kVK_ForwardDelete, "escape": kVK_Escape, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End, "pageUp": kVK_PageUp, "pageDown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
        "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
    ]

    /// The keys of a text on the keyboard layout of this Mac: a line break presses Return and a tab
    /// Tab. A character the layout cannot type fails before any key.
    static func strokes(for text: String, layout: KeyboardLayoutKeys) throws -> [GuestKeyStroke] {
        var strokes: [GuestKeyStroke] = []
        for character in text {
            switch character {
            case "\n", "\r", "\r\n": strokes.append(GuestKeyStroke(keyCode: UInt16(kVK_Return)))
            case "\t": strokes.append(GuestKeyStroke(keyCode: UInt16(kVK_Tab)))
            default:
                guard let stroke = layout.strokes[character] else {
                    throw GuestScreenError(GuestKeyboardError.cannotType(character).errorDescription ?? "")
                }
                strokes.append(stroke)
            }
        }
        return strokes
    }

    func type(_ text: String) async throws {
        let layout = KeyboardLayoutKeys.current() ?? KeyboardLayoutKeys { _, _, _ in nil }
        for (stroke, character) in zip(try Self.strokes(for: text, layout: layout), text) {
            var modifiers: [String] = []
            if stroke.shift { modifiers.append("shift") }
            if stroke.option { modifiers.append("option") }
            await press(keyCode: stroke.keyCode, modifiers: modifiers, characters: String(character))
        }
    }

    func key(_ key: String, modifiers: [String]) async throws {
        if let keyCode = Self.namedKeys[key] {
            await press(keyCode: UInt16(keyCode), modifiers: modifiers)
            return
        }
        let layout = KeyboardLayoutKeys.current() ?? KeyboardLayoutKeys { _, _, _ in nil }
        guard key.count == 1, let character = key.first, let stroke = layout.strokes[character] else {
            throw GuestScreenError("Unknown key \(key).")
        }
        // As the agent: Shift, or Option, when the layout types the character only with them.
        var all = modifiers
        if stroke.shift, !all.contains("shift") { all.append("shift") }
        if stroke.option, !all.contains("option") { all.append("option") }
        await press(keyCode: stroke.keyCode, modifiers: all, characters: key)
    }

    /// The modifiers down, the key down and up, the modifiers up in the reverse order.
    private func press(keyCode: UInt16, modifiers: [String], characters: String = "") async {
        let pressed = ["control", "option", "shift", "command"].filter(modifiers.contains).compactMap { Self.modifierKeys[$0] }
        var flags: NSEvent.ModifierFlags = []
        for modifier in pressed {
            flags.insert(modifier.flag)
            flags.insert(NSEvent.ModifierFlags(rawValue: modifier.deviceBit))
            await keyEvent(.flagsChanged, keyCode: UInt16(modifier.keyCode), flags: flags)
        }
        await keyEvent(.keyDown, keyCode: keyCode, flags: flags, characters: characters)
        await keyEvent(.keyUp, keyCode: keyCode, flags: flags, characters: characters)
        for modifier in pressed.reversed() {
            flags.remove(modifier.flag)
            flags.remove(NSEvent.ModifierFlags(rawValue: modifier.deviceBit))
            await keyEvent(.flagsChanged, keyCode: UInt16(modifier.keyCode), flags: flags)
        }
    }

    private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String = "") async {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return }
        switch type {
        case .flagsChanged: view.flagsChanged(with: event)
        case .keyDown: view.keyDown(with: event)
        default: view.keyUp(with: event)
        }
        try? await Task.sleep(for: Self.eventInterval)
    }
}
