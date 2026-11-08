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

    // MARK: Environments (docs/projects.md › Environments)

    /// The Name field of the Environments section: 1 to 100 characters after trimming, on one
    /// line, and no other environment with the trimmed name, letter case included.
    static func environmentNameMessage(_ name: String, otherNames: [String]) -> String? {
        guard let trimmed = try? ModelRules.environmentName(name) else { return "Enter a name of 1 to 100 characters." }
        return otherNames.contains(trimmed) ? ProjectEnvironment.duplicateMessage(trimmed) : nil
    }

    /// The URL field of API Access: empty, which removes the URL or, for an inherited environment,
    /// uses the parent's, or an absolute `http` or `https` URL with a host, after trimming.
    static func environmentURLMessage(_ url: String) -> String? {
        guard let trimmed = ModelRules.trimmedOrNil(url) else { return nil }
        return (try? ModelRules.environmentURL(trimmed)) == nil ? "Enter an http or https URL." : nil
    }

    /// The Port field: empty, or a whole number from 1 to 65535 after trimming.
    static func environmentPortMessage(_ port: String) -> String? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || environmentPort(trimmed) != nil ? nil : "Enter a port from 1 to 65535."
    }

    /// The port typed in the Port field: nil for an empty field or one that is not a port.
    static func environmentPort(_ port: String) -> Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(trimmed),
              (1...65535).contains(value) else { return nil }
        return value
    }

    /// The Port field as it applies: the port's number, so `08080` is `8080`, or the trimmed text.
    static func normalizedEnvironmentPort(_ port: String) -> String {
        environmentPort(port).map(String.init) ?? port.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Kubeconfig file field: empty, or an absolute path or a path starting with `~/` on one
    /// line after trimming.
    static func environmentKubeconfigMessage(_ kubeconfig: String) -> String? {
        guard let trimmed = ModelRules.trimmedOrNil(kubeconfig) else { return nil }
        let valid = !ModelRules.containsLineBreak(trimmed) && ModelRules.isAbsoluteOrHomePath(trimmed)
        return valid ? nil : "Enter an absolute path or a path starting with ~/."
    }

    /// The names the Name field must not take: those of the project's own environments, the edited
    /// environment's own name excluded, and those of the environments it inherits
    /// (docs/projects.md › Inherited environments).
    static func otherEnvironmentNames(_ environments: [ProjectEnvironment], inherited: [ProjectEnvironment] = [],
                                      editing original: ProjectEnvironment?) -> [String] {
        environments.map(\.name).filter { $0 != original?.name } + inherited.map(\.name)
    }

    /// The name `+` gives: `New Environment`, else `New Environment 2`, `New Environment 3` and so
    /// on, the first that none of `taken`, the names of the project's own and inherited
    /// environments, has.
    static func newEnvironmentName(taken: [String]) -> String {
        let names = Set(taken)
        let base = "New Environment"
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") {
            number += 1
        }
        return "\(base) \(number)"
    }

    /// The list `+` applies: the environments, then a new one named `name` with every other field
    /// empty.
    static func environments(_ environments: [ProjectEnvironment], adding name: String) -> [ProjectEnvironment] {
        environments + [ProjectEnvironment(name: name)]
    }

    /// The list a field of an environment of the project's own applies: the environments with
    /// `change` made to the first one named `name`, which keeps its other keys, its Argo CD
    /// application and unknown keys included; nil when none has that name.
    static func environments(_ environments: [ProjectEnvironment], changing name: String,
                             _ change: (inout ProjectEnvironment) -> Void) -> [ProjectEnvironment]? {
        guard let index = environments.firstIndex(where: { $0.name == name }) else { return nil }
        var list = environments
        change(&list[index])
        return list
    }

    /// The list `−` applies: the environments without the first one named `name`; nil when none
    /// has that name.
    static func environments(_ environments: [ProjectEnvironment], removing name: String) -> [ProjectEnvironment]? {
        guard let index = environments.firstIndex(where: { $0.name == name }) else { return nil }
        var list = environments
        list.remove(at: index)
        return list
    }

    // MARK: Inherited environments (docs/projects.md › Inherited environments)

    /// The changes a field of an inherited environment applies: the stored changes, with `change`
    /// made to the change of the environment `name`, which keeps its other values, its Argo CD
    /// application and unknown keys included; a change that no longer sets any value is removed.
    static func environmentOverrides(_ overrides: [String: EnvironmentOverride], changing name: String,
                                     _ change: (inout EnvironmentOverride) -> Void) -> [String: EnvironmentOverride] {
        var value = overrides[name] ?? EnvironmentOverride()
        change(&value)
        var result = overrides
        result[name] = value.isEmpty ? nil : value
        return result
    }

    /// An empty field, which removes the page, or `https://github.com/<owner>/<name>`, a trailing
    /// `/` removed (docs/projects.md › Project settings, › GitHub page).
    static func githubPageMessage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || GitHubPage.normalized(trimmed) != nil
            ? nil : "Enter a GitHub page, for example https://github.com/owner/name."
    }

    /// The page as it applies: trimmed and without one trailing `/`; empty for an empty field.
    static func normalizedGithubPage(_ text: String) -> String {
        GitHubPage.normalized(text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
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
