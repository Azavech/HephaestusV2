import Foundation
import Security

/// Steps 5 to 9 of docs/updater.md › Download and verification: unpacking, the bundle, its
/// Info.plist, its signature and its Team ID. The Team ID reader is injectable for tests.
public struct UpdateVerifier: Sendable {
    /// Reads the Team ID a bundle is signed with; nil when it has none (ad-hoc or unsigned).
    public var teamIDReader: @Sendable (URL) -> String?

    public static let bundleIdentifier = "ca.azavech.hephaestusv2"
    public static let appName = "HephaestusV2.app"
    public static let expandedName = "expanded"

    public init(teamIDReader: @escaping @Sendable (URL) -> String? = { UpdateVerifier.signingTeamID(of: $0) }) {
        self.teamIDReader = teamIDReader
    }

    /// Verifies `<build>/HephaestusV2.zip` and returns `<build>/expanded/HephaestusV2.app`. A
    /// failure throws an `UpdaterError` with the step's message; the caller deletes `<build>/`.
    public func verify(zip: URL, manifest: ReleaseManifest, runningApp: URL) async throws -> URL {
        let version = AppVersion(version: manifest.version, build: manifest.build)
        let manager = FileManager.default
        let expanded = zip.deletingLastPathComponent().appendingPathComponent(Self.expandedName, isDirectory: true)

        // Step 5: unpack into a fresh `expanded/`.
        if manager.fileExists(atPath: expanded.path) {
            do {
                try manager.removeItem(at: expanded)
            } catch {
                throw UpdaterError(UpdaterTexts.cannotUnpack)
            }
        }
        guard await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, expanded.path]) == 0 else {
            throw UpdaterError(UpdaterTexts.cannotUnpack)
        }

        // Step 6: `expanded/HephaestusV2.app` is a folder (not a link to one).
        let app = expanded.appendingPathComponent(Self.appName, isDirectory: true)
        guard (try? manager.attributesOfItem(atPath: app.path))?[.type] as? FileAttributeType == .typeDirectory else {
            throw UpdaterError(UpdaterTexts.noApp)
        }

        // Step 7: bundle id, version and build.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == manifest.version,
              info["CFBundleVersion"] as? String == String(manifest.build)
        else { throw UpdaterError(UpdaterTexts.notTheUpdate(version)) }

        // Step 8: the signature.
        guard await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdaterError(UpdaterTexts.invalidSignature)
        }

        // Step 9: a running app signed with a Team ID accepts only the same Team ID.
        if let required = teamIDReader(runningApp), teamIDReader(app) != required {
            throw UpdaterError(UpdaterTexts.otherTeam)
        }
        return app
    }

    /// The Team ID of a signed bundle, read with the Security framework; nil without one.
    public static func signingTeamID(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        let value = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return value?.isEmpty == false ? value : nil
    }
}
