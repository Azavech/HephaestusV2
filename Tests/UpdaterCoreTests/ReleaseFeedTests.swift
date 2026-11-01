import Foundation
import Testing
@testable import UpdaterCore

/// docs/updater.md › Release feed, with stubbed GitHub answers.
@Suite("Release feed")
struct ReleaseFeedTests {
    /// A repository of its own per test, so that the stub answers never mix.
    let repository = "example/feed-\(UUID().uuidString.prefix(8))"
    var latestURL: String { "https://api.github.com/repos/\(repository)/releases/latest" }
    var manifestURL: String { "https://example.com/\(repository)/release.json" }
    var zipURL: String { "https://example.com/\(repository)/HephaestusV2.zip" }

    static let manifestJSON = Data("""
        {"version": "0.5.0", "build": 61, "sha256": "\(String(repeating: "a", count: 64))", "size": 12,
         "minimumSystemVersion": "26.0", "published": "2026-10-31T14:03:00Z", "notes": "- fix: x\\n", "extra": true}
        """.utf8)

    func releaseJSON(assets: [(String, String)]) -> Data {
        let list = assets.map { "{\"name\": \"\($0.0)\", \"browser_download_url\": \"\($0.1)\", \"size\": 1}" }
        return Data("{\"tag_name\": \"v0.5.0\", \"draft\": false, \"assets\": [\(list.joined(separator: ","))]}".utf8)
    }

    func feed() -> ReleaseFeed {
        ReleaseFeed(repository: repository, session: StubProtocol.session(), runningVersion: "0.4.0")
    }

