import Darwin
import Foundation
import Testing
@testable import UpdaterCore

/// docs/updater.md › Restart for an update, steps 5 to 8, and › Install failure.
@Suite("Installer")
struct InstallerTests {
    final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func record(_ executable: String, _ arguments: [String]) {
            lock.lock()
            calls.append([executable] + arguments)
            lock.unlock()
        }
        var all: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    let folder: TemporaryFolder
    let app: URL
    let cacheRoot: URL
    let update: URL
    let launches = Launches()

    init() throws {
        folder = try TemporaryFolder()
        app = folder.path("Applications/HephaestusV2.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: app.appendingPathComponent("Contents/version"))
        cacheRoot = folder.path("Updates")
        update = cacheRoot.appendingPathComponent("61/expanded/HephaestusV2.app")
        try FileManager.default.createDirectory(at: update.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: update.appendingPathComponent("Contents/version"))
        try FileManager.default.createSymbolicLink(atPath: update.appendingPathComponent("Contents/link").path, withDestinationPath: "version")
        for path in [update.path, update.appendingPathComponent("Contents/version").path, update.appendingPathComponent("Contents/MacOS").path]
        where !Self.setQuarantine(path) {
            throw UpdaterError("Setting the quarantine attribute of \(path) failed.")
        }
    }

    func installer(environment: [String: String] = [:]) -> UpdateInstaller {
        let launches = launches
        return UpdateInstaller(cacheRoot: cacheRoot, environment: environment, launcher: { executable, arguments in
            launches.record(executable, arguments)
            return 0
        })
    }

    static func setQuarantine(_ path: String) -> Bool {
        let value = "0081;00000000;Test;"
        return setxattr(path, UpdateInstaller.quarantineAttribute, value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0
    }

    static func hasQuarantine(_ path: String) -> Bool {
        getxattr(path, UpdateInstaller.quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    @Test("A restart replaces the bundle, removes the quarantine, relaunches with the overrides and deletes the build folder")
    func restart() async throws {
        let environment = ["HEPHAESTUS_DATA_DIR": "/tmp/data dir", "HEPHAESTUS_DISABLE_UPDATER": "0", "PATH": "/usr/bin", "HOME": "/Users/example"]
        let outcome = await installer(environment: environment).install(update: update, build: 61, replacing: app, relaunch: true, activate: false)
        #expect(outcome == .installed)
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/version"), encoding: .utf8) == "new")
        for path in [app.path, app.appendingPathComponent("Contents/version").path, app.appendingPathComponent("Contents/MacOS").path] {
            #expect(!Self.hasQuarantine(path))
        }
        #expect(launches.all == [["/usr/bin/open", "-g", "--env", "HEPHAESTUS_DATA_DIR=/tmp/data dir", "--env",
                                  "HEPHAESTUS_DISABLE_UPDATER=0", app.path]])
        #expect(!FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("61").path))
    }

    @Test("An active app relaunches without -g")
    func activeRestart() async {
        let outcome = await installer().install(update: update, build: 61, replacing: app, relaunch: true, activate: true)
        #expect(outcome == .installed)
        #expect(launches.all == [["/usr/bin/open", app.path]])
    }

    @Test("Install on quit does not relaunch")
    func installOnQuit() async throws {
        let outcome = await installer().install(update: update, build: 61, replacing: app, relaunch: false, activate: false)
        #expect(outcome == .installed)
        #expect(launches.all.isEmpty)
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/version"), encoding: .utf8) == "new")
    }

    @Test("A failed replacement writes install-failed and relaunches the unchanged app for a restart",
          arguments: [true, false])
    func failure(_ restart: Bool) async throws {
        try FileManager.default.removeItem(at: update)
        let outcome = await installer().install(update: update, build: 61, replacing: app, relaunch: restart, activate: true)
        guard case .failed(let text) = outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(!text.isEmpty)
        let file = cacheRoot.appendingPathComponent("61/install-failed")
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/version"), encoding: .utf8) == "old")
        #expect(launches.all == (restart ? [["/usr/bin/open", app.path]] : []))
    }
}
