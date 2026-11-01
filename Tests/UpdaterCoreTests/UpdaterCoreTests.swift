import Foundation
import Testing
@testable import UpdaterCore

@Suite("AppVersion")
struct AppVersionTests {
    @Test("Display formats of docs/updater.md › Versions and display")
    func display() {
        let version = AppVersion(version: "0.4.0", build: 57)
        #expect(version.display == "v0.4.0(57)")
        #expect(version.aboutLine == "Version 0.4.0 (57)")
        #expect(AppVersion(version: "0.5.0", build: 61).display == "v0.5.0(61)")
    }

    @Test("Info.plist parsing needs a decimal CFBundleVersion")
    func infoPlist() {
        #expect(AppVersion(infoPlist: ["CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "57"]) == AppVersion(version: "0.4.0", build: 57))
        #expect(AppVersion(infoPlist: ["CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "0"])?.build == 0)
        #expect(AppVersion(infoPlist: ["CFBundleShortVersionString": "0.4.0"]) == nil)
        #expect(AppVersion(infoPlist: ["CFBundleVersion": "57a"]) == nil)
        #expect(AppVersion(infoPlist: ["CFBundleVersion": "1.2"]) == nil)
        #expect(AppVersion(infoPlist: ["CFBundleVersion": ""]) == nil)
    }

    @Test("Only builds are compared")
    func comparison() {
        #expect(AppVersion(version: "0.4.0", build: 58).isNewer(than: AppVersion(version: "0.5.0", build: 57)))
        #expect(!AppVersion(version: "1.0.0", build: 57).isNewer(than: AppVersion(version: "0.4.0", build: 57)))
    }
}

@Suite("Release manifest")
struct ReleaseManifestTests {
    static func repositoryRoot(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url
    }

    /// Docs conformance test 6 (docs/ci.md › Docs conformance tests): the only `json` block of
    /// docs/ci.md decodes as `ReleaseManifest` and passes `validate()`.
    @Test("The release.json example of docs/ci.md decodes and validates")
    func ciExample() throws {
        let text = try String(contentsOf: Self.repositoryRoot().appendingPathComponent("docs/ci.md"), encoding: .utf8)
        var blocks: [String] = []
        var inBlock = false
        var isJSON = false
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if !inBlock, line.hasPrefix("```") {
                inBlock = true
                isJSON = line == "```json"
                lines = []
            } else if inBlock, line == "```" {
                if isJSON { blocks.append(lines.joined(separator: "\n")) }
                inBlock = false
            } else if inBlock {
                lines.append(line)
            }
        }
        #expect(blocks.count == 1)
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: Data(try #require(blocks.first).utf8))
        try manifest.validate()
        #expect(manifest.version == "0.5.0")
        #expect(manifest.build == 61)
        #expect(ReleaseManifest.formatPublished(manifest.published) == "2026-10-31T14:03:00Z")
        let again = try JSONDecoder().decode(ReleaseManifest.self, from: JSONEncoder().encode(manifest))
        #expect(again == manifest)
    }

    @Test("Rules of docs/ci.md › release.json")
    func rules() throws {
        let valid = ReleaseManifest(version: "0.5.0", build: 61, sha256: String(repeating: "a", count: 64), size: 1,
                                    minimumSystemVersion: "26.0", published: Date(timeIntervalSince1970: 0), notes: "")
        try valid.validate()
        var manifest = valid
        manifest.version = "0.05.0"
        #expect(throws: ReleaseManifest.ValidationError.self) { try manifest.validate() }
        manifest = valid
        manifest.build = 0
        #expect(throws: ReleaseManifest.ValidationError.self) { try manifest.validate() }
        manifest = valid
        manifest.sha256 = String(repeating: "A", count: 64)
        #expect(throws: ReleaseManifest.ValidationError.self) { try manifest.validate() }
        manifest = valid
        manifest.minimumSystemVersion = "26.0.0.1"
        #expect(throws: ReleaseManifest.ValidationError.self) { try manifest.validate() }
        let missing = Data("{\"version\":\"0.5.0\",\"build\":61}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReleaseManifest.self, from: missing) }
        let offset = Data(("{\"version\":\"0.5.0\",\"build\":61,\"sha256\":\"\(String(repeating: "a", count: 64))\",\"size\":1,"
            + "\"minimumSystemVersion\":\"26.0\",\"published\":\"2026-10-31T14:03:00+02:00\",\"notes\":\"\",\"extra\":1}").utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReleaseManifest.self, from: offset) }
    }
}

