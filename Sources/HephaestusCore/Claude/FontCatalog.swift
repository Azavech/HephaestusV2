import CoreText
import Foundation

/// The font catalogue of a project on a Mac (docs/chats.md › Font catalogue): the system designs,
/// the families installed on the Mac, the families of the project's font files and the text
/// styles, with the search (› Font search) and the nearest weight (› Nearest weight). The engine
/// checks the suggestions of `chats.postFont` with it; the pinned font card and the font markers
/// use it.
public struct FontCatalog: Sendable {
    /// The system designs, in the order of the search.
    public static let systemDesigns = ["System", "System Rounded", "System Serif", "System Monospaced"]

    /// The nine weights of the system designs, with the values of the SwiftUI weights.
    public static let systemWeights: [FontFace] = [
        ("Ultralight", -0.8), ("Thin", -0.6), ("Light", -0.4), ("Regular", 0), ("Medium", 0.23), ("Semibold", 0.3),
        ("Bold", 0.4), ("Heavy", 0.56), ("Black", 0.62),
    ].map { FontFace(name: $0.0, weight: $0.1, italic: false, postScriptName: "", path: nil) }

    /// The extensions of a project's font files, compared in lowercase.
    public static let fontFileExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// The families installed on this Mac, read the first time they are needed and kept until the
    /// app quits.
    public static let installed: [FontFamily] = readInstalledFamilies()

    /// The families: the system designs, then the other families in alphabetical order.
    public let families: [FontFamily]
    private let positions: [String: Int]

    /// The catalogue of the installed families and the project families: a project family with
    /// the name of an installed family adds the faces whose style name the installed one lacks;
    /// a family named like a system design is left out.
    public init(installed: [FontFamily], project: [FontFamily]) {
        var merged: [String: FontFamily] = [:]
        for family in installed + project where !Self.systemDesigns.contains(family.name) {
            guard var existing = merged[family.name] else {
                merged[family.name] = family
                continue
            }
            let names = Set(existing.faces.map(\.name))
            existing.faces = Self.sortedFaces(existing.faces + family.faces.filter { !names.contains($0.name) })
            merged[family.name] = existing
        }
        let others = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        families = Self.systemDesigns.map { FontFamily(name: $0, faces: Self.systemWeights) } + others
        var positions: [String: Int] = [:]
        for (index, family) in families.enumerated() {
            positions[family.name] = index
        }
        self.positions = positions
    }

    public static func isSystemDesign(_ name: String) -> Bool {
        systemDesigns.contains(name)
    }

    public func family(named name: String) -> FontFamily? {
        positions[name].map { families[$0] }
    }

    /// The face of a family font; nil when the catalogue has no such family or weight.
    public func face(family: String, weight: String) -> FontFace? {
        self.family(named: family)?.faces.first { $0.name == weight }
    }

    /// Whether the font is in the catalogue: a text style, or a family and one of its weights.
    public func contains(_ font: FontNotation) -> Bool {
        switch font {
        case .textStyle: return true
        case .family(let family, let weight, _): return face(family: family, weight: weight) != nil
        }
    }

    // MARK: Search (docs/chats.md › Font search)

    /// A row of the search results.
    public enum SearchResult: Sendable, Hashable {
        case family(String)
        case textStyle(FontTextStyle)
    }

