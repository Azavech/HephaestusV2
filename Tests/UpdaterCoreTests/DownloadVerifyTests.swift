import Foundation
import Testing
@testable import UpdaterCore

/// docs/updater.md › Download and verification: every step and its failure, with a small bundle
/// built and signed ad hoc by the test.
@Suite("Download and verification")
struct DownloadVerifyTests {
    let folder: TemporaryFolder
    let cacheRoot: URL
    let zipURL: URL
    let runningApp: URL

    init() throws {
        folder = try TemporaryFolder()
        cacheRoot = folder.path("Caches/Updates")
        zipURL = URL(string: "https://example.com/\(UUID().uuidString)/HephaestusV2.zip")!
        runningApp = try TestBundle.make(in: folder.path("Applications"), version: "0.4.0", build: "57")
    }

    var downloader: UpdateDownloader {
        UpdateDownloader(cacheRoot: cacheRoot, session: StubProtocol.session())
    }

    /// Builds the release zip of a bundle and serves it.
    func serve(_ make: (URL) throws -> URL) throws -> (zip: Data, manifest: ReleaseManifest) {
        let source = folder.path("source-\(UUID().uuidString)")
        let item = try make(source)
        let zip = folder.path("\(UUID().uuidString).zip")
        try TestBundle.zip(item, to: zip)
        let data = try Data(contentsOf: zip)
        StubProtocol.set(zipURL.absoluteString, body: data)
        return (data, try TestBundle.manifest(for: zip))
    }

    func downloadAndVerify(_ manifest: ReleaseManifest, teamIDs: [String: String] = [:]) async throws -> URL {
        let zip = try await downloader.download(manifest, manifestData: Data("{}".utf8), zipURL: zipURL)
        let verifier = UpdateVerifier { url in teamIDs[url.lastPathComponent == "HephaestusV2.app" && url.path.contains("/expanded/") ? "new" : "running"] }
        return try await verifier.verify(zip: zip, manifest: manifest, runningApp: runningApp)
    }

