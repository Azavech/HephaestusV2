import CoreGraphics
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Image viewer: the one-time resize of a viewer window to its image, its size
/// and when it happens, never while the window is in full screen.
@Suite("Image viewer resize")
struct ImageViewerResizeTests {
    static let visibleFrame = CGSize(width: 1920, height: 1050)

    @Test("An image that fits in 80 % of the visible frame keeps its size")
    func fits() {
        #expect(ImageViewerResize.contentSize(image: CGSize(width: 800, height: 600), visibleFrame: Self.visibleFrame)
            == CGSize(width: 800, height: 600))
    }

    @Test("A larger image is scaled down with its proportions to fit 80 % of the visible frame")
    func scaled() {
        #expect(ImageViewerResize.contentSize(image: CGSize(width: 1718, height: 1931), visibleFrame: Self.visibleFrame)
            == CGSize(width: 747, height: 840))
        #expect(ImageViewerResize.contentSize(image: CGSize(width: 3072, height: 840), visibleFrame: Self.visibleFrame)
            == CGSize(width: 1536, height: 420))
    }

    @Test("The size is never smaller than 400 × 300 pt")
    func minimum() {
        #expect(ImageViewerResize.contentSize(image: CGSize(width: 100, height: 50), visibleFrame: Self.visibleFrame)
            == CGSize(width: 400, height: 300))
        #expect(ImageViewerResize.contentSize(image: CGSize(width: 200, height: 2000), visibleFrame: Self.visibleFrame)
            == CGSize(width: 400, height: 840))
    }

    /// The answers of `shouldResize` for the full-screen states of the window, in order.
    func decisions(_ fullScreen: [Bool]) -> [Bool] {
        var resize = ImageViewerResize()
        return fullScreen.map { resize.shouldResize(isFullScreen: $0) }
    }

    @Test("A window opened outside full screen resizes once, and not after entering and leaving full screen")
    func outsideFullScreen() {
        #expect(decisions([false]) == [true])
        #expect(decisions([false, true, false]) == [true, false, false])
    }

    @Test("A window in full screen resizes only when it first leaves full screen")
    func inFullScreen() {
        var resize = ImageViewerResize()
        let opened = resize.shouldResize(isFullScreen: true)
        #expect(!opened)
        #expect(!resize.isDone)
        // Opened in full screen, Next in full screen, first exit, second entry, second exit.
        #expect(decisions([true, true, false, true, false]) == [false, false, true, false, false])
    }
}
