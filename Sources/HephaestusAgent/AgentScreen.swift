import CoreGraphics
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit

/// The method `screenshot` and the geometry of the main display
/// (docs/virtual-machines.md › Methods).
enum AgentScreen {
    static let permissionMessage = "The agent has no Screen Recording permission."

    /// The pixels per point of the main display: 2 for a display the guest draws at 2x.
    static func scale() -> Double {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 else { return 1 }
        return max(1, Double(mode.pixelWidth) / Double(mode.width))
    }

    /// A point of the screenshot, in pixels from its top-left corner, as a point of the display.
    static func point(x: Double, y: Double) -> CGPoint {
        let scale = scale()
        let origin = CGDisplayBounds(CGMainDisplayID()).origin
        return CGPoint(x: origin.x + x / scale, y: origin.y + y / scale)
    }

    /// The main display as a PNG: with ScreenCaptureKit on macOS 14 and later, with Core Graphics
    /// before.
    static func screenshot() throws -> AgentResult {
        guard CGPreflightScreenCaptureAccess() else { throw AgentError(permissionMessage) }
        let image: CGImage
        if #available(macOS 14.0, *) {
            image = try captureWithScreenCaptureKit()
        } else {
            guard let captured = captureWithCoreGraphics() else {
                throw AgentError("The screen could not be captured.")
            }
            image = captured
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw AgentError("The screenshot could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AgentError("The screenshot could not be encoded.")
        }
        let pointWidth = Double(CGDisplayBounds(CGMainDisplayID()).width)
        let scale = pointWidth > 0 ? Double(image.width) / pointWidth : 1
        return AgentResult(json: ["width": image.width, "height": image.height, "scale": scale], data: data as Data)
    }

    /// `CGDisplayCreateImage`, for the guests older than macOS 14. The SDK hides the function from
    /// code built for macOS 15 and later, as SwiftPM builds this target, so it is looked up by name.
    private static func captureWithCoreGraphics() -> CGImage? {
        typealias CreateImage = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
        // -2 is RTLD_DEFAULT.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)(CGMainDisplayID())?.takeRetainedValue()
    }

    @available(macOS 14.0, *)
    private static func captureWithScreenCaptureKit() throws -> CGImage {
        let done = DispatchSemaphore(value: 0)
        let result = CaptureResult()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content, let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                result.error = error?.localizedDescription ?? "no display"
                done.signal()
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let pixelScale = Double(filter.pointPixelScale)
            configuration.width = Int((Double(filter.contentRect.width) * pixelScale).rounded())
            configuration.height = Int((Double(filter.contentRect.height) * pixelScale).rounded())
            configuration.showsCursor = true
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                result.image = image
                result.error = error?.localizedDescription
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            throw AgentError("The screen could not be captured in time.")
        }
        guard let image = result.image else {
            throw AgentError("The screen could not be captured: \(result.error ?? "unknown error").")
        }
        return image
    }

    /// The outcome of a capture, written by its completion handler before the semaphore is signalled.
    private final class CaptureResult: @unchecked Sendable {
        var image: CGImage?
        var error: String?
    }
}
