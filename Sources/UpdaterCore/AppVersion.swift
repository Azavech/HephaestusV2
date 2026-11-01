import Foundation

/// The version and build of the app or of a release (docs/updater.md › Versions and display).
/// Only builds are compared; version strings are shown and checked for equality.
public struct AppVersion: Sendable, Hashable, Codable {
    /// `CFBundleShortVersionString`, `X.Y.Z`.
    public var version: String
    /// `CFBundleVersion`, a decimal integer.
    public var build: Int

    public init(version: String, build: Int) {
        self.version = version
        self.build = build
    }

    /// Reads `CFBundleShortVersionString` and `CFBundleVersion`; nil when `CFBundleVersion` is
    /// missing or not a decimal integer.
    // DOC-GAP: docs/updater.md › Swift shape does not say what a missing
    // CFBundleShortVersionString gives; it reads as "".
    public init?(infoPlist: [String: Any]) {
        guard let build = AppVersion.decimalBuild(infoPlist["CFBundleVersion"]) else { return nil }
        self.version = infoPlist["CFBundleShortVersionString"] as? String ?? ""
        self.build = build
    }

    /// `v<version>(<build>)`, for example `v0.4.0(57)`.
    public var display: String { "v\(version)(\(build))" }

    /// `Version <version> (<build>)`, for example `Version 0.4.0 (57)`.
    public var aboutLine: String { "Version \(version) (\(build))" }

    /// True when this build is greater than `other`'s build.
    public func isNewer(than other: AppVersion) -> Bool {
        build > other.build
    }

    /// A string of decimal digits that fits in `Int`.
    static func decimalBuild(_ value: Any?) -> Int? {
        if let text = value as? String {
            guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            return Int(text)
        }
        if let number = value as? Int, number >= 0 {
            return number
        }
        return nil
    }
}
