import Foundation

/// The kinds of highlighted text (docs/code-editor.md › Token kinds and colors).
public enum TokenKind: String, Sendable, Codable, CaseIterable {
    case keyword, type, builtin, function, property, variable
    case string, escape, interpolation, number
    case comment, docComment, attribute, directive
    case heading, emphasis, strong, link, code
}

/// The colors and font of a token kind in the light and dark appearances.
public struct TokenStyle: Sendable, Equatable {
    public enum Weight: String, Sendable { case regular, semibold, bold }

    /// `#RRGGBB`
    public var light: String
    /// `#RRGGBB`
    public var dark: String
    public var weight: Weight
    public var italic: Bool

    public init(light: String, dark: String, weight: Weight, italic: Bool) {
        self.light = light
        self.dark = dark
        self.weight = weight
        self.italic = italic
    }
}

extension TokenKind {
    /// The table of docs/code-editor.md › Token kinds and colors.
    public var style: TokenStyle {
        switch self {
        case .keyword: return TokenStyle(light: "#9B2393", dark: "#FF7AB2", weight: .semibold, italic: false)
        case .type: return TokenStyle(light: "#3900A0", dark: "#DABAFF", weight: .regular, italic: false)
        case .builtin: return TokenStyle(light: "#6C36A9", dark: "#B281EB", weight: .regular, italic: false)
        case .function: return TokenStyle(light: "#326D74", dark: "#67B7A4", weight: .regular, italic: false)
        case .property: return TokenStyle(light: "#0B4F79", dark: "#6BDFFF", weight: .regular, italic: false)
        case .variable: return TokenStyle(light: "#0F68A0", dark: "#4EB0CC", weight: .regular, italic: false)
        case .string: return TokenStyle(light: "#C41A16", dark: "#FF8170", weight: .regular, italic: false)
        case .escape: return TokenStyle(light: "#A3410B", dark: "#FFB38A", weight: .regular, italic: false)
        case .interpolation: return TokenStyle(light: "#9B2393", dark: "#FF7AB2", weight: .regular, italic: false)
        case .number: return TokenStyle(light: "#1C00CF", dark: "#D9C97C", weight: .regular, italic: false)
        case .comment: return TokenStyle(light: "#5D6C79", dark: "#7F8C98", weight: .regular, italic: false)
        case .docComment: return TokenStyle(light: "#5D6C79", dark: "#7F8C98", weight: .regular, italic: true)
        case .attribute: return TokenStyle(light: "#815F03", dark: "#CC9768", weight: .regular, italic: false)
        case .directive: return TokenStyle(light: "#643820", dark: "#FFA14F", weight: .regular, italic: false)
        case .heading: return TokenStyle(light: "#0B4F79", dark: "#6BDFFF", weight: .bold, italic: false)
        case .emphasis: return TokenStyle(light: "#1F1F24", dark: "#DFDFE0", weight: .regular, italic: true)
        case .strong: return TokenStyle(light: "#1F1F24", dark: "#DFDFE0", weight: .bold, italic: false)
        case .link: return TokenStyle(light: "#0E0EFF", dark: "#5482FF", weight: .regular, italic: false)
        case .code: return TokenStyle(light: "#1C00CF", dark: "#D9C97C", weight: .regular, italic: false)
        }
    }

    /// `"tok-"` + the kind in kebab case, for example `tok-doc-comment`.
    public var cssClass: String {
        var kebab = ""
        for character in rawValue {
            if character.isUppercase {
                kebab += "-" + character.lowercased()
            } else {
                kebab.append(character)
            }
        }
        return "tok-" + kebab
    }
}
