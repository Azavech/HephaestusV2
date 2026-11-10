import Foundation

/// A screenshot of the screen of a setup virtual machine: a PNG of the display's pixels.
public struct GuestScreenshot: Sendable, Hashable {
    public var png: Data
    public var width: Int
    public var height: Int

    public init(png: Data, width: Int, height: Int) {
        self.png = png
        self.width = width
        self.height = height
    }
}

/// The failure of an action through the screen, with the message the VM tools give
/// (docs/virtual-machines.md › Screen of the setup virtual machine).
public struct GuestScreenError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// The screen of a setup virtual machine, which the VM tools drive while its agent is not
/// connected: a screenshot and the events of the mouse and the keyboard, as the user's
/// (docs/virtual-machines.md › Screen of the setup virtual machine). Coordinates are pixels of the
/// screenshot from its top-left corner; `key` and `modifiers` are those of the agent's `key`
/// request. Main actor only, as the framework's views.
@MainActor
public protocol GuestScreen: AnyObject {
    /// `name` is the virtual machine's name, for the messages.
    func screenshot(name: String) async throws -> GuestScreenshot
    func click(x: Int, y: Int, button: String, count: Int) async throws
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws
    func scroll(x: Int, y: Int, deltaX: Int, deltaY: Int) async throws
    func type(_ text: String) async throws
    func key(_ key: String, modifiers: [String]) async throws
    /// The setup has ended: the screen lets go of the virtual machine.
    func close()
}

/// Makes the screen of a setup virtual machine. The app gives the engine one that drives a
/// `VZVirtualMachineView` of a window never shown; tests give a stand-in
/// (docs/architecture.md › Engine configuration).
public protocol GuestScreenProviding: Sendable {
    /// The screen of `machine`, or nil when it has none, as a stand-in machine without a framework
    /// virtual machine.
    @MainActor func screen(for machine: any GuestMachine) -> (any GuestScreen)?
}
