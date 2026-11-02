import Foundation

/// The SF Symbols of a Mac, read from the catalogue of its macOS, and their search
/// (docs/chats.md › Symbol catalogue, › Symbol search). The engine checks the suggestions of
/// `chats.postSymbol` with it; the pinned symbol card searches it.
public struct SFSymbolCatalog: Sendable {
    /// The folder of the running macOS's catalogue files.
    public static let systemFolder = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// The catalogue of this Mac, read the first time it is used and kept until the app quits.
    public static let system = SFSymbolCatalog(folder: systemFolder, macOSVersion: ProcessInfo.processInfo.operatingSystemVersion)

    /// The last dot-separated components of the localized variants.
    public static let localizationSuffixes: Set<String> = [
        "ar", "bn", "el", "gu", "he", "hi", "ja", "km", "kn", "ko", "ml", "mni", "mr", "my", "or", "pa", "rtl", "ru", "sat",
        "si", "ta", "te", "th", "zh",
    ]

    /// One searchable symbol: its name and keywords, lowercased.
    private struct Entry: Sendable {
        var name: String
        var lowercasedName: String
        var keywords: [String]
    }

    /// Every name of the catalogue, localized variants included.
    public let names: Set<String>
    /// The names the search lists, in alphabetical order: no localized variant.
    private let entries: [Entry]
    /// What could not be read, for `engine.log`; empty when both files were read.
    public let problems: [String]

    /// The catalogue of `names` with their search keywords.
    public init(names: Set<String>, keywords: [String: [String]], problems: [String] = []) {
        self.names = names
        self.problems = problems
        entries = names.filter { !Self.isLocalizedVariant($0) }.sorted().map { name in
            Entry(name: name, lowercasedName: name.lowercased(), keywords: (keywords[name] ?? []).map { $0.lowercased() })
        }
    }

    /// Reads `name_availability.plist` and `symbol_search.plist` of `folder`: a name belongs to
    /// the catalogue when the `macOS` version of its release is at most `macOSVersion`, or when
    /// its release gives none. A file that cannot be read leaves the catalogue empty, or the names
    /// without keywords.
    public init(folder: URL, macOSVersion: OperatingSystemVersion) {
        var problems: [String] = []
        var names: Set<String> = []
        do {
            let plist = try Self.dictionary(folder.appendingPathComponent("name_availability.plist"))
            guard let symbols = plist["symbols"] as? [String: String] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            let releases = plist["year_to_release"] as? [String: [String: String]] ?? [:]
            for (name, release) in symbols {
                if let version = releases[release]?["macOS"], !Self.isAvailable(version, on: macOSVersion) { continue }
                names.insert(name)
            }
        } catch {
            problems.append("name_availability.plist cannot be read: \(error.localizedDescription)")
        }
        var keywords: [String: [String]] = [:]
        do {
            let plist = try Self.dictionary(folder.appendingPathComponent("symbol_search.plist"))
            for (name, value) in plist {
                keywords[name] = value as? [String] ?? []
            }
        } catch {
            problems.append("symbol_search.plist cannot be read: \(error.localizedDescription)")
        }
        self.init(names: names, keywords: keywords, problems: problems)
    }

    /// Whether the name is a symbol of the catalogue, localized variants included.
    public func contains(_ name: String) -> Bool {
        names.contains(name)
    }

    /// A name whose last dot-separated component is one of `localizationSuffixes`.
    public static func isLocalizedVariant(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return localizationSuffixes.contains(String(name[name.index(after: dot)...]))
    }

    /// The search of docs/chats.md › Symbol search: the name matches, then the keyword matches,
    /// each in alphabetical order, without localized variants and without `excluded`; nothing for
    /// an empty query.
    public func search(_ query: String, excluding excluded: Set<String> = []) -> [String] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        var byName: [String] = []
        var byKeyword: [String] = []
        for entry in entries where !excluded.contains(entry.name) {
            if words.allSatisfy({ entry.lowercasedName.contains($0) }) {
                byName.append(entry.name)
            } else if words.allSatisfy({ word in entry.lowercasedName.contains(word) || entry.keywords.contains { $0.contains(word) } }) {
                byKeyword.append(entry.name)
            }
        }
        return byName + byKeyword
    }

    private static func dictionary(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dictionary
    }

    /// Whether a release's `macOS` version, such as `27.2`, is at most the running version.
    private static func isAvailable(_ version: String, on running: OperatingSystemVersion) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let release = [parts.first ?? 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0]
        let current = [running.majorVersion, running.minorVersion, running.patchVersion]
        return release == current || release.lexicographicallyPrecedes(current)
    }
}
