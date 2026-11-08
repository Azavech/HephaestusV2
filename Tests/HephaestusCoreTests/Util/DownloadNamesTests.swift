import Foundation
import Testing
@testable import HephaestusCore

/// docs/web-tabs.md › Downloads and docs/builds.md › Downloads: the names of downloaded files.
@Suite("Download names")
struct DownloadNamesTests {
    @Test("Separators become underscores, the name is trimmed, an empty name becomes download")
    func safeNames() {
        #expect(DownloadNames.safeName("HephaestusV2.zip") == "HephaestusV2.zip")
        #expect(DownloadNames.safeName(" a/b:c.txt ") == "a_b_c.txt")
        #expect(DownloadNames.safeName("  ") == "download")
        #expect(DownloadNames.safeName("..") == "download")
    }

    @Test("A taken name gets (1), (2), … before its extension")
    func uniqueNames() {
        let folder = URL(fileURLWithPath: "/Users/example/Downloads", isDirectory: true)
        let taken: Set<String> = ["App.zip", "App (1).zip", "notes"]
        let isTaken: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        #expect(DownloadNames.uniqueURL(in: folder, name: "Other.zip", isTaken: isTaken).lastPathComponent == "Other.zip")
        #expect(DownloadNames.uniqueURL(in: folder, name: "App.zip", isTaken: isTaken).lastPathComponent == "App (2).zip")
        #expect(DownloadNames.uniqueURL(in: folder, name: "notes", isTaken: isTaken).lastPathComponent == "notes (1)")
    }
}
