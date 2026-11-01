import Foundation

// DOC-GAP: docs/updater.md › Swift shape names these three types and the steps they implement,
// not their members; the members below are placeholders for the Updater stage.

/// Steps 1 to 4 of docs/updater.md › Download and verification.
public struct UpdateDownloader: Sendable {
    /// `~/Library/Caches/HephaestusV2/Updates/`.
    public var cacheRoot: URL
    public var session: URLSession

    public init(cacheRoot: URL, session: URLSession) {
        self.cacheRoot = cacheRoot
        self.session = session
    }

    /// The default cache folder of downloaded updates.
    public static func defaultCacheRoot(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Caches/HephaestusV2/Updates", isDirectory: true)
    }

    /// Downloads the zip of `manifest` into the cache folder of its build.
    // STUB: release
    public func download(_ manifest: ReleaseManifest, manifestData: Data, zipURL: URL) async throws -> URL {
        throw UpdaterError.notImplemented
    }
}

/// Steps 5 to 9 of docs/updater.md › Download and verification; the Team ID reader is
/// injectable for tests.
public struct UpdateVerifier: Sendable {
    /// Reads the Team ID a bundle is signed with; nil when it has none.
    public var teamIDReader: @Sendable (URL) -> String?

    public init(teamIDReader: @escaping @Sendable (URL) -> String?) {
        self.teamIDReader = teamIDReader
    }

    /// Verifies the downloaded update and returns the unpacked bundle.
    // STUB: release
    public func verify(zip: URL, manifest: ReleaseManifest, runningApp: URL) async throws -> URL {
        throw UpdaterError.notImplemented
    }
}

/// Steps 5 to 8 of docs/updater.md › Restart for an update and the `install-failed` file.
public struct UpdateInstaller: Sendable {
    public init() {}

    /// Replaces the app bundle with the verified update.
    // STUB: release
    public func install(update: URL, replacing app: URL, relaunch: Bool) async throws {
        throw UpdaterError.notImplemented
    }
}
