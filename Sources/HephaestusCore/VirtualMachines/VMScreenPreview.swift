import Foundation

/// A virtual machine whose guest agent takes screenshots of its screen, for the previews of the
/// popover of the Virtual Machines bubble (docs/virtual-machines.md › Previews).
@MainActor
protocol GuestPreviewCapturing: AnyObject {
    /// A PNG of the guest's main display, taken by the connected agent with its `screenshot`
    /// method. Throws when no agent is connected or the agent fails.
    func capturePreviewPNG() async throws -> Data
}

/// The screenshots of the previews.
enum VMScreenPreview {
    /// How long the agent may take for one screenshot.
    static let timeout: Duration = .seconds(10)

    /// A PNG of the screen of `machine`, or nil when it takes no screenshot or the screenshot
    /// fails.
    @MainActor
    static func capture(_ machine: any GuestMachine) async -> Data? {
        guard let capturing = machine as? GuestPreviewCapturing,
              let png = try? await capturing.capturePreviewPNG(), !png.isEmpty else { return nil }
        return png
    }
}

#if arch(arm64)
extension MacGuestMachine: GuestPreviewCapturing {
    func capturePreviewPNG() async throws -> Data {
        guard let agent else { throw GuestAgentError.disconnected }
        return try await agent.request("screenshot", timeout: VMScreenPreview.timeout).data
    }
}
#endif

extension VMSession {
    /// A PNG of the screen for the preview of the popover, from the guest agent; nil while no
    /// agent is connected, and when the screenshot fails (docs/virtual-machines.md › Previews).
    public func capturePreview() async -> Data? {
        guard agent != nil else { return nil }
        return await VMScreenPreview.capture(machine)
    }
}

extension VMSetupSession {
    /// A PNG of the screen of the setup virtual machine for the preview of the popover, from the
    /// guest agent; nil while no agent is connected, and when the screenshot fails
    /// (docs/virtual-machines.md › Previews).
    public func capturePreview() async -> Data? {
        guard agent != nil else { return nil }
        return await VMScreenPreview.capture(machine)
    }
}
