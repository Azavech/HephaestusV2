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
public struct UpdaterError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    /// `<localized description>` of docs/updater.md, inserted before a final period of the
    /// message templates.
    // DOC-GAP: docs/updater.md writes `<localized description>.`; most localized descriptions end
    // with a period already, so one final period of the description is dropped to avoid "..".
    static func describe(_ error: Error) -> String {
        var text = (error as NSError).localizedDescription
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}

/// The value of the Info.plist key `HephaestusReleaseRepository` (docs/ci.md › Info.plist keys).
public enum ReleaseRepository {
    public static let infoPlistKey = "HephaestusReleaseRepository"

    /// `^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`
    public static func isValid(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let owner = parts[0].utf8.allSatisfy { isAlphanumeric($0) || $0 == 0x2D }
        let name = parts[1].utf8.allSatisfy { isAlphanumeric($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F }
        return owner && name
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

/// The release feed client (docs/updater.md › Release feed).
public struct ReleaseFeed: Sendable {
    public var repository: String
    public var session: URLSession
    /// The running app's version, sent in `User-Agent`.
    // DOC-GAP: docs/updater.md › Swift shape gives `init(repository:session:)`, but the
    // `User-Agent` header needs the running version; it is a third parameter.
    public var runningVersion: String

    public static let manifestAssetName = "release.json"
    public static let zipAssetName = "HephaestusV2.zip"
    /// Timeout of the latest release request and of the `release.json` download.
    public static let timeout: TimeInterval = 30
    /// Largest accepted `release.json`, 1 MiB.
    public static let manifestSizeLimit = 1_048_576

    public init(repository: String, session: URLSession, runningVersion: String = "0.0.0") {
        self.repository = repository
        self.session = session
        self.runningVersion = runningVersion
    }

    /// A session for the feed: no cache, no stored cookies.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// `https://api.github.com/repos/<owner>/<name>/releases/latest`.
    public var latestReleaseURL: URL? {
        guard ReleaseRepository.isValid(repository) else { return nil }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// The request of docs/updater.md › Latest release request.
    public func latestReleaseRequest() -> URLRequest? {
        guard let url = latestReleaseURL else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("HephaestusV2-Updater/\(runningVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The latest release request, the asset checks and the manifest download. Every failure is
    /// an `UpdaterError` whose message is the `error` state's message.
    public func latest() async throws -> FeedResult {
        guard let request = latestReleaseRequest() else {
            // DOC-GAP: the app does not start the Updater without a valid repository (docs/updater.md ›
            // Starting the Updater, row 4); an Updater started by hand reports the same reason.
            throw UpdaterError(UpdaterTexts.noRepository)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.checkFailed(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 404:
            return .noRelease
        case 429:
            throw UpdaterError(UpdaterTexts.rateLimit)
        case 403 where Self.rateLimitExhausted(response):
            throw UpdaterError(UpdaterTexts.rateLimit)
        default:
            throw UpdaterError("GitHub answered HTTP \(status).")
        }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            // DOC-GAP: docs/updater.md › Latest release request does not define a 200 answer that is
            // not a release; it is reported like a failed request.
            throw Self.checkFailed(error)
        }
        let manifestURL = try Self.asset(named: Self.manifestAssetName, in: release)
        let zipURL = try Self.asset(named: Self.zipAssetName, in: release)
        let manifestData = try await downloadManifest(from: manifestURL)
        let manifest: ReleaseManifest
        do {
            manifest = try JSONDecoder().decode(ReleaseManifest.self, from: manifestData)
            try manifest.validate()
        } catch {
            throw UpdaterError(UpdaterTexts.invalidManifest)
        }
        return .release(manifest, manifestData: manifestData, zipURL: zipURL)
    }

    /// The URL of the only asset named `name`.
    // DOC-GAP: docs/updater.md › Security allows HTTPS downloads only; an asset whose URL is not
    // HTTPS counts as missing.
    static func asset(named name: String, in release: GitHubRelease) throws -> URL {
        let matches = release.assets.filter { $0.name == name }
        guard matches.count == 1, let url = matches.first?.browserDownloadURL, url.scheme?.lowercased() == "https" else {
            throw UpdaterError("The latest release has no \(name) asset.")
        }
        return url
    }

    /// Downloads `release.json`: redirects followed, timeout 30 seconds, at most 1 MiB.
    // DOC-GAP: docs/updater.md › Release manifest does not define a failed manifest download; a
    // network failure reads as a failed check, another status than 200 as `GitHub answered HTTP
    // <status>.`, and a body above 1 MiB as an invalid release.json.
    func downloadManifest(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("HephaestusV2-Updater/\(runningVersion)", forHTTPHeaderField: "User-Agent")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.checkFailed(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            bytes.task.cancel()
            throw UpdaterError("GitHub answered HTTP \(status).")
        }
        guard response.expectedContentLength <= Int64(Self.manifestSizeLimit) else {
            bytes.task.cancel()
            throw UpdaterError(UpdaterTexts.invalidManifest)
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.manifestSizeLimit {
                    bytes.task.cancel()
                    throw UpdaterError(UpdaterTexts.invalidManifest)
                }
            }
        } catch let error as UpdaterError {
            throw error
        } catch {
            throw Self.checkFailed(error)
        }
        return data
    }

    /// 403 with `x-ratelimit-remaining: 0`.
    static func rateLimitExhausted(_ response: URLResponse) -> Bool {
        let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining")
        return value?.trimmingCharacters(in: .whitespaces) == "0"
    }

    /// `The update check failed: <localized description>.`
    static func checkFailed(_ error: Error) -> UpdaterError {
        UpdaterError("The update check failed: \(UpdaterError.describe(error)).")
    }
}
