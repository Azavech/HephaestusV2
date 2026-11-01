import Foundation

// SHIM(core-domain): delete at integration
// The cross-key contracts core-files calls, until core-domain's implementations arrive. The
// domain queries read the projects from disk on every call: the registry's top-level projects,
// each followed by its sub projects, depth first, skipping invalid files and identifiers
// already used, as docs/data-model.md › Loading does.
extension DomainState {
    private func shimProjects() -> [(id: ProjectID, root: URL, project: Project)] {
        var result: [(id: ProjectID, root: URL, project: Project)] = []
        var used: Set<ProjectID> = []
        func load(_ root: URL) {
            let folder = ProjectFolder(root: root)
            guard let project = try? ProjectFileStore.readProject(folder), !used.contains(project.id) else { return }
            used.insert(project.id)
            result.append((project.id, folder.root, project))
            for entry in project.subprojects where ModelRules.isRelativePath(entry) {
                load(folder.root.appendingPathComponent(entry, isDirectory: true))
            }
        }
        for entry in registry.loadableEntries {
            load(URL(fileURLWithPath: entry, isDirectory: true))
        }
        return result
    }

    func project(_ id: ProjectID) -> Project? {
        shimProjects().first { $0.id == id }?.project
    }

    func projectRoot(_ id: ProjectID) -> URL? {
        shimProjects().first { $0.id == id }?.root
    }

    func loadedProjectIDs() -> [ProjectID] {
        shimProjects().map(\.id)
    }
}

// SHIM(core-domain): delete at integration
extension Engine {
    func projectDataFilesChanged(projectID: ProjectID, paths: [String]) async {}
}
