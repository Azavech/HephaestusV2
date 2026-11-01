import Foundation
import Testing
@testable import UpdaterCore

/// docs/updater.md › IPC: the userInfo round trip of every notification and the pid filtering.
@Suite("IPC payloads")
struct IPCPayloadTests {
    /// Property-list values only, as distributed notifications require.
    func isPropertyList(_ info: [String: Any]) -> Bool {
        PropertyListSerialization.propertyList(info, isValidFor: .binary)
    }

    /// The `userInfo` as the receiver sees it: through a property list, numbers become NSNumbers.
    func received(_ info: [String: Any]) throws -> [AnyHashable: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as! [AnyHashable: Any]
    }

    @Test("app → Updater: check, install, app.quitting", arguments: [
        UpdaterRequest.check(intervalMinutes: 60, autoUpdate: false),
        .check(intervalMinutes: 15, autoUpdate: true),
        .install,
        .appQuitting(restart: true, activate: false),
        .appQuitting(restart: false, activate: true),
    ])
    func requests(_ request: UpdaterRequest) throws {
        let (name, info) = UpdaterIPC.notification(for: request, pid: 321)
        #expect(UpdaterIPC.appToUpdater.contains(name))
        #expect(isPropertyList(info))
        #expect(info["pid"] as? Int == 321)
        let decoded = UpdaterIPC.request(name: name, userInfo: try received(info), expectedPID: 321)
        #expect(decoded == request)
        // Another app process's notification is ignored.
        #expect(UpdaterIPC.request(name: name, userInfo: try received(info), expectedPID: 322) == nil)
        #expect(UpdaterIPC.request(name: name, userInfo: nil, expectedPID: 321) == nil)
        // The app never reads its own requests as messages.
        #expect(UpdaterIPC.message(name: name, userInfo: try received(info), expectedPID: 321) == nil)
    }

    @Test("The keys of each request")
    func requestKeys() {
        #expect(Set(UpdaterIPC.checkUserInfo(pid: 1, intervalMinutes: 30, autoUpdate: true).keys) == ["pid", "intervalMinutes", "autoUpdate"])
        #expect(Set(UpdaterIPC.installUserInfo(pid: 1).keys) == ["pid"])
        #expect(Set(UpdaterIPC.appQuittingUserInfo(pid: 1, restart: true, activate: false).keys) == ["pid", "restart", "activate"])
        #expect(UpdaterIPC.appQuittingUserInfo(pid: 1, restart: true, activate: false)["restart"] as? Bool == true)
        #expect(UpdaterIPC.request(name: UpdaterIPC.check, userInfo: ["pid": 1], expectedPID: 1)
            == .check(intervalMinutes: nil, autoUpdate: nil))
    }

    @Test("Updater → app: status and ready", arguments: [
        UpdaterMessage.status(UpdaterStatus(state: .idle)),
        .status(UpdaterStatus(state: .upToDate, version: "0.5.0", build: 61, message: "v0.5.0(61) requires macOS 27.0.")),
        .status(UpdaterStatus(state: .error, message: "GitHub answered HTTP 500.")),
        .status(UpdaterStatus(state: .ready, version: "0.5.0", build: 61)),
        .ready(version: "0.5.0", build: 61),
    ])
    func messages(_ message: UpdaterMessage) throws {
        let (name, info) = UpdaterIPC.notification(for: message, pid: 654)
        #expect(UpdaterIPC.updaterToApp.contains(name))
        #expect(isPropertyList(info))
        let decoded = UpdaterIPC.message(name: name, userInfo: try received(info), expectedPID: 654)
        #expect(decoded == message)
        #expect(UpdaterIPC.message(name: name, userInfo: try received(info), expectedPID: 655) == nil)
        #expect(UpdaterIPC.request(name: name, userInfo: try received(info), expectedPID: 654) == nil)
    }

    @Test("A status leaves out the values that do not apply")
    func statusKeys() {
        #expect(Set(UpdaterStatus(state: .checking).userInfo(pid: 1).keys) == ["pid", "state"])
        #expect(Set(UpdaterStatus(state: .error, version: "0.5.0", build: 61, message: "x").userInfo(pid: 1).keys)
            == ["pid", "state", "version", "build", "message"])
        #expect(Set(UpdaterIPC.readyUserInfo(pid: 1, version: "0.5.0", build: 61).keys) == ["pid", "version", "build"])
        #expect(UpdaterIPC.message(name: UpdaterIPC.ready, userInfo: ["pid": 1, "version": "0.5.0"], expectedPID: 1) == nil)
        #expect(UpdaterStatus(state: .ready, version: "0.5.0", build: 61).appVersion == AppVersion(version: "0.5.0", build: 61))
        #expect(UpdaterStatus(state: .error, message: "x").appVersion == nil)
    }
}

/// docs/updater.md › Starting the Updater, › About window, › Update-ready banner, › Settings.
@Suite("App presentation")
struct PresentationTests {
    let folder: TemporaryFolder
    let bundle: URL
    let info: [String: Any] = ["CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "57",
                               "HephaestusReleaseRepository": "Azavech/HephaestusV2"]

