// OWNER: ui-chats — the fonts of the font card and of the font markers of the chat transcript and
// the pinned cards, and the `hephaestus-font` URL scheme that loads their faces (docs/chats.md ›
// Font catalogue, › Links, images and files).
import CoreText
import Foundation
import HephaestusCore
import HephaestusText
import SwiftUI
import Synchronization
import WebKit

/// The faces that draw fonts on this Mac: the faces of the installed families, and the faces of
/// project families loaded through the engine, shared by every window of this Mac.
enum FontFaces {
    /// Project faces loaded so far, by `family/weight`.
    private static let loaded = Mutex<[String: CTFontDescriptor]>([:])

    /// The PostScript name of each installed face, by `family/weight`.
    private static let installed: [String: String] = {
        var names: [String: String] = [:]
        for family in FontCatalog.installed {
            for face in family.faces {
                names[key(family.name, face.name)] = face.postScriptName
            }
        }
        return names
    }()

    private static func key(_ family: String, _ weight: String) -> String {
        family + "/" + weight
    }

    static func register(family: String, weight: String, descriptor: CTFontDescriptor) {
        loaded.withLock { $0[key(family, weight)] = descriptor }
    }

    /// Whether the face is drawn from a face installed on this Mac.
    static func isInstalled(family: String, weight: String) -> Bool {
        installed[key(family, weight)] != nil
    }

    /// The face of a family other than a system design: installed on this Mac, else a project face
    /// loaded so far; nil when this Mac cannot draw it yet.
    static func ctFont(family: String, weight: String, size: CGFloat) -> CTFont? {
        if let name = installed[key(family, weight)] {
            return CTFontCreateWithName(name as CFString, size, nil)
        }
        guard let descriptor = loaded.withLock({ $0[key(family, weight)] }) else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    // MARK: SwiftUI fonts

    /// The SwiftUI weight of a weight of the system designs.
    static func systemWeight(_ name: String) -> Font.Weight? {
        switch name {
        case "Ultralight": return .ultraLight
        case "Thin": return .thin
        case "Light": return .light
        case "Regular": return .regular
        case "Medium": return .medium
        case "Semibold": return .semibold
        case "Bold": return .bold
        case "Heavy": return .heavy
        case "Black": return .black
        default: return nil
        }
    }

    /// The SwiftUI design of a system design.
    static func systemDesign(_ name: String) -> Font.Design? {
        switch name {
        case "System": return .default
        case "System Rounded": return .rounded
        case "System Serif": return .serif
        case "System Monospaced": return .monospaced
        default: return nil
        }
    }

    /// The SwiftUI style of a text style.
    static func textStyle(_ style: FontTextStyle) -> Font.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        }
    }

    /// A family's face at `size`: a system design in its weight, another family in its face;
    /// nil when this Mac cannot draw it.
    static func font(family: String, weight: String, size: CGFloat) -> Font? {
        if let design = systemDesign(family) {
            return .system(size: size, weight: systemWeight(weight) ?? .regular, design: design)
        }
        return ctFont(family: family, weight: weight, size: size).map { Font($0) }
    }

    /// The font that draws a font in the pinned font card: a text style in that style, a family
    /// font in its face at `size`, or at its own size when `size` is nil; the system font when this
    /// Mac cannot draw it.
    static func font(_ font: FontNotation, size: CGFloat?) -> Font {
        switch font {
        case .textStyle(let style):
            return .system(textStyle(style))
        case .family(let family, let weight, _):
            let points = size ?? CGFloat(font.points ?? 13)
            return self.font(family: family, weight: weight, size: points) ?? .system(size: points)
        }
    }

    /// The font of a font marker at the size of the text around it: a family font in its face, a
    /// text style in the system font with the weight of its style (docs/chats.md › Links, images
    /// and files).
    static func markerFont(_ font: FontNotation, size: CGFloat) -> Font {
        switch font {
        case .textStyle(let style):
            let weight: Font.Weight = style.cssWeight == 700 ? .bold : style.cssWeight == 500 ? .medium : .regular
            return .system(size: size, weight: weight)
        case .family:
            return self.font(font, size: size)
        }
    }
}

/// The font markers of the chat transcript and the pinned cards (docs/chats.md › Links, images and
/// files, docs/documentation-viewer.md › Font markers).
enum FontMarkers {
    /// The CSS families of the system designs.
    static let cssFamilies = ["System": "system-ui", "System Rounded": "ui-rounded", "System Serif": "ui-serif",
                              "System Monospaced": "ui-monospace"]

    /// The `fontMarker` of the chat's Markdown: every font that follows the font notation, read as
    /// the rows of the pinned font card read it.
    @Sendable static func marker(_ font: String) -> MarkdownFontMarker? {
        guard let notation = FontNotation(font) else { return nil }
        switch notation {
        case .textStyle(let style):
            return MarkdownFontMarker(font: font, label: notation.label, cssFamily: "system-ui", cssWeight: style.cssWeight)
        case .family(let family, let weight, _):
            if let cssFamily = cssFamilies[family] {
                let index = FontCatalog.systemWeights.firstIndex { $0.name == weight } ?? 3
                return MarkdownFontMarker(font: font, label: notation.label, cssFamily: cssFamily, cssWeight: 100 * (index + 1))
            }
            return MarkdownFontMarker(font: font, label: notation.label, cssFamily: "system-ui", cssWeight: 400,
                                      faceURL: FontSchemeHandler.url(family: family, weight: weight))
        }
    }
}

