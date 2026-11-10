import Foundation
import Testing
@testable import HephaestusCore

/// docs/virtual-machines.md › macOS versions: the answer of ipsw.me.
@Suite("macOS versions of ipsw.me")
struct MacOSVersionsTests {
    @Test("The capture gives its versions newest first, with their build, URL, size and checksum")
    func capture() throws {
        let versions = try MacOSVersions.parse(try ipswFixture())
        #expect(versions.map(\.version) == ["27.2.1", "27.2", "26.6.2", "15.6.1", "13.0", "12.4"])
        #expect(versions.map(\.build) == ["26B131", "26B123", "25G83", "24G90", "22A380", "21F79"])
        let newest = try #require(versions.first)
        #expect(newest.url == "https://updates.cdn-apple.com/2026FallFCS/c202a724-db7e-4d56-917b-110aa0226507/UniversalMac_27.2.1_26B131_Restore.ipsw")
        #expect(newest.sizeBytes == 25_595_954_706)
        #expect(newest.sha256 == "233e85a09887579d47d0b195e7db72be7f204261059c6946f719acf6b300814f")
        #expect(MacOSVersion.title(version: newest.version, build: newest.build) == "27.2.1 (26B131)")
    }

    @Test("Versions are ordered number by number, then by release date, whatever the order of the answer")
    func order() throws {
        let json = """
        {"firmwares": [
          {"version": "26.6.2", "buildid": "25G83", "url": "https://updates.cdn-apple.com/a.ipsw", "releasedate": "2026-08-17T17:43:14Z"},
          {"version": "9.10", "buildid": "X1", "url": "https://updates.cdn-apple.com/b.ipsw", "releasedate": "2020-01-01T00:00:00Z"},
          {"version": "27.2", "buildid": "26B123", "url": "https://updates.cdn-apple.com/c.ipsw", "releasedate": "2026-10-26T18:14:17Z"},
          {"version": "27.2", "buildid": "26B124", "url": "https://updates.cdn-apple.com/d.ipsw", "releasedate": "2026-10-28T18:14:17Z"},
          {"version": "9.9", "buildid": "X0", "url": "https://updates.cdn-apple.com/e.ipsw", "releasedate": "2021-01-01T00:00:00Z"},
          {"version": "27.2.1", "buildid": "26B131", "url": "https://updates.cdn-apple.com/f.ipsw", "releasedate": "2026-11-09T18:23:25Z"}
        ]}
        """
        let versions = try MacOSVersions.parse(Data(json.utf8))
        #expect(versions.map(\.build) == ["26B131", "26B124", "26B123", "25G83", "X1", "X0"])
        #expect(MacOSVersions.compare("27.2.1", "27.2") == .orderedDescending)
        #expect(MacOSVersions.compare("27.2", "26.6.2") == .orderedDescending)
        #expect(MacOSVersions.compare("9.10", "9.9") == .orderedDescending)
        #expect(MacOSVersions.compare("13.0", "13") == .orderedSame)
    }

    @Test("An element without version, build or https URL is skipped, and the first of a build is kept")
    func skippedElements() throws {
        let json = """
        {"firmwares": [
          {"version": "27.2", "buildid": "26B123", "url": "https://updates.cdn-apple.com/first.ipsw", "filesize": 12, "sha256sum": "ABCDEF"},
          {"version": "27.2", "buildid": "26B123", "url": "https://updates.cdn-apple.com/second.ipsw"},
          {"version": "", "buildid": "A", "url": "https://updates.cdn-apple.com/x.ipsw"},
          {"version": "27.1", "buildid": "", "url": "https://updates.cdn-apple.com/x.ipsw"},
          {"version": "27.0", "buildid": "B", "url": "http://updates.cdn-apple.com/x.ipsw"},
          {"version": "26.9", "buildid": "C"},
          {"version": 26, "buildid": "D", "url": "https://updates.cdn-apple.com/x.ipsw"},
          "text",
          {"version": "26.0", "buildid": "25A354", "url": "https://updates.cdn-apple.com/kept.ipsw",
           "sha256sum": "50D858E0985ECC7F60418AAF0CC5AB587F42C2570A884095A9E8CCACD0F6545C", "signed": false}
        ]}
        """
        let versions = try MacOSVersions.parse(Data(json.utf8))
        #expect(versions == [
            MacOSVersion(version: "27.2", build: "26B123", url: "https://updates.cdn-apple.com/first.ipsw", sizeBytes: 12, sha256: nil),
            MacOSVersion(version: "26.0", build: "25A354", url: "https://updates.cdn-apple.com/kept.ipsw", sizeBytes: 0,
                         sha256: "50d858e0985ecc7f60418aaf0cc5ab587f42c2570a884095a9e8ccacd0f6545c"),
        ])
    }

    @Test("An answer that is not an object with a firmwares array is refused")
    func unexpectedAnswers() {
        for text in ["", "[]", "{}", #"{"firmwares": {}}"#, "<html>"] {
            #expect(throws: MacOSVersions.UnexpectedAnswer.self) { try MacOSVersions.parse(Data(text.utf8)) }
        }
        #expect((try? MacOSVersions.parse(Data(#"{"firmwares": []}"#.utf8))) == [])
    }

    @Test("The failure of the list names ipsw.me and the reason, without a doubled period")
    func unavailableMessage() {
        #expect(MacOSVersions.unavailable("HTTP 503") == EngineError(.unavailable, "The macOS versions cannot be read from ipsw.me: HTTP 503."))
        #expect(MacOSVersions.unavailable("The Internet connection appears to be offline.").message
            == "The macOS versions cannot be read from ipsw.me: The Internet connection appears to be offline.")
    }
}
