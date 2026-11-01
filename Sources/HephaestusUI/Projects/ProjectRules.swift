// OWNER: ui-shell — the field rules and messages of the project sheets (docs/projects.md ›
// Identifier rules, › Creating a project, › Sub projects, › Project settings).
import Foundation
import HephaestusCore

/// The checks the New Project, New Sub Project and Project Settings sheets run while the user
/// types, with their messages.
enum ProjectRules {
    // MARK: Name

    /// Single line, 1 to 100 characters after trimming.
    static func nameMessage(_ name: String) -> String? {
        (try? ModelRules.projectName(name)) == nil ? "Enter a name of 1 to 100 characters." : nil
    }

    // MARK: Identifier

    /// docs/projects.md › Identifier rules: empty, not 2 to 8 letters, or used by a loaded project
    /// of the window's device.
    static func identifierMessage(_ typed: String, projects: [ProjectSummary]) -> String? {
        guard !typed.isEmpty else { return "Enter an identifier." }
        guard typed.range(of: "^[A-Za-z]{2,8}$", options: .regularExpression) != nil else {
            return "Use 2 to 8 letters (A–Z)."
        }
        let identifier = typed.uppercased()
        if let owner = projects.first(where: { $0.id == identifier }) {
            return "\(identifier) is already used by “\(owner.name)”."
        }
        return nil
    }

    /// The suggestion from the name: its letters without diacritics, uppercased, keeping only `A`
    /// to `Z`, the first four of them; empty with fewer than 2.
    static func identifierSuggestion(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
        let letters = folded.unicodeScalars.filter { ("A"..."Z").contains($0) }.prefix(4)
        guard letters.count >= 2 else { return "" }
        return String(String.UnicodeScalarView(letters))
    }

    // MARK: Folders

    /// The folder name that follows the name: `/` and `:` replaced by `-`, trimmed, without
    /// leading `.`.
    static func folderNameSuggestion(from name: String) -> String {
        var result = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// 1 to 255 UTF-8 bytes, no `/`, not starting with `.`.
    static func folderNameMessage(_ folderName: String) -> String? {
        let valid = (1...255).contains(folderName.utf8.count) && !folderName.contains("/") && !folderName.hasPrefix(".")
        return valid ? nil : "Enter a folder name without “/” that does not start with “.”."
    }

    /// `parent` + `/` + `name`.
    static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// True when `path` is `root` or inside it; with `strictly`, only inside it.
    static func isInside(_ path: String, root: String, strictly: Bool) -> Bool {
        let path = standardized(path)
        let root = standardized(root)
        if path == root { return !strictly }
        return path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// The innermost loaded project whose root strictly contains `path`.
    static func innermostProject(containing path: String, in projects: [ProjectSummary]) -> ProjectSummary? {
        projects.filter { isInside(path, root: $0.rootPath, strictly: true) }.max { $0.rootPath.count < $1.rootPath.count }
    }

    /// The path of `path` relative to `root`, for a path inside it.
    static func relativePath(_ path: String, to root: String) -> String {
        let path = standardized(path)
        let root = standardized(root)
        guard path.hasPrefix(root == "/" ? "/" : root + "/") else { return path }
        return String(path.dropFirst(root == "/" ? 1 : root.count + 1))
    }

    /// The folder that contains `path`.
    static func parentFolder(of path: String) -> String {
        (standardized(path) as NSString).deletingLastPathComponent
    }

    /// The last component of a path.
    static func lastComponent(of path: String) -> String {
        (standardized(path) as NSString).lastPathComponent
    }

    private static func standardized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    // MARK: Project settings

    /// A relative path with `/` separators, no leading or trailing `/`, no empty, `.` or `..`
    /// component, not inside `.hephaestus`.
    // DOC-GAP: docs/projects.md › Project settings gives the docs folder the placeholder `docs` but
    // no meaning for an empty field; an empty field is not a relative path and shows the message.
    static func docsPathMessage(_ docsPath: String) -> String? {
        let valid = ModelRules.isRelativePath(docsPath) && docsPath.split(separator: "/").first != ".hephaestus"
        return valid ? nil : "Enter a folder path inside the project, for example docs."
    }
}
