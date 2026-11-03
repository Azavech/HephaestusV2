import CoreText
import Foundation
import Testing
@testable import HephaestusCore

/// The font notation, the font catalogue, its search and the nearest weight (docs/chats.md › Font
/// notation, › Font catalogue, › Font search, › Nearest weight).
@Suite("Font catalogue")
struct FontCatalogTests {
    @Test("The notation: eleven text styles, <family>/<weight>/<size>, sizes of 1 to 999 pt with at most one decimal")
    func notation() {
        #expect(FontNotation(".headline") == .textStyle(.headline))
        #expect(FontTextStyle.allCases.map(\.notation) == [".largeTitle", ".title", ".title2", ".title3", ".headline", ".subheadline",
                                                           ".body", ".callout", ".footnote", ".caption", ".caption2"])
        #expect(FontNotation.parse(".title1") == .failure(.notation))
        #expect(FontNotation.parse(".Headline") == .failure(.notation))
        #expect(FontNotation("System Rounded/Semibold/17") == .family(family: "System Rounded", weight: "Semibold", size: "17"))
        #expect(FontNotation("Avenir Next/Demi Bold/15") == .family(family: "Avenir Next", weight: "Demi Bold", size: "15"))
        for text in ["Helvetica", "Helvetica/Bold", "Helvetica/Bold/17/2", "/Bold/17", "Helvetica//17", ""] {
            #expect(FontNotation.parse(text) == .failure(.notation), "\(text)")
        }
        for size in ["17", "15.5", "17.0", "1", "999", "999.0"] {
            #expect(FontNotation.isSize(size), "\(size)")
        }
        for size in ["0.5", "1000", "15.25", "15,5", "017", "0", "", "17.", ".5", "999.5", "1e2", " 17"] {
            #expect(!FontNotation.isSize(size), "\(size)")
            #expect(FontNotation.parse("System/Bold/\(size)") == .failure(.size), "\(size)")
        }
        #expect(FontNotation("System Rounded/Semibold/17")?.label == "System Rounded · Semibold · 17 pt")
        #expect(FontNotation("Avenir Next/Demi Bold/15.5")?.label == "Avenir Next · Demi Bold · 15.5 pt")
        #expect(FontNotation(".headline")?.label == ".headline")
        #expect(FontNotation.sizeText(17) == "17" && FontNotation.sizeText(15.5) == "15.5" && FontNotation.sizeText(17.0) == "17")
        #expect(FontNotation.sizeText(0.5) == nil && FontNotation.sizeText(1000) == nil)
    }

    @Test("The system designs come first with the nine SwiftUI weights; installed families follow A–Z with their faces")
    func systemDesignsAndInstalledFamilies() throws {
        let catalog = FontCatalog(installed: FontCatalog.installed, project: [])
        #expect(Array(catalog.families.prefix(4).map(\.name)) == ["System", "System Rounded", "System Serif", "System Monospaced"])
        #expect(catalog.families[1].faces.map(\.name)
            == ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"])
        #expect(catalog.families[1].faces.map(\.weight) == [-0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62])
        let others = catalog.families.dropFirst(4).map(\.name)
        #expect(others == others.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let avenir = try #require(catalog.family(named: "Avenir Next"))
        let names = avenir.faces.map(\.name)
        for name in ["Regular", "Italic", "Medium", "Demi Bold", "Bold"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(avenir.faces.map(\.weight) == avenir.faces.map(\.weight).sorted())
        #expect(names.firstIndex(of: "Regular")! < names.firstIndex(of: "Italic")!)
        #expect(catalog.face(family: "Avenir Next", weight: "Demi Bold")?.postScriptName == "AvenirNext-DemiBold")
        #expect(catalog.contains(.family(family: "Avenir Next", weight: "Demi Bold", size: "15")))
        #expect(catalog.contains(.family(family: "System Rounded", weight: "Semibold", size: "17")))
        #expect(!catalog.contains(.family(family: "Avenir Next", weight: "Semibold", size: "15")))
        #expect(!catalog.contains(.family(family: "No Such Family", weight: "Regular", size: "15")))
        #expect(catalog.contains(.textStyle(.caption2)))
    }

    @Test("Project font files: each font of a file, named by its family; an installed family gains the faces it lacks")
    func projectFamilies() throws {
        try withTemporaryDirectory { folder in
            func write(_ name: String, _ data: Data) -> (path: String, url: URL) {
                let url = folder.appendingPathComponent(name)
                try? data.write(to: url)
                return ("Fonts/\(name)", url)
            }
            let files = [
                write("Heph-Regular.ttf", FontTestFiles.font(family: "Heph Test Sans", style: "Regular", postScriptName: "HephTestSans-Regular")),
                write("Heph-Bold.ttf", FontTestFiles.font(family: "Heph Test Sans", style: "Bold", postScriptName: "HephTestSans-Bold",
                                                          base: "Helvetica-Bold")),
                write("Again.ttf", FontTestFiles.font(family: "Heph Test Sans", style: "Regular", postScriptName: "HephTestSans-Again")),
                write("Avenir.otf", FontTestFiles.font(family: "Avenir Next", style: "Book", postScriptName: "HephAvenir-Book")),
                write("AvenirRegular.otf", FontTestFiles.font(family: "Avenir Next", style: "Regular", postScriptName: "HephAvenir-Regular")),
                write("System.ttf", FontTestFiles.font(family: "System Rounded", style: "Regular", postScriptName: "HephSystem-Regular")),
                write("Broken.ttf", Data("not a font".utf8)),
            ]
            let project = FontCatalog.projectFamilies(files: files)
            #expect(project.map(\.name) == ["Avenir Next", "Heph Test Sans"])
            let heph = try #require(project.last)
            #expect(heph.faces.map(\.name) == ["Regular", "Bold"])
            #expect(heph.faces.map(\.path) == ["Fonts/Heph-Regular.ttf", "Fonts/Heph-Bold.ttf"])
            #expect(heph.faces.map(\.postScriptName) == ["HephTestSans-Regular", "HephTestSans-Bold"])
            #expect(heph.faces[1].weight > heph.faces[0].weight && !heph.faces[0].italic)

            let catalog = FontCatalog(installed: FontCatalog.installed, project: project)
            let avenir = try #require(catalog.family(named: "Avenir Next"))
            #expect(avenir.faces.filter { $0.name == "Book" }.map(\.path) == ["Fonts/Avenir.otf"])
            #expect(avenir.faces.filter { $0.name == "Regular" }.map(\.path) == [nil])
            #expect(catalog.family(named: "System Rounded")?.faces == FontCatalog.systemWeights)
            #expect(catalog.contains(.family(family: "Heph Test Sans", weight: "Bold", size: "12")))
        }
    }

    @Test("The search: every family and text style for an empty query, system designs, then families A–Z, then text styles")
    func search() {
        let project = [FontFamily(name: "Zeta Mono", faces: [FontFace(name: "Regular", weight: 0, italic: false, postScriptName: "Z", path: "z.ttf")]),
                       FontFamily(name: "alpha Serif", faces: [FontFace(name: "Regular", weight: 0, italic: false, postScriptName: "A", path: "a.ttf")])]
        let catalog = FontCatalog(installed: [], project: project)
        let all = catalog.search("  ")
        #expect(all == ["System", "System Rounded", "System Serif", "System Monospaced", "alpha Serif", "Zeta Mono"].map { .family($0) }
            + FontTextStyle.allCases.map { .textStyle($0) })
        #expect(catalog.search("serif") == [.family("System Serif"), .family("alpha Serif")])
        #expect(catalog.search("MONO system") == [.family("System Monospaced")])
        #expect(catalog.search("large") == [.textStyle(.largeTitle)])
        #expect(catalog.search("title") == [.textStyle(.largeTitle), .textStyle(.title), .textStyle(.title2), .textStyle(.title3)])
        #expect(catalog.search("title", excludingSuggestions: [".title2", "System/Bold/17"])
            == [.textStyle(.largeTitle), .textStyle(.title), .textStyle(.title3)])
        #expect(catalog.search("system", excludingSuggestions: ["System/Bold/17"]).count == 4)
        #expect(catalog.search("nothing matches").isEmpty)
    }

    @Test("Nearest weight: the same name, else the nearest value, upright before italic on a tie")
    func nearestWeight() throws {
        let catalog = FontCatalog(installed: FontCatalog.installed, project: [])
        let avenir = try #require(catalog.family(named: "Avenir Next"))
        #expect(FontCatalog.nearestFace(name: "Semibold", value: 0.3, in: avenir)?.name == "Demi Bold")
        #expect(FontCatalog.nearestFace(name: "Bold", value: 0.4, in: avenir)?.name == "Bold")
        #expect(FontCatalog.nearestFace(name: "Black", value: 0.62, in: avenir)?.name == "Heavy")
        #expect(FontCatalog.nearestFace(name: "Italic", value: 0, in: avenir)?.name == "Italic")
        let system = try #require(catalog.family(named: "System"))
        #expect(FontCatalog.nearestFace(name: "Demi Bold", value: 0.3, in: system)?.name == "Semibold")
        #expect(FontCatalog.nearestFace(name: "Italic", value: 0, in: system)?.name == "Regular")
        let faces = [FontFace(name: "Light Italic", weight: -0.4, italic: true, postScriptName: "a", path: nil),
                     FontFace(name: "Light", weight: -0.4, italic: false, postScriptName: "b", path: nil),
                     FontFace(name: "Book", weight: 0.1, italic: false, postScriptName: "c", path: nil)]
        let family = FontFamily(name: "Test", faces: faces)
        #expect(FontCatalog.nearestFace(name: "Thin", value: -0.6, in: family)?.name == "Light")
        #expect(FontCatalog.nameFace(of: family)?.name == "Book")
        #expect(FontCatalog.nameFace(of: avenir)?.name == "Regular")
    }

    @Test("A face of a collection is rebuilt as one OpenType font that CoreText reads back")
    func fontFileWriter() throws {
        let font = CTFontCreateWithName("AvenirNext-DemiBold" as CFString, 12, nil)
        let file = try #require(FontFileWriter.data(of: font))
        #expect(!file.isCFF)
        let descriptors = try #require(CTFontManagerCreateFontDescriptorsFromData(file.data as CFData) as? [CTFontDescriptor])
        #expect(descriptors.count == 1)
        #expect(CTFontDescriptorCopyAttribute(descriptors[0], kCTFontNameAttribute) as? String == "AvenirNext-DemiBold")
        #expect(FontFileWriter.checksum(Data([0, 0, 0, 1, 0, 0, 0, 2, 1])) == 3 + 0x0100_0000)
    }
}