    func expectError(_ message: String) async {
        do {
            _ = try await feed().latest()
            Issue.record("expected \(message)")
        } catch let error as UpdaterError {
            #expect(error.message == message)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("200: the release, its manifest and the zip URL; the request headers")
    func release() async throws {
        StubProtocol.set(latestURL, body: releaseJSON(assets: [("HephaestusV2.zip", zipURL), ("release.json", manifestURL)]))
        StubProtocol.set(manifestURL, body: Self.manifestJSON)
        let result = try await feed().latest()
        guard case .release(let manifest, let data, let zip) = result else {
            Issue.record("expected a release")
            return
        }
        #expect(manifest.version == "0.5.0")
        #expect(manifest.build == 61)
        #expect(data == Self.manifestJSON)
        #expect(zip.absoluteString == zipURL)
        let request = try #require(StubProtocol.requests(to: latestURL).first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "HephaestusV2-Updater/0.4.0")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 30)
    }

    @Test("404: no release yet")
    func noRelease() async throws {
        StubProtocol.set(latestURL, status: 404)
        #expect(try await feed().latest() == .noRelease)
    }

    @Test("429 and 403 with x-ratelimit-remaining 0: the rate limit message")
    func rateLimit() async throws {
        StubProtocol.set(latestURL, status: 429)
        await expectError("GitHub's rate limit was reached; the next check tries again.")
        StubProtocol.set(latestURL, status: 403, headers: ["X-RateLimit-Remaining": "0"])
        await expectError("GitHub's rate limit was reached; the next check tries again.")
    }

    @Test("Other statuses: GitHub answered HTTP <status>.")
    func otherStatus() async {
        StubProtocol.set(latestURL, status: 500)
        await expectError("GitHub answered HTTP 500.")
        StubProtocol.set(latestURL, status: 403, headers: ["X-RateLimit-Remaining": "12"])
        await expectError("GitHub answered HTTP 403.")
        StubProtocol.set(latestURL, status: 403)
        await expectError("GitHub answered HTTP 403.")
    }

    @Test("No response: The update check failed: <localized description>.")
    func networkError() async {
        StubProtocol.set(latestURL, .failure(.timedOut))
        let description = URLError(.timedOut).localizedDescription
        let trimmed = description.hasSuffix(".") ? String(description.dropLast()) : description
        await expectError("The update check failed: \(trimmed).")
    }

    @Test("A missing asset", arguments: ["release.json", "HephaestusV2.zip"])
    func missingAsset(_ name: String) async {
        let other = name == "release.json" ? ("HephaestusV2.zip", zipURL) : ("release.json", manifestURL)
        StubProtocol.set(latestURL, body: releaseJSON(assets: [other, ("\(name).sig", zipURL)]))
        StubProtocol.set(manifestURL, body: Self.manifestJSON)
        await expectError("The latest release has no \(name) asset.")
    }

    @Test("An asset that is not on HTTPS, or twice, counts as missing")
    func insecureOrDuplicateAsset() async {
        StubProtocol.set(latestURL, body: releaseJSON(assets: [("release.json", "http://example.com/release.json"), ("HephaestusV2.zip", zipURL)]))
        await expectError("The latest release has no release.json asset.")
        StubProtocol.set(latestURL, body: releaseJSON(assets: [("release.json", manifestURL), ("HephaestusV2.zip", zipURL), ("HephaestusV2.zip", zipURL)]))
        StubProtocol.set(manifestURL, body: Self.manifestJSON)
        await expectError("The latest release has no HephaestusV2.zip asset.")
    }

    @Test("An invalid release.json", arguments: [
        "not json",
        "{\"version\": \"0.5.0\"}",
        "{\"version\": \"0.5\", \"build\": 61, \"sha256\": \"\(String(repeating: "a", count: 64))\", \"size\": 12, \"minimumSystemVersion\": \"26.0\", \"published\": \"2026-10-31T14:03:00Z\", \"notes\": \"\"}",
        "{\"version\": \"0.5.0\", \"build\": 61, \"sha256\": \"abc\", \"size\": 12, \"minimumSystemVersion\": \"26.0\", \"published\": \"2026-10-31T14:03:00Z\", \"notes\": \"\"}",
    ])
    func invalidManifest(_ body: String) async {
        StubProtocol.set(latestURL, body: releaseJSON(assets: [("release.json", manifestURL), ("HephaestusV2.zip", zipURL)]))
        StubProtocol.set(manifestURL, body: Data(body.utf8))
        await expectError("The release.json of the latest release is invalid.")
    }

    @Test("A release.json above 1 MiB is invalid")
    func manifestTooLarge() async {
        StubProtocol.set(latestURL, body: releaseJSON(assets: [("release.json", manifestURL), ("HephaestusV2.zip", zipURL)]))
        StubProtocol.set(manifestURL, body: Data(repeating: 0x20, count: ReleaseFeed.manifestSizeLimit + 1))
        await expectError("The release.json of the latest release is invalid.")
    }

    @Test("A failed release.json download")
    func manifestDownloadFails() async {
        StubProtocol.set(latestURL, body: releaseJSON(assets: [("release.json", manifestURL), ("HephaestusV2.zip", zipURL)]))
        StubProtocol.set(manifestURL, status: 404)
        await expectError("GitHub answered HTTP 404.")
    }

    @Test("A 200 answer that is not a release fails the check")
    func notARelease() async {
        StubProtocol.set(latestURL, body: Data("[]".utf8))
        let error = await #expect(throws: UpdaterError.self) { try await feed().latest() }
        #expect(error?.message.hasPrefix("The update check failed: ") == true)
    }

    @Test("Release repositories of docs/ci.md › Info.plist keys")
    func repositories() async {
        #expect(ReleaseRepository.isValid("Azavech/HephaestusV2"))
        #expect(ReleaseRepository.isValid("a-b/c.d_e-f"))
        for invalid in [nil, "", "Azavech", "/HephaestusV2", "Azavech/", "a/b/c", "a_b/c", "a/b c", "a/b?x"] {
            #expect(!ReleaseRepository.isValid(invalid))
        }
        let feed = ReleaseFeed(repository: "", session: StubProtocol.session())
        #expect(feed.latestReleaseURL == nil)
        await #expect(throws: UpdaterError(UpdaterTexts.noRepository)) { try await feed.latest() }
    }
}
