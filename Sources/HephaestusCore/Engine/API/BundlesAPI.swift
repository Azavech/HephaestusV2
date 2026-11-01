import Foundation

// docs/engine-api.md › Bundles.

/// `bundles.list`: the project's bundles sorted by number. Actors: user, claude.
public enum BundlesList: EngineMethod {
    public static let name = "bundles.list"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [TicketBundle]
}

/// `bundles.get`. Actors: user, claude.
public enum BundlesGet: EngineMethod {
    public static let name = "bundles.get"
    public struct Params: Codable, Sendable, Hashable {
        public var bundleID: BundleID

        public init(bundleID: BundleID) {
            self.bundleID = bundleID
        }
    }
    public typealias Result = TicketBundle
}

/// `bundles.create`. Actors: user, claude.
public enum BundlesCreate: EngineMethod {
    public static let name = "bundles.create"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// When absent or empty after trimming, Haiku names the bundle from its ticket titles.
        public var title: String?
        /// At least one ticket of this project, each listed once, in implementation order.
        public var ticketIDs: [TicketID]

        public init(projectID: ProjectID, title: String? = nil, ticketIDs: [TicketID]) {
            self.projectID = projectID
            self.title = title
            self.ticketIDs = ticketIDs
        }
    }
    public typealias Result = TicketBundle
}

/// `bundles.update`. Actors: user, claude.
public enum BundlesUpdate: EngineMethod {
    public static let name = "bundles.update"
    public struct Params: Codable, Sendable, Hashable {
        public var bundleID: BundleID
        public var title: String?
        /// Replaces the list; may be empty.
        public var ticketIDs: [TicketID]?

        public init(bundleID: BundleID, title: String? = nil, ticketIDs: [TicketID]? = nil) {
            self.bundleID = bundleID
            self.title = title
            self.ticketIDs = ticketIDs
        }
    }
    public typealias Result = TicketBundle
}

/// `bundles.setStatus`. Actors: user, claude.
public enum BundlesSetStatus: EngineMethod {
    public static let name = "bundles.setStatus"
    public struct Params: Codable, Sendable, Hashable {
        public var bundleID: BundleID
        /// `todo`, `in_progress` or `done`, decoded as a string and checked by the handler.
        public var status: String

        public init(bundleID: BundleID, status: String) {
            self.bundleID = bundleID
            self.status = status
        }
    }
    public typealias Result = TicketBundle
}

/// `bundles.delete`. Actors: user, claude.
public enum BundlesDelete: EngineMethod {
    public static let name = "bundles.delete"
    public struct Params: Codable, Sendable, Hashable {
        public var bundleID: BundleID

        public init(bundleID: BundleID) {
            self.bundleID = bundleID
        }
    }
    public typealias Result = Empty
}
