// OWNER: ui-code-docs — the `hephaestus-file` and `hephaestus-attachment` URL schemes of web views
// that show rendered Markdown (docs/documentation-viewer.md › Resource URL schemes, › Scheme
// handler).
import AppKit
import Foundation
import HephaestusCore
import UniformTypeIdentifiers
import WebKit

/// One instance per web view, registered for both schemes, created with the window's connection
/// and the project; it answers with `files.read` or `attachments.read`.
@MainActor
final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let fileScheme = "hephaestus-file"
    static let attachmentScheme = "hephaestus-attachment"

    let connection: any EngineConnection
    let projectID: String
    /// The tasks WebKit has not stopped, by identity.
    private var active: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    nonisolated(unsafe) private var eventTask: Task<Void, Never>?

    /// A parsed request: the scheme and the project path or data path.
    struct Request: Equatable {
        var scheme: String
        var path: String
    }

    init(connection: any EngineConnection, projectID: String) {
        self.connection = connection
        self.projectID = projectID
        super.init()
        // A `hephaestus-file` entry is dropped when a `files.changed` event of its project names
        // its path, a folder that contains it, or `""`.
        let events = connection.events
        let connectionID = ObjectIdentifier(connection as AnyObject)
        eventTask = Task { @MainActor in
            for await envelope in events where envelope.name == FilesChangedEvent.name {
                guard let payload = try? envelope.payload(FilesChangedEvent.self), payload.projectID == projectID else { continue }
                ResourceCache.invalidate(connection: connectionID, projectID: projectID, paths: payload.paths)
            }
        }
    }

    deinit {
        eventTask?.cancel()
    }

    /// Step 1: a GET whose host is `project` for `hephaestus-file` or `attachment` for
    /// `hephaestus-attachment`; the path without its leading `/`, percent-decoded. Nil for a
    /// malformed URL.
    static func parse(_ request: URLRequest) -> Request? {
        guard (request.httpMethod ?? "GET").uppercased() == "GET", let url = request.url,
              let scheme = url.scheme?.lowercased() else { return nil }
        let host: String
        switch scheme {
        case fileScheme: host = "project"
        case attachmentScheme: host = "attachment"
        default: return nil
        }
        guard url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var encoded = Substring(components.percentEncodedPath)
        if encoded.hasPrefix("/") {
            encoded = encoded.dropFirst()
        }
        guard let path = String(encoded).removingPercentEncoding, !path.isEmpty else { return nil }
        return Request(scheme: scheme, path: path)
    }

    /// The content type of a project file, from its extension.
    static func contentType(forPath path: String) -> String {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        switch fileExtension {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        default:
            if !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension), let mime = type.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        active[key] = urlSchemeTask
        guard let request = Self.parse(urlSchemeTask.request) else {
            fail(key, URLError(.noPermissionsToReadFile))
            return
        }
        let cacheKey = ResourceCache.Key(connection: ObjectIdentifier(connection as AnyObject), projectID: projectID,
                                         scheme: request.scheme, path: request.path)
        let cache = webView.window.map(ResourceCache.cache(for:))
        if let cached = cache?.value(for: cacheKey) {
            respond(key, cached)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.fetch(request) {
            case .success(let resource):
                cache?.store(resource, for: cacheKey)
                self.respond(key, resource)
            case .failure(let error):
                self.fail(key, error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // The answer of a stopped task is dropped.
        active[ObjectIdentifier(urlSchemeTask as AnyObject)] = nil
    }

    /// Step 2: the engine call of the scheme.
    private func fetch(_ request: Request) async -> Result<ResourceCache.Resource, URLError> {
        do {
            if request.scheme == Self.fileScheme {
                let file = try await connection.call(FilesRead.self, FilesRead.Params(projectID: projectID, path: request.path))
                let data: Data
                if let text = file.text {
                    data = Data(text.utf8)
                } else if let base64 = file.dataBase64, let decoded = Data(base64Encoded: base64) {
                    data = decoded
                } else {
                    return .failure(URLError(.dataLengthExceedsMaximum))
                }
                return .success(ResourceCache.Resource(data: data, contentType: Self.contentType(forPath: request.path)))
            }
            let attachment = try await connection.call(AttachmentsRead.self, AttachmentsRead.Params(projectID: projectID, path: request.path))
            guard let data = Data(base64Encoded: attachment.dataBase64) else {
                return .failure(URLError(.cannotLoadFromNetwork))
            }
            return .success(ResourceCache.Resource(data: data, contentType: attachment.contentType))
        } catch let error as EngineError {
            switch error.code {
            case .notFound: return .failure(URLError(.fileDoesNotExist))
            case .invalid, .forbidden: return .failure(URLError(.noPermissionsToReadFile))
            default: return .failure(URLError(.cannotLoadFromNetwork))
            }
        } catch {
            return .failure(URLError(.cannotLoadFromNetwork))
        }
    }

    /// Step 3: status 200, `Content-Type` and `Content-Length`, the bytes, then finished.
    private func respond(_ key: ObjectIdentifier, _ resource: ResourceCache.Resource) {
        guard let task = active.removeValue(forKey: key), let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": resource.contentType,
                                                            "Content-Length": String(resource.data.count)]) else { return }
        task.didReceive(response)
        task.didReceive(resource.data)
        task.didFinish()
    }

    /// Step 4.
    private func fail(_ key: ObjectIdentifier, _ error: URLError) {
        guard let task = active.removeValue(forKey: key) else { return }
        task.didFailWithError(error)
    }
}

