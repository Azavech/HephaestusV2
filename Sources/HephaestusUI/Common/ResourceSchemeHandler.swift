// OWNER: ui-code-docs — the `hephaestus-file` and `hephaestus-attachment` URL schemes of web views
// that show rendered Markdown (docs/documentation-viewer.md › Resource URL schemes, › Scheme
// handler).
import Foundation
import HephaestusCore
import WebKit

/// One instance per web view, registered for both schemes, created with the window's connection
/// and the project; it answers with `files.read` or `attachments.read`.
// STUB: ui-code-docs — the requests, the answers, the failures and the per-window cache.
final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let fileScheme = "hephaestus-file"
    static let attachmentScheme = "hephaestus-attachment"

    let connection: any EngineConnection
    let projectID: String

    init(connection: any EngineConnection, projectID: String) {
        self.connection = connection
        self.projectID = projectID
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        urlSchemeTask.didFailWithError(URLError(.cannotLoadFromNetwork))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
