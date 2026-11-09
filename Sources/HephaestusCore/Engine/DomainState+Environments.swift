import Foundation

/// The environments of a project as they apply (docs/projects.md › Inherited environments).
struct ResolvedEnvironments: Equatable, Sendable {
    /// The inherited environments with the project's changes, then its own environments whose
    /// names they do not have.
    var environments: [ProjectEnvironment] = []
    /// The environments the project inherits, as its parent resolves them, without its changes.
    var inherited: [ProjectEnvironment] = []

    /// A project's environments from the ones it inherits: each inherited environment with the
    /// change of `overrides` for its name, then the environments of `own` whose names no inherited
    /// environment has, each list in its order. A change for a name no inherited environment has
    /// is ignored.
    init(own: [ProjectEnvironment], overrides: [String: EnvironmentOverride], inherited: [ProjectEnvironment]) {
        let inheritedNames = Set(inherited.map(\.name))
        environments = inherited.map { environment in overrides[environment.name]?.applied(to: environment) ?? environment }
            + own.filter { !inheritedNames.contains($0.name) }
        self.inherited = inherited
    }

    init() {}
}

/// What a loaded project takes from its parent while it uses its parent's settings
/// (docs/projects.md › Sub projects), with the current working environment that follows its
/// environments: taken for every project before a change, so that the projects whose GitHub page,
/// environments or current working environment the change alters get `project.updated`.
struct InheritedSettings: Equatable, Sendable {
    var githubPage: String?
    var graphEnabled: Bool
    var environments: ResolvedEnvironments
    var currentEnvironment: String?
}

extension Engine {
    /// The environments of a loaded project as they apply (docs/projects.md › Inherited
    /// environments): none for a project whose type is not `goService`; for a sub project that
    /// uses its parent's settings, its parent's environments as the parent resolves them, with its
    /// changes, then its own; otherwise its own. `project` stands for the loaded project's file,
    /// for example a change `projects.update` checks before it writes it.
    func resolvedEnvironments(of id: ProjectID, project: Project? = nil) -> ResolvedEnvironments {
        var visited: Set<ProjectID> = []
        return resolvedEnvironments(of: id, project: project, visited: &visited)
    }

    private func resolvedEnvironments(of id: ProjectID, project: Project?, visited: inout Set<ProjectID>) -> ResolvedEnvironments {
        guard let loaded = domain.projects[id], visited.insert(id).inserted else { return ResolvedEnvironments() }
        let project = project ?? loaded.project
        guard project.type == .goService else { return ResolvedEnvironments() }
        var inherited: [ProjectEnvironment] = []
        if project.useParentSettings, let parentID = loaded.parentID, domain.isLoaded(parentID) {
            inherited = resolvedEnvironments(of: parentID, project: nil, visited: &visited).environments
        }
        return ResolvedEnvironments(own: project.environments, overrides: project.environmentOverrides, inherited: inherited)
    }

    /// Whether a loaded project's Graph is enabled (docs/graph.md › Enabling): never for a project
    /// whose type is not `goService`; for a sub project that uses its parent's settings, as its
    /// parent resolves it; otherwise its own `graphEnabled`.
    func graphEnabled(of id: ProjectID) -> Bool {
        var current = id
        var visited: Set<ProjectID> = []
        while let loaded = domain.projects[current], visited.insert(current).inserted {
            guard loaded.project.type == .goService else { return false }
            guard loaded.project.useParentSettings, let parentID = loaded.parentID, domain.isLoaded(parentID) else {
                return loaded.project.graphEnabled
            }
            current = parentID
        }
        return false
    }

    /// The GitHub page and the environments of every loaded project: taken before a change, so that
    /// `emitInheritedSettingsChanges(since:except:origin:)` finds the projects whose settings it
    /// changed.
    func inheritedSettings() -> [ProjectID: InheritedSettings] {
        Dictionary(domain.loadedProjectIDs().map { id in (id, inheritedSettings(of: id)) }, uniquingKeysWith: { first, _ in first })
    }

    private func inheritedSettings(of id: ProjectID) -> InheritedSettings {
        let environments = resolvedEnvironments(of: id)
        return InheritedSettings(githubPage: githubPage(of: id), graphEnabled: graphEnabled(of: id), environments: environments,
                                 currentEnvironment: currentEnvironment(of: id, in: environments.environments))
    }

    /// Emits `project.updated` for every project loaded before a change whose GitHub page or
    /// environments now differ from those of `before`, except the projects of `except`, which the
    /// change announces itself (docs/projects.md › GitHub page, › Inherited environments).
    func emitInheritedSettingsChanges(since before: [ProjectID: InheritedSettings], except: Set<ProjectID> = [], origin: Actor) {
        for id in domain.loadedProjectIDs() where !except.contains(id) {
            guard let old = before[id], inheritedSettings(of: id) != old else { continue }
            emitProjectUpdated(id, origin: origin)
        }
    }

    // MARK: Current working environment (docs/projects.md › Current working environment)

    /// The name of a loaded project's current working environment among its environments as they
    /// apply: the one chosen for it, else the first; nil without environments.
    func currentEnvironment(of id: ProjectID, in environments: [ProjectEnvironment]) -> String? {
        if let name = currentEnvironments.projects[id], environments.contains(where: { $0.name == name }) {
            return name
        }
        return environments.first?.name
    }

    /// The environments a change of `environments` renames, old name to new name: those whose name
    /// changed at the same position of the list, the list keeping its length.
    static func renamedEnvironments(from old: [ProjectEnvironment], to new: [ProjectEnvironment]) -> [String: String] {
        guard old.count == new.count else { return [:] }
        var renamed: [String: String] = [:]
        for (before, after) in zip(old, new) where before.name != after.name {
            renamed[before.name] = after.name
        }
        return renamed
    }

    /// After a change, for every project whose environments it changed since `before`: a chosen
    /// environment that `renamed` renamed and the project now has under its new name stays chosen
    /// under that name; one the project no longer has is forgotten, so that the first environment
    /// is current. A failed write is logged and the choices stay in memory.
    func keepCurrentEnvironments(since before: [ProjectID: InheritedSettings], renamed: [String: String] = [:]) {
        var kept = currentEnvironments
        for (id, name) in currentEnvironments.projects {
            guard let old = before[id], domain.isLoaded(id) else { continue }
            let environments = resolvedEnvironments(of: id)
            guard environments != old.environments else { continue }
            let names = Set(environments.environments.map(\.name))
            if let newName = renamed[name], names.contains(newName) {
                kept.projects[id] = newName
            } else if !names.contains(name) {
                kept.projects[id] = nil
            }
        }
        storeCurrentEnvironments(kept)
    }

    /// Forgets the choices of the projects that `projects.remove` unregistered.
    func forgetCurrentEnvironments(of ids: [ProjectID]) {
        var kept = currentEnvironments
        for id in ids where domain.projects[id] == nil {
            kept.projects[id] = nil
        }
        storeCurrentEnvironments(kept)
    }

    /// Keeps the choices in memory and writes them when they changed; a failed write is logged.
    private func storeCurrentEnvironments(_ kept: CurrentEnvironments) {
        guard kept != currentEnvironments else { return }
        currentEnvironments = kept
        // `saveCurrentEnvironments` logs a failed write.
        try? saveCurrentEnvironments(kept)
    }
}
