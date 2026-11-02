import Foundation
import Testing
@testable import HephaestusCore

/// The symbol catalogue and its search (docs/chats.md › Symbol catalogue, › Symbol search).
@Suite("SF Symbol catalogue")
struct SFSymbolCatalogTests {
    @Test("The search of this Mac's catalogue matches keywords: filter finds line.3.horizontal.decrease.circle")
    func systemSearch() throws {
        let catalog = SFSymbolCatalog.system
        #expect(catalog.problems.isEmpty)
        #expect(catalog.contains("line.3.horizontal.decrease.circle"))
        let results = catalog.search("filter")
        #expect(results.contains("line.3.horizontal.decrease.circle"))
        // Name matches come first, then the keyword matches.
        let firstKeywordMatch = try #require(results.firstIndex { !$0.contains("filter") })
        #expect(results[..<firstKeywordMatch].allSatisfy { $0.contains("filter") })
        #expect(results[firstKeywordMatch...].allSatisfy { !$0.contains("filter") })
        #expect(!results.contains(where: SFSymbolCatalog.isLocalizedVariant))
        #expect(!catalog.search("FILTER ", excluding: ["line.3.horizontal.decrease.circle"]).contains("line.3.horizontal.decrease.circle"))
        #expect(catalog.search("  ").isEmpty)
    }

    /// Writes the two catalogue files of `folder`.
    static func writeCatalog(_ folder: URL, symbols: [String: String], releases: [String: [String: String]],
                             keywords: [String: [String]]) throws {
        let availability: [String: Any] = ["symbols": symbols, "year_to_release": releases]
        try PropertyListSerialization.data(fromPropertyList: availability, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("name_availability.plist"))
        try PropertyListSerialization.data(fromPropertyList: keywords, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("symbol_search.plist"))
    }

    @Test("A name belongs to the catalogue when its release's macOS version is at most the running one; localized variants are valid but never listed")
    func catalogFiles() throws {
        try withTemporaryDirectory { folder in
            try Self.writeCatalog(folder, symbols: [
                "star": "2019", "star.fill": "2019", "star.ar": "2019", "character.book.closed.ja": "2019", "pencil.tip": "2019",
                "sparkle": "2026", "sparkles": "2026.2", "wand": "9999",
            ], releases: [
                "2019": ["iOS": "13.0", "macOS": "10.15"], "2026": ["macOS": "27.0"], "2026.2": ["macOS": "27.2"], "9999": ["iOS": "1.0"],
            ], keywords: ["star": ["Favorite", "rating"], "sparkles": ["magic"], "wand": ["magic"]])
            let catalog = SFSymbolCatalog(folder: folder, macOSVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0))
            #expect(catalog.problems.isEmpty)
            #expect(catalog.names == ["star", "star.fill", "star.ar", "character.book.closed.ja", "pencil.tip", "sparkle", "wand"])
            #expect(catalog.contains("star.ar") && !catalog.contains("sparkles"))
            #expect(catalog.search("star") == ["star", "star.fill"])
            #expect(catalog.search("favorite") == ["star"])
            #expect(catalog.search("star fill") == ["star.fill"])
            #expect(catalog.search("magic") == ["wand"])
            #expect(catalog.search("tip") == ["pencil.tip"])
            #expect(catalog.search("book").isEmpty)
            #expect(catalog.search("s") == ["sparkle", "star", "star.fill"])
            #expect(catalog.search("s", excluding: ["star"]) == ["sparkle", "star.fill"])
        }
    }

    @Test("Unreadable files: an empty catalogue, or names without keywords, with the problems for engine.log")
    func unreadableFiles() throws {
        try withTemporaryDirectory { folder in
            let empty = SFSymbolCatalog(folder: folder, macOSVersion: ProcessInfo.processInfo.operatingSystemVersion)
            #expect(empty.names.isEmpty && empty.search("star").isEmpty)
            #expect(empty.problems.count == 2)
            #expect(empty.problems.first?.hasPrefix("name_availability.plist cannot be read: ") == true)
            try Self.writeCatalog(folder, symbols: ["star": "2019"], releases: ["2019": ["macOS": "10.15"]], keywords: [:])
            try FileManager.default.removeItem(at: folder.appendingPathComponent("symbol_search.plist"))
            let withoutKeywords = SFSymbolCatalog(folder: folder, macOSVersion: ProcessInfo.processInfo.operatingSystemVersion)
            #expect(withoutKeywords.names == ["star"] && withoutKeywords.search("star") == ["star"])
            #expect(withoutKeywords.problems.count == 1 && withoutKeywords.problems[0].hasPrefix("symbol_search.plist cannot be read: "))
        }
    }

    @Test("Localized variants end in one of the 24 script suffixes")
    func localizedVariants() {
        #expect(SFSymbolCatalog.localizationSuffixes.count == 24)
        #expect(SFSymbolCatalog.isLocalizedVariant("character.book.closed.ja"))
        #expect(SFSymbolCatalog.isLocalizedVariant("arrow.right.rtl"))
        #expect(!SFSymbolCatalog.isLocalizedVariant("pencil.tip"))
        #expect(!SFSymbolCatalog.isLocalizedVariant("star"))
    }
}