    init() throws {
        folder = try TemporaryFolder()
        bundle = folder.path("Applications/HephaestusV2.app")
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let updater = helpers.appendingPathComponent("Updater")
        try Data("#!/bin/sh\n".utf8).write(to: updater)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: updater.path)
    }

    func reason(_ info: [String: Any]? = nil, disabled: Bool = false) -> String? {
        UpdaterStartConditions.reason(infoPlist: info ?? self.info, disabledByEnvironment: disabled, bundleURL: bundle)
    }

    @Test("Every condition of Starting the Updater, in order")
    func startConditions() throws {
        #expect(reason() == nil)
        for build in [nil, "0", "x", "1.2"] as [String?] {
            var info = self.info
            info["CFBundleVersion"] = build
            #expect(reason(info, disabled: true) == "Updates are disabled in development builds.")
        }
        #expect(reason(disabled: true) == "Updates are disabled by HEPHAESTUS_DISABLE_UPDATER.")
        for repository in [nil, "", "Azavech", "a b/c"] as [String?] {
            var info = self.info
            info["HephaestusReleaseRepository"] = repository
            #expect(reason(info) == "Updates are unavailable: this build has no release repository.")
        }
        let updater = bundle.appendingPathComponent("Contents/Helpers/Updater")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: updater.path)
        #expect(reason() == "Updates are unavailable: the Updater is missing from the app bundle.")
        try FileManager.default.removeItem(at: updater)
        #expect(reason() == "Updates are unavailable: the Updater is missing from the app bundle.")
        var noRepository = info
        noRepository["HephaestusReleaseRepository"] = nil
        #expect(reason(noRepository) == "Updates are unavailable: this build has no release repository.")
    }

    @Test("A folder or bundle that is not writable", arguments: [true, false])
    func notWritable(_ parent: Bool) throws {
        let target = parent ? bundle.deletingLastPathComponent() : bundle
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        #expect(reason() == "Updates are unavailable: move HephaestusV2 to a folder you can write to, such as /Applications, and reopen it.")
        var noRepository = info
        noRepository["HephaestusReleaseRepository"] = nil
        #expect(reason(noRepository) == "Updates are unavailable: move HephaestusV2 to a folder you can write to, such as /Applications, and reopen it.")
    }

    typealias Input = UpdateArea.Input
    static let available = UpdaterStatus(state: .available, version: "0.5.0", build: 61)

    @Test("The rows of the About window's update area")
    func aboutRows() {
        func area(_ input: Input) -> UpdateArea { UpdateArea.about(input) }
        let reason = "Updates are disabled in development builds."
        #expect(area(Input(unavailableReason: reason, installChosen: true, checkTimedOut: true)) == UpdateArea(row: 1, text: reason))
        #expect(area(Input(installChosen: true, checkTimedOut: true, status: Self.available))
            == UpdateArea(row: 2, text: "Installing…", showsProgress: true))
        #expect(area(Input(checkTimedOut: true, awaitingCheck: true))
            == UpdateArea(row: 3, text: "The updater is not responding.", controls: .tryAgain))
        #expect(area(Input(awaitingCheck: true, status: Self.available))
            == UpdateArea(row: 4, text: "Checking for updates…", showsProgress: true))
        for state in [UpdaterState.idle, .checking] {
            #expect(area(Input(status: UpdaterStatus(state: state))) == UpdateArea(row: 4, text: "Checking for updates…", showsProgress: true))
        }
        #expect(area(Input(status: UpdaterStatus(state: .upToDate))) == UpdateArea(row: 5, text: "No update available"))
        let newer = UpdaterStatus(state: .upToDate, version: "0.5.0", build: 61, message: "v0.5.0(61) requires macOS 27.0.")
        #expect(area(Input(status: newer)) == UpdateArea(row: 6, text: "v0.5.0(61) requires macOS 27.0."))
        for state in [UpdaterState.available, .downloading, .ready] {
            let status = UpdaterStatus(state: state, version: "0.5.0", build: 61)
            #expect(area(Input(status: status, notNowClicked: true)) == UpdateArea(row: 7, text: "v0.5.0(61) available"))
            #expect(area(Input(status: status)) == UpdateArea(row: 8, text: "v0.5.0(61) available", controls: .installOrNotNow))
        }
        let error = UpdaterStatus(state: .error, message: "GitHub answered HTTP 500.")
        #expect(area(Input(status: error)) == UpdateArea(row: 9, text: "GitHub answered HTTP 500.", controls: .tryAgain))
        let failed = "The updater did not respond; the update was not installed."
        #expect(area(Input(status: UpdaterStatus(state: .ready, version: "0.5.0", build: 61), restartFailedMessage: failed))
            == UpdateArea(row: 8, text: failed, controls: .installOrNotNow))
    }

    @Test("The Settings status line shows rows 1 and 3 to 9 without row 2")
    func settingsLine() {
        #expect(UpdateArea.settingsStatusLine(Input(unavailableReason: "x")) == "x")
        #expect(UpdateArea.settingsStatusLine(Input(installChosen: true, status: Self.available)) == "v0.5.0(61) available")
        #expect(UpdateArea.settingsStatusLine(Input(status: Self.available, notNowClicked: true)) == "v0.5.0(61) available")
        #expect(UpdateArea.settingsStatusLine(Input(checkTimedOut: true)) == "The updater is not responding.")
        #expect(UpdateArea.settingsStatusLine(Input(status: UpdaterStatus(state: .upToDate))) == "No update available")
    }

    @Test("The banner texts")
    func banner() {
        let version = AppVersion(version: "0.5.0", build: 61)
        #expect(UpdaterTexts.bannerReady(version, autoUpdate: true) == "Update v0.5.0(61) ready — restarts when idle")
        #expect(UpdaterTexts.bannerReady(version, autoUpdate: false) == "Update v0.5.0(61) ready")
    }
}
