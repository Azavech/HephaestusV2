import Foundation

// docs/engine-api.md › Docs.

/// `docs.list`: the Markdown files under the project's `docsPath`. Actors: user, claude.
public enum DocsList: EngineMethod {
    public static let name = "docs.list"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [DocEntry]
}
