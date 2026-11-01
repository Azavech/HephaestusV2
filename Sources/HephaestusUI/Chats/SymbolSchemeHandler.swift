// OWNER: ui-chats — SF Symbol markers of the chat transcript and the questions card, and the
// `hephaestus-symbol` URL scheme that draws their icons (docs/chats.md › Links, images and files).
import AppKit
import Foundation
import Synchronization
import WebKit

/// The SF Symbols of the Mac that shows the window.
enum SFSymbols {
    /// Answers already given, by name; emptied when it grows past `cacheLimit`.
    private static let availability = Mutex<[String: Bool]>([:])
    private static let cacheLimit = 1_024

    /// Whether `NSImage(systemSymbolName:accessibilityDescription:)` gives an image for the name:
    /// the `isSymbolAvailable` of the chat's Markdown.
    @Sendable static func isAvailable(_ name: String) -> Bool {
        if let known = availability.withLock({ $0[name] }) {
            return known
        }
        let available = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        availability.withLock { cache in
            if cache.count >= cacheLimit {
                cache.removeAll()
            }
            cache[name] = available
        }
        return available
    }

    /// The symbol drawn at 48 points and scale 2 as PNG; nil when the name has no symbol.
    static func png(_ name: String) -> Data? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)) else { return nil }
        let size = symbol.size
        let scale: CGFloat = 2
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                                            pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // The size in points before the context, which scales points to the bitmap's pixels.
        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        symbol.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Registered for `hephaestus-symbol` on the transcript web view: answers a GET whose host is
/// `symbol` with the PNG of the symbol named by the path, without an engine call.
@MainActor
final class SymbolSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "hephaestus-symbol"

    /// The symbol name of a request: the path without its leading `/`, percent-decoded; nil for a
    /// malformed URL.
    static func name(of request: URLRequest) -> String? {
        guard (request.httpMethod ?? "GET").uppercased() == "GET", let url = request.url,
              url.scheme?.lowercased() == scheme, url.host?.lowercased() == "symbol",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var encoded = Substring(components.percentEncodedPath)
        if encoded.hasPrefix("/") {
            encoded = encoded.dropFirst()
        }
        guard let name = String(encoded).removingPercentEncoding, !name.isEmpty else { return nil }
        return name
    }

    /// Status 200 with the PNG's `Content-Type` and `Content-Length`, and
    /// `Access-Control-Allow-Origin: *`: CSS masks load their image in CORS mode.
    static func response(url: URL, byteCount: Int) -> HTTPURLResponse? {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "image/png", "Content-Length": String(byteCount),
                                       "Access-Control-Allow-Origin": "*"])
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let name = Self.name(of: urlSchemeTask.request) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        guard let data = SFSymbols.png(name), let url = urlSchemeTask.request.url,
              let response = Self.response(url: url, byteCount: data.count)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // The answer is given at once: nothing is left to stop.
    }
}
