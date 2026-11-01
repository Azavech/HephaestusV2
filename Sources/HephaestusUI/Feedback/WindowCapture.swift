// OWNER: ui-shell — the in-process window capture of docs/feedback.md › Screenshot capture, used by
// debug_screenshot (App/DebugUI.swift) and by the Feedback flow (Feedback/FeedbackController.swift).
import AppKit
import WebKit

/// Renders a window into a PNG inside the app process, without screen-capture APIs, so no screen
/// recording permission is needed and offscreen windows render as on a display
/// (docs/feedback.md › Screenshot capture).
@MainActor
enum WindowCapture {
    /// A rendered window: the PNG and its size in pixels.
    struct Image {
        let png: Data
        let width: Int
        let height: Int
    }

    /// The capture produced no bitmap.
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "The window could not be captured." }
    }

    /// PNGs larger than this many bytes are rendered again at 1 pixel per point: the size up to
    /// which a chat message passes an image to Claude as an image block.
    static let maximumPNGSize = 5_000_000

    /// Steps 1 to 4: the frame view of the window (title bar, toolbar and content) rendered with
    /// `cacheDisplay` at the backing scale, every visible `WKWebView` snapshotted and drawn at its
    /// area, then encoded as PNG; again at 1 pixel per point when the PNG is too large.
    static func capture(_ window: NSWindow) async throws -> Image {
        guard let root = window.contentView?.superview ?? window.contentView, !root.bounds.isEmpty else {
            throw Failure()
        }
        let snapshots = await webSnapshots(in: root)
        // The snapshots and the rendering run in the same main-queue turn, so the covers are never
        // displayed.
        let covers = cover(snapshots)
        defer {
            for cover in covers {
                cover.removeFromSuperview()
            }
        }
        if let image = render(root, onePixelPerPoint: false), image.png.count <= maximumPNGSize {
            return image
        }
        guard let image = render(root, onePixelPerPoint: true) else {
            throw Failure()
        }
        return image
    }

    // MARK: Rendering

    private struct WebSnapshot {
        let webView: WKWebView
        /// The web view's visible rect, in its own coordinates.
        let rect: NSRect
        let image: NSImage
    }

    private static func render(_ root: NSView, onePixelPerPoint: Bool) -> Image? {
        let bounds = root.bounds
        let bitmap: NSBitmapImageRep
        if onePixelPerPoint {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width.rounded(.up)),
                                             pixelsHigh: Int(bounds.height.rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                             bitsPerPixel: 0) else { return nil }
            rep.size = bounds.size
            bitmap = rep
        } else {
            guard let rep = root.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            bitmap = rep
        }
        root.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return Image(png: png, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }

    /// Puts each snapshot in an image view right above its web view, so that the rendering draws
    /// it at the web view's place in the view order: views drawn over the web view (the search
    /// panel, the update banner) stay over it, as on screen.
    // DOC-GAP: docs/feedback.md › Screenshot capture, step 3, draws the snapshots over the result
    // of step 2, which also covers the views drawn above the web views; they are drawn in the
    // web views' place instead.
    private static func cover(_ snapshots: [WebSnapshot]) -> [NSView] {
        snapshots.compactMap { snapshot in
            guard let superview = snapshot.webView.superview else { return nil }
            let cover = NSImageView(frame: snapshot.webView.convert(snapshot.rect, to: superview))
            cover.image = snapshot.image
            cover.imageScaling = .scaleAxesIndependently
            cover.imageFrameStyle = .none
            superview.addSubview(cover, positioned: .above, relativeTo: snapshot.webView)
            return cover
        }
    }

    // MARK: Web views

    /// Step 3: every web view that is not hidden and has a non-empty visible rect, snapshotted with
    /// `takeSnapshot(with:)`; a snapshot that fails or takes more than 2 seconds is left out.
    private static func webSnapshots(in root: NSView) async -> [WebSnapshot] {
        var result: [WebSnapshot] = []
        for webView in webViews(in: root) where !webView.isHiddenOrHasHiddenAncestor && !webView.visibleRect.isEmpty {
            let visible = webView.visibleRect
            guard let image = await snapshot(webView, rect: visible) else { continue }
            result.append(WebSnapshot(webView: webView, rect: visible, image: image))
        }
        return result
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        if let webView = view as? WKWebView {
            return [webView]
        }
        return view.subviews.flatMap { webViews(in: $0) }
    }

    private static func snapshot(_ webView: WKWebView, rect: NSRect) async -> NSImage? {
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            webView.takeSnapshot(with: configuration) { image, _ in
                if once.claim() {
                    continuation.resume(returning: image)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if once.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Lets exactly one of the snapshot's completion and its timeout resume the continuation; both
    /// run on the main thread.
    private final class ResumeOnce: @unchecked Sendable {
        private var claimed = false

        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
