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

    /// Steps 1 to 5: the frame view of the window (title bar, toolbar and content) rendered with
    /// `cacheDisplay` at the backing scale, every visible `WKWebView` snapshotted and drawn at its
    /// area, the window's sheets drawn over it, then encoded as PNG; again at 1 pixel per point
    /// when the PNG is too large. A sheet, or the background window of an alert sheet, is
    /// captured as the window it is attached to.
    static func capture(_ requested: NSWindow) async throws -> Image {
        let window = hostWindow(of: requested)
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
        if let image = render(root, of: window, onePixelPerPoint: false), image.png.count <= maximumPNGSize {
            return image
        }
        guard let image = render(root, of: window, onePixelPerPoint: true) else {
            throw Failure()
        }
        return image
    }

    // MARK: Sheets

    /// The window a sheet is attached to, through every level of sheets; for the background
    /// window of an alert sheet (a child window of the sheet), the window of that sheet.
    static func hostWindow(of window: NSWindow) -> NSWindow {
        var host = window
        if host.sheetParent == nil, let parent = host.parent, parent.sheetParent != nil {
            host = parent
        }
        while let parent = host.sheetParent {
            host = parent
        }
        return host
    }

    /// Step 4: the windows drawn over the window, back to front: each attached sheet, through
    /// every level, preceded by its visible child windows, the background macOS puts behind an
    /// alert sheet.
    private static func overlayWindows(of window: NSWindow) -> [NSWindow] {
        var result: [NSWindow] = []
        var current = window.attachedSheet
        while let sheet = current {
            result += (sheet.childWindows ?? []).filter(\.isVisible)
            result.append(sheet)
            current = sheet.attachedSheet
        }
        return result
    }

    // MARK: Rendering

    private struct WebSnapshot {
        let webView: WKWebView
        /// The web view's visible rect, in its own coordinates.
        let rect: NSRect
        let image: NSImage
    }

    private static func render(_ root: NSView, of window: NSWindow, onePixelPerPoint: Bool) -> Image? {
        guard let bitmap = bitmap(of: root, onePixelPerPoint: onePixelPerPoint) else { return nil }
        let panes = frostedPanes(in: root)
        let overlays = overlayWindows(of: window)
        if !panes.isEmpty || !overlays.isEmpty, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            fill(panes, of: root)
            for overlay in overlays {
                guard let overlayRoot = overlay.contentView?.superview ?? overlay.contentView, !overlayRoot.bounds.isEmpty,
                      let image = Self.bitmap(of: overlayRoot, onePixelPerPoint: onePixelPerPoint)
                else { continue }
                let rect = NSRect(x: overlay.frame.minX - window.frame.minX, y: overlay.frame.minY - window.frame.minY,
                                  width: overlay.frame.width, height: overlay.frame.height)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return Image(png: png, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }

    /// Step 2: the visible views of the root that blend with what is behind the window (the frosted
    /// sidebar and inspector panes); `cacheDisplay` leaves their area transparent.
    private static func frostedPanes(in view: NSView) -> [NSVisualEffectView] {
        if let effect = view as? NSVisualEffectView, effect.blendingMode == .behindWindow {
            return effect.isHiddenOrHasHiddenAncestor || effect.visibleRect.isEmpty ? [] : [effect]
        }
        return view.subviews.flatMap { frostedPanes(in: $0) }
    }

    /// Step 2: fills each pane's visible area behind the rendered pixels with the window
    /// background colour of the pane's appearance, so the pane shows opaque in the PNG.
    private static func fill(_ panes: [NSVisualEffectView], of root: NSView) {
        for pane in panes {
            var rect = pane.convert(pane.visibleRect, to: root)
            if root.isFlipped {
                rect.origin.y = root.bounds.height - rect.maxY
            }
            pane.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill(using: .destinationOver)
            }
        }
    }

    /// Step 2: the view rendered with `cacheDisplay`, at the backing scale or at 1 pixel per point.
    private static func bitmap(of root: NSView, onePixelPerPoint: Bool) -> NSBitmapImageRep? {
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
        return bitmap
    }

    /// Puts each snapshot in an image view right above its web view, so that the rendering draws
    /// it at the web view's place in the view order: views drawn over the web view (the search
    /// panel, the update banner) stay over it, as on screen (docs/feedback.md › Screenshot capture,
    /// step 3).
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
