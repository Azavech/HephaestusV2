import Foundation

/// The YAML frontmatter of `<skills library>/<name>/SKILL.md`
/// (docs/data-model.md › Skill file). It has no `schema` key.
public struct SkillFrontmatter: Codable, Sendable, Hashable {
    /// Skill name; equals the folder name.
    public var name: String
    /// Tells Claude when to use the skill.
    public var description: String
    /// Every other frontmatter key, preserved as read.
    public var extraFrontmatter: [String: JSONValue]

    public init(name: String, description: String = "", extraFrontmatter: [String: JSONValue] = [:]) {
        self.name = name
        self.description = description
        self.extraFrontmatter = extraFrontmatter
    }

    static let knownKeys: Set<String> = ["name", "description"]

    /// Decodes a frontmatter mapping. When `ModelCoding.skillFolderNameKey` is set in
    /// `userInfo`, the folder name replaces a `name` that is missing or differs from it;
    /// otherwise a missing `name` reads as "".
    // DOC-GAP: docs/data-model.md › Skill file gives `name` the default "folder name", which a
    // decoder only knows when the caller passes it; without it a missing name decodes as "".
    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        let folderName = c.userInfo[ModelCoding.skillFolderNameKey] as? String
        let written: String? = try c.optional("name")
        name = folderName ?? written ?? ""
        description = try c.value("description", default: "")
        extraFrontmatter = try c.unknownKeys(known: Self.knownKeys)
    }

    /// Writes `name`, `description`, then the extra keys sorted by key.
    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(name, "name")
        try c.encode(description, "description")
        try c.encodeUnknownKeys(extraFrontmatter, known: Self.knownKeys)
    }

    /// The write rules of the field table.
    public func validate() throws {
        _ = try ModelRules.skillName(name)
        _ = try ModelRules.skillDescription(description)
    }
}