/// The project families of a project of the main device and the data of their files, read through
/// the window's engine connection (docs/chats.md › Font catalogue). Each face read is registered in
/// `FontFaces`.
@MainActor
final class ProjectFonts {
    let connection: any EngineConnection
    let projectID: String
    private var familiesTask: Task<[FontFamily], Never>?
    private var fileTasks: [String: Task<Data?, Never>] = [:]

    init(connection: any EngineConnection, projectID: String) {
        self.connection = connection
        self.projectID = projectID
    }

    /// `files.fonts`, called once; no family when it fails.
    func families() async -> [FontFamily] {
        if let familiesTask { return await familiesTask.value }
        let connection = connection, projectID = projectID
        let task = Task { (try? await connection.call(FilesFonts.self, FilesFonts.Params(projectID: projectID))) ?? [] }
        familiesTask = task
        return await task.value
    }

    /// Reads the files of the families and registers their faces in `FontFaces`.
    func loadFaces(of families: [FontFamily]) async {
        for family in families {
            for face in family.faces {
                _ = await descriptor(family: family.name, face: face)
            }
        }
    }

    /// The face of a project family; nil when the project has no such face or its file cannot be
    /// read.
    func descriptor(family: String, weight: String) async -> CTFontDescriptor? {
        guard let face = await families().first(where: { $0.name == family })?.faces.first(where: { $0.name == weight })
        else { return nil }
        return await descriptor(family: family, face: face)
    }

    private func descriptor(family: String, face: FontFace) async -> CTFontDescriptor? {
        guard let path = face.path, let data = await fileData(path),
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first(where: {
                  CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == face.postScriptName
              })
        else { return nil }
        FontFaces.register(family: family, weight: face.name, descriptor: descriptor)
        return descriptor
    }

    /// The data of a font file, `files.read` called once per path.
    private func fileData(_ path: String) async -> Data? {
        if let task = fileTasks[path] { return await task.value }
        let connection = connection, projectID = projectID
        let task = Task { () -> Data? in
            guard let content = try? await connection.call(FilesRead.self, FilesRead.Params(projectID: projectID, path: path)),
                  let base64 = content.dataBase64 else { return nil }
            return Data(base64Encoded: base64)
        }
        fileTasks[path] = task
        return await task.value
    }
}

/// Registered for `hephaestus-font` on the transcript web view: answers a GET whose host is `face`
/// with the font of the face named by the path, `/<family>/<weight>`, rebuilt as one OpenType font:
/// a face installed on this Mac, else a face of the chat's project read through the engine.
@MainActor
final class FontSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "hephaestus-font"

    private let fonts: ProjectFonts
    /// The tasks WebKit has not stopped, by identity.
    private var active: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    init(connection: any EngineConnection, projectID: String) {
        fonts = ProjectFonts(connection: connection, projectID: projectID)
    }

    /// The URL of a face: each name percent-encoded as `encodeURIComponent` does.
    nonisolated static func url(family: String, weight: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        func encoded(_ name: String) -> String {
            name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        }
        return "\(scheme)://face/\(encoded(family))/\(encoded(weight))"
    }

    /// The family and the weight of a request: the two components of the path, percent-decoded;
    /// nil for a malformed URL.
    nonisolated static func face(of request: URLRequest) -> (family: String, weight: String)? {
        guard (request.httpMethod ?? "GET").uppercased() == "GET", let url = request.url,
              url.scheme?.lowercased() == scheme, url.host?.lowercased() == "face",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, let family = String(parts[1]).removingPercentEncoding,
              let weight = String(parts[2]).removingPercentEncoding, !family.isEmpty, !weight.isEmpty else { return nil }
        return (family, weight)
    }

    /// Status 200 with the font's `Content-Type` and `Content-Length`, and
    /// `Access-Control-Allow-Origin: *`: WebKit loads fonts in CORS mode.
    nonisolated static func response(url: URL, byteCount: Int, isCFF: Bool) -> HTTPURLResponse? {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": isCFF ? "font/otf" : "font/ttf", "Content-Length": String(byteCount),
                                       "Access-Control-Allow-Origin": "*"])
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let face = Self.face(of: urlSchemeTask.request), let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        active[id] = urlSchemeTask
        Task {
            var font = FontFaces.ctFont(family: face.family, weight: face.weight, size: 12)
            if font == nil, let descriptor = await fonts.descriptor(family: face.family, weight: face.weight) {
                font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            }
            guard let task = active.removeValue(forKey: id) else { return }
            guard let font, let file = FontFileWriter.data(of: font),
                  let response = Self.response(url: url, byteCount: file.data.count, isCFF: file.isCFF) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(response)
            task.didReceive(file.data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }
}