    /// The families whose name contains every word of the query, then the text styles whose
    /// notation contains them, compared in lowercase; every family and text style for an empty
    /// query. The text styles that are suggestions are left out.
    public func search(_ query: String, excludingSuggestions suggestions: [String] = []) -> [SearchResult] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func matches(_ name: String) -> Bool {
            let lowercased = name.lowercased()
            return words.allSatisfy { lowercased.contains($0) }
        }
        let suggested = Set(suggestions)
        let families = families.filter { matches($0.name) }.map { SearchResult.family($0.name) }
        let styles = FontTextStyle.allCases.filter { !suggested.contains($0.notation) && matches($0.notation) }
            .map { SearchResult.textStyle($0) }
        return families + styles
    }

    // MARK: Weights (docs/chats.md › Nearest weight)

    /// The weight the `Weight` menu takes when `family` is selected in the search results: the
    /// face named `name`, else the face whose value is nearest `value`, an upright face before an
    /// italic one on a tie, then the first in the family's order.
    public static func nearestFace(name: String, value: Double, in family: FontFamily) -> FontFace? {
        if let same = family.faces.first(where: { $0.name == name }) { return same }
        var best: FontFace?
        for face in family.faces {
            guard let current = best else {
                best = face
                continue
            }
            let distance = abs(face.weight - value), bestDistance = abs(current.weight - value)
            if distance < bestDistance - 1e-9 || (abs(distance - bestDistance) <= 1e-9 && current.italic && !face.italic) {
                best = face
            }
        }
        return best
    }

    /// The face that draws a family's name in the search results: its `Regular` face, else the
    /// face whose value is nearest 0.
    public static func nameFace(of family: FontFamily) -> FontFace? {
        nearestFace(name: "Regular", value: 0, in: family)
    }

    /// A family's faces by value, upright faces before italic ones, then by name.
    public static func sortedFaces(_ faces: [FontFace]) -> [FontFace] {
        faces.sorted { a, b in
            if a.weight != b.weight { return a.weight < b.weight }
            if a.italic != b.italic { return !a.italic }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Reading

    /// Every family CoreText lists on this Mac, with the faces of each.
    public static func readInstalledFamilies() -> [FontFamily] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        var families: [FontFamily] = []
        for name in names where !name.hasPrefix(".") {
            let request = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
            let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
            let descriptors = CTFontDescriptorCreateMatchingFontDescriptors(request, mandatory) as? [CTFontDescriptor] ?? []
            var faces: [FontFace] = []
            for descriptor in descriptors {
                guard let face = face(of: descriptor, path: nil), !faces.contains(where: { $0.name == face.face.name })
                else { continue }
                faces.append(face.face)
            }
            if !faces.isEmpty {
                families.append(FontFamily(name: name, faces: sortedFaces(faces)))
            }
        }
        return families
    }

    /// The families of a project's font files, read in the order given: a face whose family and
    /// style name an earlier file gave is left out, a family named like a system design too, and a
    /// file that cannot be read is skipped (docs/engine-api.md › files.fonts).
    public static func projectFamilies(files: [(path: String, url: URL)]) -> [FontFamily] {
        var faces: [String: [FontFace]] = [:]
        for file in files {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file.url as CFURL) as? [CTFontDescriptor] else {
                continue
            }
            for descriptor in descriptors {
                guard let found = face(of: descriptor, path: file.path), !isSystemDesign(found.family),
                      !(faces[found.family] ?? []).contains(where: { $0.name == found.face.name })
                else { continue }
                faces[found.family, default: []].append(found.face)
            }
        }
        return faces.map { FontFamily(name: $0.key, faces: sortedFaces($0.value)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The family name and the face of a font descriptor; nil when it has no family, style or
    /// PostScript name.
    public static func face(of descriptor: CTFontDescriptor, path: String?) -> (family: String, face: FontFace)? {
        guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String, !family.isEmpty,
              let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String, !style.isEmpty,
              let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        else { return nil }
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any] ?? [:]
        let weight = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
        let symbolic = (traits[kCTFontSymbolicTrait as String] as? NSNumber)?.uint32Value ?? 0
        let italic = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
        return (family, FontFace(name: style, weight: (weight * 100).rounded() / 100, italic: italic,
                                 postScriptName: postScriptName, path: path))
    }
}

/// One OpenType font rebuilt from the tables of a CoreText font, so that a face of a collection
/// can be loaded on its own (docs/chats.md › Links, images and files, `FontSchemeHandler`).
public enum FontFileWriter {
    /// The font data, `isCFF` true when it has CFF outlines; nil when CoreText gives no table.
    public static func data(of font: CTFont) -> (data: Data, isCFF: Bool)? {
        guard let array = CTFontCopyAvailableTables(font, []) else { return nil }
        var tables: [UInt32: Data] = [:]
        for index in 0..<CFArrayGetCount(array) {
            let tag = UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(array, index)))
            if let table = CTFontCopyTable(font, CTFontTableTag(tag), []) as Data? {
                tables[tag] = table
            }
        }
        guard !tables.isEmpty else { return nil }
        let isCFF = tables[tag("CFF ")] != nil || tables[tag("CFF2")] != nil
        return (data(tables: tables, isCFF: isCFF), isCFF)
    }

    /// An sfnt file of the tables: the offset table, the table records sorted by tag, then each
    /// table padded to 4 bytes, with the checksums of the OpenType specification.
    public static func data(tables: [UInt32: Data], isCFF: Bool) -> Data {
        let tags = tables.keys.sorted()
        var output = Data()
        func append32(_ value: UInt32) { output.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        func append16(_ value: UInt16) { output.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
        let count = UInt16(tags.count)
        var power: UInt16 = 1, selector: UInt16 = 0
        while power * 2 <= count {
            power *= 2
            selector += 1
        }
        append32(isCFF ? tag("OTTO") : 0x0001_0000)
        append16(count)
        append16(power * 16)
        append16(selector)
        append16(count * 16 - power * 16)
        var offset = UInt32(12 + 16 * tags.count)
        var body = Data()
        var headOffset: Int?
        for tagValue in tags {
            var table = tables[tagValue] ?? Data()
            if tagValue == tag("head"), table.count >= 12 {
                // The checksum adjustment is computed over the whole file below.
                table.replaceSubrange(8..<12, with: [0, 0, 0, 0])
                headOffset = Int(offset) + 8
            }
            append32(tagValue)
            append32(checksum(table))
            append32(offset)
            append32(UInt32(table.count))
            body.append(table)
            while body.count % 4 != 0 { body.append(0) }
            offset = UInt32(12 + 16 * tags.count + body.count)
        }
        output.append(body)
        if let headOffset {
            let adjustment = 0xB1B0_AFBA &- checksum(output)
            output.replaceSubrange(headOffset..<headOffset + 4,
                                   with: [UInt8(adjustment >> 24), UInt8(adjustment >> 16 & 0xFF), UInt8(adjustment >> 8 & 0xFF),
                                          UInt8(adjustment & 0xFF)])
        }
        return output
    }

    /// The tag of four ASCII characters, such as `head`.
    public static func tag(_ name: String) -> UInt32 {
        name.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The sum of the table's big-endian 32-bit words, the last one padded with zeros.
    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        var word: UInt32 = 0
        for (index, byte) in data.enumerated() {
            word = word << 8 | UInt32(byte)
            if index % 4 == 3 {
                sum = sum &+ word
                word = 0
            }
        }
        let remainder = data.count % 4
        if remainder != 0 {
            sum = sum &+ (word << UInt32(8 * (4 - remainder)))
        }
        return sum
    }
}
