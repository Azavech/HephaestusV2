import Foundation

// docs/engine-api.md › Search.

/// `search.query`: results in rank order. Actors: user, claude.
public enum SearchQuery: EngineMethod {
    public static let name = "search.query"
    public struct Params: Codable, Sendable, Hashable {
        /// Whitespace-separated terms; every term must match.
        public var query: String
        /// Kinds to search; absent or empty means every kind.
        public var scopes: [SearchScope]?
        /// Searches only this project; absent searches every project.
        public var projectID: ProjectID?
        /// 1–1,000, default 200.
        public var limit: Int?

        public init(query: String, scopes: [SearchScope]? = nil, projectID: ProjectID? = nil, limit: Int? = nil) {
            self.query = query
            self.scopes = scopes
            self.projectID = projectID
            self.limit = limit
        }
    }
    public typealias Result = [SearchResult]
}
