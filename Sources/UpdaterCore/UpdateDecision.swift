import Foundation

/// The outcome of a check (docs/updater.md › Decision).
public enum UpdateDecision: Sendable, Equatable {
    case upToDate
    case requiresNewerSystem(ReleaseManifest)
    case previousInstallFailed(ReleaseManifest, String)
    case available(ReleaseManifest)

    /// The first row of the decision table that holds.
    /// - Parameters:
    ///   - runningBuild: `CFBundleVersion` of the app, read once at start.
    ///   - systemVersion: the running macOS version.
    ///   - installFailedText: the text of the `install-failed` file of the manifest's build in
    ///     the cache folder, nil when there is none.
    // DOC-GAP: docs/updater.md › Swift shape writes `static func decide(...)` without its
    // parameters; these are the inputs the decision table names.
    public static func decide(manifest: ReleaseManifest, runningBuild: Int, systemVersion: OperatingSystemVersion,
                              installFailedText: String?) -> UpdateDecision {
        if manifest.build <= runningBuild {
            return .upToDate
        }
        if compare(manifest.minimumSystemVersion, systemVersion) > 0 {
            return .requiresNewerSystem(manifest)
        }
        if let installFailedText {
            return .previousInstallFailed(manifest, installFailedText)
        }
        return .available(manifest)
    }

    /// Compares a version string with the running system version, component by component,
    /// missing components being 0. Returns 1 when `required` is above the system version.
    static func compare(_ required: String, _ system: OperatingSystemVersion) -> Int {
        var parts = required.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        let running = [system.majorVersion, system.minorVersion, system.patchVersion]
        for (lhs, rhs) in zip(parts, running) where lhs != rhs {
            return lhs > rhs ? 1 : -1
        }
        return 0
    }
}
