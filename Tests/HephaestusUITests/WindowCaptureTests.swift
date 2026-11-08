import AppKit
import Testing
@testable import HephaestusUI

/// docs/feedback.md › Screenshot capture, step 4: the toolbar window of a window in full screen and
/// the sheets are drawn over the bitmap at their places in the window.
@MainActor
@Suite("Window capture placement")
struct WindowCaptureTests {
    @Test("The toolbar window of a full-screen window goes over the window's top band")
    func fullScreenToolbar() {
        let window = NSRect(x: 0, y: 0, width: 1496, height: 939)
        let toolbar = NSRect(x: 0, y: 887, width: 1496, height: 52)
        #expect(WindowCapture.placement(of: toolbar, in: window) == NSRect(x: 0, y: 887, width: 1496, height: 52))
    }

    @Test("A window on another display or below the origin keeps its offset from the captured window")
    func offset() {
        let window = NSRect(x: 1920, y: -1080, width: 1920, height: 1080)
        let sheet = NSRect(x: 2630, y: -330, width: 500, height: 300)
        #expect(WindowCapture.placement(of: sheet, in: window) == NSRect(x: 710, y: 750, width: 500, height: 300))
    }
}
