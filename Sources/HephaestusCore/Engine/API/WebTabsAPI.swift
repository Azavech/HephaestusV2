import Foundation

// docs/engine-api.md › Web tabs.

/// `webTabs.list`: the project's tabs in tab order. Actors: user, claude.
public enum WebTabsList: EngineMethod {
    public static let name = "webTabs.list"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [WebTab]
}

/// `webTabs.open`. Actors: user, claude.
public enum WebTabsOpen: EngineMethod {
    public static let name = "webTabs.open"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// Absolute `http` or `https` URL.
        public var url: String
        /// Default: the URL's host.
        public var title: String?
        /// Default false.
        public var locked: Bool?
        /// Position of the new tab, clamped to 0 through the number of tabs; absent appends.
        public var index: Int?

        public init(projectID: ProjectID, url: String, title: String? = nil, locked: Bool? = nil, index: Int? = nil) {
            self.projectID = projectID
            self.url = url
            self.title = title
            self.locked = locked
            self.index = index
        }
    }
    public typealias Result = WebTab
}

/// `webTabs.update`. Actors: user, claude.
public enum WebTabsUpdate: EngineMethod {
    public static let name = "webTabs.update"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var tabID: UUID
        public var url: String?
        public var title: String?
        /// Lock or unlock the tab; claude may not unlock.
        public var locked: Bool?

        public init(projectID: ProjectID, tabID: UUID, url: String? = nil, title: String? = nil, locked: Bool? = nil) {
            self.projectID = projectID
            self.tabID = tabID
            self.url = url
            self.title = title
            self.locked = locked
        }
    }
    public typealias Result = WebTab
}

/// `webTabs.close`. Actors: user, claude.
public enum WebTabsClose: EngineMethod {
    public static let name = "webTabs.close"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var tabID: UUID

        public init(projectID: ProjectID, tabID: UUID) {
            self.projectID = projectID
            self.tabID = tabID
        }
    }
    public typealias Result = Empty
}

/// `webTabs.move`: the result is every tab in the new order. Actors: user, claude.
public enum WebTabsMove: EngineMethod {
    public static let name = "webTabs.move"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var tabID: UUID
        /// Final position, clamped to 0 through the number of tabs minus 1.
        public var toIndex: Int

        public init(projectID: ProjectID, tabID: UUID, toIndex: Int) {
            self.projectID = projectID
            self.tabID = tabID
            self.toIndex = toIndex
        }
    }
    public typealias Result = [WebTab]
}