@Suite("Decision")
struct UpdateDecisionTests {
    static let manifest = ReleaseManifest(version: "0.5.0", build: 61, sha256: String(repeating: "a", count: 64), size: 1,
                                          minimumSystemVersion: "27.0", published: Date(timeIntervalSince1970: 0), notes: "")
    static let system26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
    static let system27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)

    @Test("Every row of docs/updater.md › Decision")
    func rows() {
        #expect(UpdateDecision.decide(manifest: Self.manifest, runningBuild: 61, systemVersion: Self.system27, installFailedText: nil) == .upToDate)
        #expect(UpdateDecision.decide(manifest: Self.manifest, runningBuild: 60, systemVersion: Self.system26, installFailedText: "x")
            == .requiresNewerSystem(Self.manifest))
        #expect(UpdateDecision.decide(manifest: Self.manifest, runningBuild: 60, systemVersion: Self.system27, installFailedText: "codesign")
            == .previousInstallFailed(Self.manifest, "codesign"))
        #expect(UpdateDecision.decide(manifest: Self.manifest, runningBuild: 60, systemVersion: Self.system27, installFailedText: nil)
            == .available(Self.manifest))
    }

    @Test("System versions compare component by component, missing components being 0")
    func systemVersions() {
        #expect(UpdateDecision.compare("26", OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) == 0)
        #expect(UpdateDecision.compare("26.0.1", OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) == 1)
        #expect(UpdateDecision.compare("26.1", OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)) == -1)
    }
}

@Suite("IPC")
struct UpdaterIPCTests {
    @Test("Notification names and object of docs/updater.md › IPC")
    func names() {
        #expect(UpdaterIPC.object == "ca.azavech.hephaestusv2")
        #expect(UpdaterIPC.allNames.map(\.rawValue) == [
            "ca.azavech.hephaestusv2.updater.check", "ca.azavech.hephaestusv2.updater.install",
            "ca.azavech.hephaestusv2.updater.status", "ca.azavech.hephaestusv2.updater.ready",
            "ca.azavech.hephaestusv2.app.quitting",
        ])
        #expect(UpdaterState.allCases.map(\.rawValue) == ["idle", "checking", "upToDate", "available", "downloading", "ready", "installing", "error"])
    }

    @Test("The status userInfo round trip leaves out the values that do not apply")
    func statusRoundTrip() {
        let status = UpdaterStatus(state: .available, version: "0.5.0", build: 61)
        let info = status.userInfo(pid: 123)
        #expect(info["pid"] as? Int == 123)
        #expect(info["message"] == nil)
        #expect(UpdaterStatus(userInfo: info) == status)
        #expect(UpdaterStatus(userInfo: ["state": "unknown"]) == nil)
        #expect(UpdaterStatus.initial == UpdaterStatus(state: .idle))
    }
}

@Suite("Command line")
struct UpdaterArgumentsTests {
    @Test("Arguments of docs/updater.md › Command line")
    func valid() throws {
        let arguments = try UpdaterArguments.parse(["--app", "/Applications/HephaestusV2.app", "--pid", "123"])
        #expect(arguments == UpdaterArguments(appPath: "/Applications/HephaestusV2.app", pid: 123, intervalMinutes: 30, autoUpdate: true))
        let all = try UpdaterArguments.parse(["--auto-update", "false", "--interval", "2", "--pid", "5", "--app", "/A.app"])
        #expect(all.intervalMinutes == 5)
        #expect(!all.autoUpdate)
        #expect(try UpdaterArguments.parse(["--app", "/A.app", "--pid", "5", "--interval", "5000"]).intervalMinutes == 1440)
    }

    @Test("Usage errors", arguments: [
        [], ["--app", "/A.app"], ["--pid", "5"], ["--app", "A.app", "--pid", "5"], ["--app", "/A.app", "--pid", "x"],
        ["--app", "/A.app", "--pid", "5", "--interval", "-1"], ["--app", "/A.app", "--pid", "5", "--auto-update", "yes"],
        ["--app", "/A.app", "--pid", "5", "--verbose"], ["--app", "/A.app", "--pid"],
    ])
    func usageErrors(_ arguments: [String]) {
        #expect(throws: UpdaterArguments.UsageError.self) { try UpdaterArguments.parse(arguments) }
        #expect(UpdaterArguments.UsageError(reason: "x").message == "Updater: x")
    }
}
