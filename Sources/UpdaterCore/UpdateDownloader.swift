import CryptoKit
import Foundation

/// Steps 1 to 4 of docs/updater.md › Download and verification: the cache folder of the build,
/// the download of `HephaestusV2.zip` (or the reuse of a complete one), its size and its SHA-256.
public struct UpdateDownloader: Sendable {
    /// `~/Library/Caches/HephaestusV2/Updates/`.
    public var cacheRoot: URL
    public var session: URLSession

    public static let zipName = "HephaestusV2.zip"
    public static let manifestName = "release.json"
    /// Request timeout of the zip download.
    public static let requestTimeout: TimeInterval = 60
    /// Resource timeout of the zip download, 30 minutes.
    public static let resourceTimeout: TimeInterval = 30 * 60

    public init(cacheRoot: URL, session: URLSession) {
        self.cacheRoot = cacheRoot
        self.session = session
    }

    /// The default cache folder of downloaded updates; it does not move with `HEPHAESTUS_DATA_DIR`.
    public static func defaultCacheRoot(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Caches/HephaestusV2/Updates", isDirectory: true)
    }

    /// A session for the zip download: no cache, the resource timeout of 30 minutes.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }

    /// `<cacheRoot>/<build>/`.
    public func buildFolder(_ build: Int) -> URL {
        Self.buildFolder(build, in: cacheRoot)
    }

    public static func buildFolder(_ build: Int, in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(String(build), isDirectory: true)
    }

    /// Runs steps 1 to 4 and returns `<build>/HephaestusV2.zip`. A failure throws an
    /// `UpdaterError` with the step's message; the caller deletes `<build>/`.
    public func download(_ manifest: ReleaseManifest, manifestData: Data, zipURL: URL) async throws -> URL {
        let version = AppVersion(version: manifest.version, build: manifest.build)
        let folder = buildFolder(manifest.build)
        let zip = folder.appendingPathComponent(Self.zipName)

        // Step 1: the cache folder of the build; every other entry of the cache root goes.
        do {
            try prepare(folder)
        } catch {
            throw UpdaterError(UpdaterTexts.cannotSave(error))
        }

        // Step 2: reuse a complete zip, or download it to a temporary file moved into place.
        var digest: (size: Int, sha256: String)? = Self.fingerprint(of: zip)
        if digest?.size != manifest.size || digest?.sha256 != manifest.sha256 {
            do {
                try await fetch(zipURL, to: zip)
            } catch {
                throw UpdaterError(UpdaterTexts.downloadFailed(version, error))
            }
            digest = nil
        }
        do {
            try manifestData.write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
        } catch {
            throw UpdaterError(UpdaterTexts.downloadFailed(version, error))
        }

        // Step 3: the size.
        let size = digest?.size ?? Self.fileSize(of: zip)
        guard size == manifest.size else { throw UpdaterError(UpdaterTexts.wrongSize) }

        // Step 4: the SHA-256 in lowercase hexadecimal.
        let sha256 = digest?.sha256 ?? (try? Self.sha256Hex(of: zip))
        guard sha256 == manifest.sha256 else { throw UpdaterError(UpdaterTexts.wrongChecksum) }
        return zip
    }

    /// Creates `folder` and deletes every other entry of the cache root.
    func prepare(_ folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in try manager.contentsOfDirectory(atPath: cacheRoot.path) where name != folder.lastPathComponent {
            try manager.removeItem(at: cacheRoot.appendingPathComponent(name))
        }
    }

    /// Downloads `url` (redirects followed) and moves the complete file to `destination`; an answer
    /// that is not 2xx fails step 2 (docs/updater.md › Download and verification).
    func fetch(_ url: URL, to destination: URL) async throws {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        let (temporary, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: temporary)
            throw HTTPStatusError(status: status)
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temporary, to: destination)
    }

    /// The size and SHA-256 of a regular file; nil when it does not exist or cannot be read.
    static func fingerprint(of url: URL) -> (size: Int, sha256: String)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let sha256 = try? sha256Hex(of: url)
        else { return nil }
        return (size, sha256)
    }

    static func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size].flatMap { ($0 as? NSNumber)?.intValue }
    }

    /// The SHA-256 of a file in lowercase hexadecimal, read in 1 MiB chunks.
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A download answered with another status than 2xx.
struct HTTPStatusError: Error, LocalizedError {
    var status: Int
    var errorDescription: String? { "The server answered HTTP \(status)." }
}
