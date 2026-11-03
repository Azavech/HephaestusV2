import Foundation

/// Options of the Markdown renderers (docs/documentation-viewer.md › Renderer).
public struct MarkdownRenderOptions: Sendable {
    /// Project path of the folder the text belongs to; "" for the project root.
    public var baseDirectory: String
    /// Absolute path of the project root on the main device; recognizes absolute paths and file URLs.
    public var projectRootPath: String?
    /// Removes a leading YAML front matter block before parsing.
    public var stripFrontMatter: Bool
    /// Draws the SF Symbol markers whose name it accepts; nil leaves `sf:` images refused
    /// (docs/documentation-viewer.md › SF Symbol markers).
    public var isSymbolAvailable: (@Sendable (String) -> Bool)?
    /// Draws the color markers whose color it gives a swatch for; nil leaves `color:` images
    /// refused (docs/documentation-viewer.md › Color markers).
    public var colorSwatch: (@Sendable (String) -> MarkdownColorSwatch?)?
    /// Identifiers of the projects of the device; their ticket and bundle ids become links
    /// (docs/documentation-viewer.md › Ticket and bundle ids).
    public var projectIdentifiers: Set<String>

    public init(baseDirectory: String = "", projectRootPath: String? = nil, stripFrontMatter: Bool = false,
                isSymbolAvailable: (@Sendable (String) -> Bool)? = nil,
                colorSwatch: (@Sendable (String) -> MarkdownColorSwatch?)? = nil, projectIdentifiers: Set<String> = []) {
        self.baseDirectory = baseDirectory
        self.projectRootPath = projectRootPath
        self.stripFrontMatter = stripFrontMatter
        self.isSymbolAvailable = isSymbolAvailable
        self.colorSwatch = colorSwatch
        self.projectIdentifiers = projectIdentifiers
    }
}

/// The light and dark values of a color marker's swatch (docs/documentation-viewer.md › Color
/// markers): CSS hex colors, `#RRGGBB` or `#RRGGBBAA`.
public struct MarkdownColorSwatch: Sendable, Equatable, Hashable {
    public var light: String
    public var dark: String

    public init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }

    /// Both values are `#` followed by 6 or 8 hex digits, so they can be written in attributes.
    public var isValid: Bool {
        Self.isCSSHex(light) && Self.isCSSHex(dark)
    }

    static func isCSSHex(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 7 || scalars.count == 9, scalars[0] == "#" else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            switch scalar {
            case "0"..."9", "a"..."f", "A"..."F": return true
            default: return false
            }
        }
    }
}

enum FrontMatter {
    /// When the first line is exactly `---` and a later line is exactly `---` or `...`, every
    /// line up to and including that closing line is removed (docs/documentation-viewer.md ›
    /// Front matter). Without a closing line nothing is removed.
    static func strip(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first == "---" || first == "---\r" else { return markdown }
        for index in lines.indices.dropFirst() {
            let line = lines[index].hasSuffix("\r") ? lines[index].dropLast() : lines[index]
            if line == "---" || line == "..." {
                return lines[(index + 1)...].joined(separator: "\n")
            }
        }
        return markdown
    }
}
