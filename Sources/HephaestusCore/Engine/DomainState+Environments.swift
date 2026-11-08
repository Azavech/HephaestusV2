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
/// (docs/projects.md › Sub projects): taken for every project before a change, so that the
/// projects whose GitHub page or environments the change alters get `project.updated`.
struct InheritedSettings: Equatable, Sendable {
    var githubPage: String?
    var environments: ResolvedEnvironments
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

    /// The GitHub page and the environments of every loaded project: taken before a change, so that
    /// `emitInheritedSettingsChanges(since:except:origin:)` finds the projects whose settings it
    /// changed.
    func inheritedSettings() -> [ProjectID: InheritedSettings] {
        Dictionary(domain.loadedProjectIDs().map { id in
            (id, InheritedSettings(githubPage: githubPage(of: id), environments: resolvedEnvironments(of: id)))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Emits `project.updated` for every project loaded before a change whose GitHub page or
    /// environments now differ from those of `before`, except the projects of `except`, which the
    /// change announces itself (docs/projects.md › GitHub page, › Inherited environments).
    func emitInheritedSettingsChanges(since before: [ProjectID: InheritedSettings], except: Set<ProjectID> = [], origin: Actor) {
        for id in domain.loadedProjectIDs() where !except.contains(id) {
            guard let old = before[id],
                  InheritedSettings(githubPage: githubPage(of: id), environments: resolvedEnvironments(of: id)) != old else { continue }
            emitProjectUpdated(id, origin: origin)
        }
    }
}
