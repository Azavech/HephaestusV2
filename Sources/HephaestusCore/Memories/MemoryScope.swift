import Foundation

/// The folder a `memories.*` call or a memories view works on: the memory folder of a project, or
/// the device's global memories folder, which a call names by giving no `projectID`
/// (docs/memories.md › Global memories, docs/engine-api.md › Memories).
public enum MemoryScope: Hashable, Sendable {
    case project(ProjectID)
    case global

    /// The scope of a call's `projectID`: the global memories folder without one.
    public init(projectID: ProjectID?) {
        self = projectID.map { .project($0) } ?? .global
    }

    /// The `projectID` of the calls and of the `memories.changed` data: nil for the global memories
    /// folder.
    public var projectID: ProjectID? {
        if case .project(let projectID) = self { return projectID }
        return nil
    }
}
