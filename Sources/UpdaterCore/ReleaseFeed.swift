import Foundation

/// The GitHub answer of `GET /repos/<owner>/<name>/releases/latest`; only the fields used.
public struct GitHubRelease: Decodable, Sendable, Hashable {
    public struct Asset: Decodable, Sendable, Hashable {
        public var name: String
        public var browserDownloadURL: URL

        public init(name: String, browserDownloadURL: URL) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var assets: [Asset]

    public init(tagName: String, assets: [Asset]) {
        self.tagName = tagName
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

/// The outcome of a feed request.
public enum FeedResult: Sendable, Equatable {
    /// The repository has no release yet (404).
    case noRelease
    case release(ReleaseManifest, manifestData: Data, zipURL: URL)
}

/// Errors of the Updater whose text is the `message` of the `error` state.
public struct UpdaterError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }

    /// Returned by the parts that are not implemented yet.
    public static let notImplemented = UpdaterError("The updater is not implemented yet.")
}

/// The release feed client (docs/updater.md › Release feed).
public struct ReleaseFeed: Sendable {
    public var repository: String
    public var session: URLSession

    public init(repository: String, session: URLSession) {
        self.repository = repository
        self.session = session
    }

    /// The latest release request, the asset checks and the manifest download.
    // STUB: release — the request, the answers of docs/updater.md › Latest release request and
    // the manifest download come with the Updater.
    public func latest() async throws -> FeedResult {
        throw UpdaterError.notImplemented
    }
}
