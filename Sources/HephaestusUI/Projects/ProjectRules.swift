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

    /// docs/projects.md › Identifier rules: empty, not 2 to 8 letters, reserved for the
    /// HephaestusV2 project, or used by a loaded project of the window's device.
    static func identifierMessage(_ typed: String, projects: [ProjectSummary]) -> String? {
        guard !typed.isEmpty else { return "Enter an identifier." }
        guard typed.range(of: "^[A-Za-z]{2,8}$", options: .regularExpression) != nil else {
            return "Use 2 to 8 letters (A–Z)."
        }
        let identifier = typed.uppercased()
        if identifier == HephaestusRepository.identifier {
            return "\(identifier) is reserved for HephaestusV2."
        }
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

    /// The innermost loaded project whose root strictly contains `path`; without `strictly`, whose
    /// root is `path` or contains it.
    static func innermostProject(containing path: String, in projects: [ProjectSummary], strictly: Bool = true) -> ProjectSummary? {
        projects.filter { isInside(path, root: $0.rootPath, strictly: strictly) }.max { $0.rootPath.count < $1.rootPath.count }
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

    // MARK: Parent project

    /// The New Project sheet's `Parent project` pop-up: `None` (tag `""`), a separator, then
    /// every project in `projects.list` order, indented by depth (docs/projects.md › Creating a
    /// project).
    static func parentItems(projects: [ProjectSummary]) -> [IndentedPopUpButton.Item] {
        let parents = Dictionary(projects.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        func depth(of project: ProjectSummary) -> Int {
            var depth = 0
            var parentID = project.parentID
            while let current = parentID, depth < projects.count {
                depth += 1
                parentID = parents[current] ?? nil
            }
            return depth
        }
        return [IndentedPopUpButton.Item(tag: "", title: "None"), .separator()]
            + projects.map { IndentedPopUpButton.Item(tag: $0.id, title: $0.name, indentation: depth(of: $0)) }
    }

    /// `Choose a folder inside “<parent name>”.` while the folder breaks the sub project
    /// constraint: in New Folder mode the parent folder is the parent's root or inside it; in
    /// Existing Folder mode the folder is strictly inside the parent's root (docs/projects.md ›
    /// Sub projects). An empty folder field gives no message.
    static func parentFolderMessage(parent: ProjectSummary, newFolder: Bool, parentFolder: String, chosenFolder: String) -> String? {
        if newFolder {
            guard !parentFolder.isEmpty, !isInside(parentFolder, root: parent.rootPath, strictly: false) else { return nil }
        } else {
            guard !chosenFolder.isEmpty, !isInside(chosenFolder, root: parent.rootPath, strictly: true) else { return nil }
        }
        return "Choose a folder inside “\(parent.name)”."
    }

    /// The parent that follows the project folder until the user picks one: the innermost loaded
    /// project whose root strictly contains the project folder. In New Folder mode that folder is
    /// parent folder + folder name, so the project whose root is the parent folder or contains it;
    /// in Existing Folder mode, the chosen folder. nil for `None` (docs/projects.md › Creating a
    /// project).
    static func folderParent(newFolder: Bool, parentFolder: String, chosenFolder: String, projects: [ProjectSummary]) -> ProjectSummary? {
        if newFolder {
            guard !parentFolder.isEmpty else { return nil }
            return innermostProject(containing: parentFolder, in: projects, strictly: false)
        }
        guard !chosenFolder.isEmpty else { return nil }
        return innermostProject(containing: chosenFolder, in: projects)
    }

    /// The note of a project folder inside a loaded project, shown while no parent is selected
    /// (docs/projects.md › Creating a project).
    static func insideNote(projectFolder: String, projects: [ProjectSummary]) -> String? {
        guard !projectFolder.isEmpty, let owner = innermostProject(containing: projectFolder, in: projects) else { return nil }
        return "This folder is inside “\(owner.name)”: the new project becomes its sub project."
    }

    private static func standardized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    // MARK: Project settings

    /// A relative path with `/` separators, no leading or trailing `/`, no empty, `.` or `..`
    /// component, not inside `.hephaestus`; an empty field is not a relative path
    /// (docs/projects.md › Project settings).
    static func docsPathMessage(_ docsPath: String) -> String? {
        let valid = ModelRules.isRelativePath(docsPath) && docsPath.split(separator: "/").first != ".hephaestus"
        return valid ? nil : "Enter a folder path inside the project, for example docs."
    }

    /// The breadcrumb's icon, drawn for a project without an icon (docs/ui.md › Breadcrumb
    /// selector).
    static let defaultIcon = "folder"

    /// The symbol drawn for a project's icon: the icon, or `defaultIcon` when the project has none
    /// or the Mac that shows the window has no symbol for its name (docs/projects.md › Project
    /// settings).
    static func iconSymbol(_ icon: String?, isAvailable: (String) -> Bool = SFSymbols.isAvailable) -> String {
        guard let icon, isAvailable(icon) else { return defaultIcon }
        return icon
    }

    // MARK: HephaestusV2 project

    /// True for the HephaestusV2 project, the device's project `HEPH`, and for its ancestors:
    /// Project ▸ Remove Project… is not shown for them (docs/projects.md › Removing a project).
    static func isHephaestusOrAncestor(_ projectID: String, projects: [ProjectSummary]) -> Bool {
        var current: String? = HephaestusRepository.identifier
        var visited: Set<String> = []
        while let id = current, visited.insert(id).inserted, let project = projects.first(where: { $0.id == id }) {
            if id == projectID {
                return true
            }
            current = project.parentID
        }
        return false
    }

}

/// The Project type of the New Project and New Sub Project sheets: it follows the project folder
/// until the user picks a type in the menu (docs/projects.md › Creating a project).
struct ProjectTypeChoice: Equatable {
    private(set) var type = ProjectType.none
    /// True once the user has picked a type in the menu.
    private(set) var picked = false

    /// A type picked in the menu: the type no longer follows the folder.
    mutating func pick(_ type: ProjectType) {
        self.type = type
        picked = true
    }

    /// The project folder was checked: `Go service` when it has `go.mod`, `None` otherwise.
    mutating func follow(folderHasGoMod: Bool) {
        guard !picked else { return }
        type = folderHasGoMod ? .goService : .none
    }
}

/// The Parent project of the New Project sheet: it follows the project folder until the user picks
/// a value in the pop-up, `None` included. The parent preselected by New Sub Project… never follows
/// the folder (docs/projects.md › Creating a project, › Sub projects).
struct ParentProjectChoice: Equatable {
    /// The value picked in the pop-up, nil for `None`.
    private(set) var pickedID: String?
    /// True once the user has picked a value, or for a preselected parent.
    private(set) var picked: Bool

    init(preselected parentID: String? = nil) {
        pickedID = parentID
        picked = parentID != nil
    }

    /// A value picked in the pop-up, nil for `None`: the parent no longer follows the folder.
    mutating func pick(_ parentID: String?) {
        pickedID = parentID
        picked = true
    }

    /// The selected parent: the picked value, or until one is picked, the project that contains
    /// the project folder (`ProjectRules.folderParent`).
    func parentID(following folderParent: ProjectSummary?) -> String? {
        picked ? pickedID : folderParent?.id
    }
}
