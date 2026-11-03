import CoreText
import Foundation
@testable import HephaestusCore

/// Font files with a family name of their own, built from the tables of a font installed on every
/// Mac with a new `name` table, so that tests read project fonts that no Mac has installed.
enum FontTestFiles {
    /// One font: the tables of `base` with the family, style and PostScript names given.
    static func font(family: String, style: String, postScriptName: String, base: String = "Helvetica") -> Data {
        let font = CTFontCreateWithName(base as CFString, 12, nil)
        var tables: [UInt32: Data] = [:]
        let array = CTFontCopyAvailableTables(font, [])!
        for index in 0..<CFArrayGetCount(array) {
            let tag = UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(array, index)))
            if let table = CTFontCopyTable(font, CTFontTableTag(tag), []) as Data? {
                tables[tag] = table
            }
        }
        tables[FontFileWriter.tag("name")] = nameTable([1: family, 2: style, 4: "\(family) \(style)", 6: postScriptName])
        let isCFF = tables[FontFileWriter.tag("CFF ")] != nil
        return FontFileWriter.data(tables: tables, isCFF: isCFF)
    }

    /// A `name` table of format 0 with Windows Unicode records in US English, strings in UTF-16BE.
    static func nameTable(_ names: [UInt16: String]) -> Data {
        let ids = names.keys.sorted()
        var strings = Data()
        var records = Data()
        func append16(_ data: inout Data, _ value: UInt16) { data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
        for id in ids {
            let bytes = Array(names[id]!.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            for value in [UInt16(3), 1, 0x0409, id, UInt16(bytes.count), UInt16(strings.count)] {
                append16(&records, value)
            }
            strings.append(contentsOf: bytes)
        }
        var table = Data()
        append16(&table, 0)
        append16(&table, UInt16(ids.count))
        append16(&table, UInt16(6 + 12 * ids.count))
        table.append(records)
        table.append(strings)
        return table
    }
}