    func expectFailure(_ message: String, _ manifest: ReleaseManifest, teamIDs: [String: String] = [:]) async {
        do {
            _ = try await downloadAndVerify(manifest, teamIDs: teamIDs)
            Issue.record("expected \(message)")
        } catch let error as UpdaterError {
            #expect(error.message == message)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("A valid update passes steps 1 to 9 and leaves only its build folder in the cache")
    func valid() async throws {
        let (data, manifest) = try serve { try TestBundle.make(in: $0) }
        try FileManager.default.createDirectory(at: cacheRoot.appendingPathComponent("57/expanded"), withIntermediateDirectories: true)
        try Data().write(to: cacheRoot.appendingPathComponent("stray-file"))
        let app = try await downloadAndVerify(manifest)
        let build = cacheRoot.appendingPathComponent("61")
        #expect(app.path == build.appendingPathComponent("expanded/HephaestusV2.app").path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path) == ["61"])
        #expect(try Data(contentsOf: build.appendingPathComponent("HephaestusV2.zip")) == data)
        #expect(try Data(contentsOf: build.appendingPathComponent("release.json")) == Data("{}".utf8))
        #expect(StubProtocol.requests(to: zipURL.absoluteString).count == 1)
        #expect(StubProtocol.requests(to: zipURL.absoluteString).first?.timeoutInterval == 60)
    }

    @Test("Step 2 reuses a complete zip and replaces an incomplete one")
    func reuse() async throws {
        let (data, manifest) = try serve { try TestBundle.make(in: $0) }
        _ = try await downloadAndVerify(manifest)
        _ = try await downloadAndVerify(manifest)
        #expect(StubProtocol.requests(to: zipURL.absoluteString).count == 1)
        let zip = cacheRoot.appendingPathComponent("61/HephaestusV2.zip")
        try data.prefix(10).write(to: zip)
        _ = try await downloadAndVerify(manifest)
        #expect(StubProtocol.requests(to: zipURL.absoluteString).count == 2)
        #expect(try Data(contentsOf: zip) == data)
    }

    @Test("Step 1: the cache folder cannot be created")
    func cannotSave() async throws {
        let (_, manifest) = try serve { try TestBundle.make(in: $0) }
        try FileManager.default.createDirectory(at: cacheRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: cacheRoot)
        let error = await #expect(throws: UpdaterError.self) { try await downloadAndVerify(manifest) }
        #expect(error?.message.hasPrefix("The update could not be saved: ") == true)
        #expect(error?.message.hasSuffix(".") == true)
    }

    @Test("Step 2: the download fails")
    func downloadFails() async throws {
        let (_, manifest) = try serve { try TestBundle.make(in: $0) }
        StubProtocol.set(zipURL.absoluteString, .failure(.networkConnectionLost))
        let description = URLError(.networkConnectionLost).localizedDescription
        let trimmed = description.hasSuffix(".") ? String(description.dropLast()) : description
        await expectFailure("Downloading v0.5.0(61) failed: \(trimmed).", manifest)
        StubProtocol.set(zipURL.absoluteString, status: 404)
        await expectFailure("Downloading v0.5.0(61) failed: The server answered HTTP 404.", manifest)
        #expect(!FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("61/HephaestusV2.zip").path))
    }

    @Test("Step 3: the wrong size")
    func wrongSize() async throws {
        var (_, manifest) = try serve { try TestBundle.make(in: $0) }
        manifest.size += 1
        await expectFailure("The downloaded update has the wrong size.", manifest)
    }

    @Test("Step 4: the wrong SHA-256")
    func wrongChecksum() async throws {
        var (_, manifest) = try serve { try TestBundle.make(in: $0) }
        manifest.sha256 = String(repeating: "0", count: 64)
        await expectFailure("The downloaded update does not match its SHA-256 checksum.", manifest)
    }

    @Test("Step 5: a zip that does not unpack")
    func cannotUnpack() async throws {
        let garbage = folder.path("garbage.zip")
        try Data("not a zip".utf8).write(to: garbage)
        StubProtocol.set(zipURL.absoluteString, body: try Data(contentsOf: garbage))
        await expectFailure("The downloaded update could not be unpacked.", try TestBundle.manifest(for: garbage))
    }

    @Test("Step 6: no HephaestusV2.app in the zip")
    func noApp() async throws {
        let (_, manifest) = try serve { try TestBundle.make(in: $0, name: "Other.app") }
        await expectFailure("The downloaded update does not contain HephaestusV2.app.", manifest)
    }

    @Test("Step 7: another bundle id, version or build", arguments: [
        ("ca.azavech.other", "0.5.0", "61"), ("ca.azavech.hephaestusv2", "0.5.1", "61"), ("ca.azavech.hephaestusv2", "0.5.0", "62"),
    ])
    func notTheUpdate(_ values: (String, String, String)) async throws {
        let (_, manifest) = try serve { try TestBundle.make(in: $0, identifier: values.0, version: values.1, build: values.2) }
        await expectFailure("The downloaded update is not HephaestusV2 v0.5.0(61).", manifest)
    }

    @Test("Step 8: an invalid signature")
    func invalidSignature() async throws {
        let (_, manifest) = try serve { try TestBundle.make(in: $0, sign: false) }
        await expectFailure("The downloaded update has an invalid code signature.", manifest)
        let (_, tampered) = try serve { source in
            let app = try TestBundle.make(in: source)
            try Data("extra".utf8).write(to: app.appendingPathComponent("Contents/MacOS/extra"))
            return app
        }
        await expectFailure("The downloaded update has an invalid code signature.", tampered)
    }

    @Test("Step 9: the Team ID of the running app")
    func teamID() async throws {
        let (_, manifest) = try serve { try TestBundle.make(in: $0) }
        await expectFailure("The downloaded update is signed by another team.", manifest, teamIDs: ["running": "TEAMONE", "new": "TEAMTWO"])
        await expectFailure("The downloaded update is signed by another team.", manifest, teamIDs: ["running": "TEAMONE"])
        _ = try await downloadAndVerify(manifest, teamIDs: ["running": "TEAMONE", "new": "TEAMONE"])
        _ = try await downloadAndVerify(manifest, teamIDs: ["new": "TEAMTWO"])
    }

    @Test("The Security framework reads no Team ID from an ad-hoc signature")
    func adHocTeamID() {
        #expect(UpdateVerifier.signingTeamID(of: runningApp) == nil)
    }

    @Test("SHA-256 in lowercase hexadecimal")
    func sha256() throws {
        let file = folder.path("abc")
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateDownloader.sha256Hex(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("The default cache folder")
    func cacheFolder() {
        #expect(UpdateDownloader.defaultCacheRoot(homeDirectory: "/Users/example").path
            == "/Users/example/Library/Caches/HephaestusV2/Updates")
        #expect(UpdateDownloader.buildFolder(61, in: URL(fileURLWithPath: "/tmp/u")).path == "/tmp/u/61")
    }
}