/// The responses of the resource schemes, cached per window in memory, least recently used first
/// out, at most 64 MB; emptied when the window closes. Attachments never change, so their entries
/// stay until then.
@MainActor
final class ResourceCache {
    static let limit = 64 * 1_024 * 1_024

    struct Key: Hashable {
        var connection: ObjectIdentifier
        var projectID: String
        var scheme: String
        var path: String
    }

    struct Resource {
        var data: Data
        var contentType: String
    }

    private static var caches: [ObjectIdentifier: ResourceCache] = [:]
    private var entries: [Key: Resource] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private var totalBytes = 0
    private var closeObserver: NSObjectProtocol?

    /// The cache of a window, created on first use.
    static func cache(for window: NSWindow) -> ResourceCache {
        let id = ObjectIdentifier(window)
        if let cache = caches[id] { return cache }
        let cache = ResourceCache()
        caches[id] = cache
        cache.closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                     queue: .main) { _ in
            MainActor.assumeIsolated {
                if let cache = caches.removeValue(forKey: id), let observer = cache.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        return cache
    }

    /// Drops the `hephaestus-file` entries of a project named by a `files.changed` event.
    static func invalidate(connection: ObjectIdentifier, projectID: String, paths: [String]) {
        for cache in caches.values {
            cache.removeAll { key in
                key.connection == connection && key.projectID == projectID && key.scheme == ResourceSchemeHandler.fileScheme
                    && paths.contains { $0.isEmpty || key.path == $0 || key.path.hasPrefix($0 + "/") }
            }
        }
    }

    func value(for key: Key) -> Resource? {
        guard let resource = entries[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
        return resource
    }

    func store(_ resource: Resource, for key: Key) {
        guard resource.data.count <= Self.limit else { return }
        if let old = entries[key] {
            totalBytes -= old.data.count
            order.removeAll { $0 == key }
        }
        entries[key] = resource
        order.append(key)
        totalBytes += resource.data.count
        while totalBytes > Self.limit, let oldest = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalBytes -= removed.data.count
            }
        }
    }

    private func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in entries.keys where shouldRemove(key) {
            if let removed = entries.removeValue(forKey: key) {
                totalBytes -= removed.data.count
            }
            order.removeAll { $0 == key }
        }
    }
}
