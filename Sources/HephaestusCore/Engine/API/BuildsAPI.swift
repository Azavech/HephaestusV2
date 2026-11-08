import Foundation

// docs/engine-api.md › Builds.

/// `builds.listRuns`: the newest 50 workflow runs of the project's repository, newest first,
/// without jobs. Actors: user.
public enum BuildsListRuns: EngineMethod {
    public static let name = "builds.listRuns"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [WorkflowRun]
}

/// `builds.getRun`: one run with its jobs and their steps. Actors: user.
public enum BuildsGetRun: EngineMethod {
    public static let name = "builds.getRun"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// Id of the run (`WorkflowRun.id`).
        public var runID: Int

        public init(projectID: ProjectID, runID: Int) {
            self.projectID = projectID
            self.runID = runID
        }
    }
    public typealias Result = WorkflowRun
}

/// `builds.rerunRun`: runs every job of a completed run again, or only its failed jobs and the
/// jobs that depend on them. Actors: user.
public enum BuildsRerunRun: EngineMethod {
    public static let name = "builds.rerunRun"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var runID: Int
        /// true: only the failed jobs and the jobs that depend on them (`--failed`).
        public var failedOnly: Bool?

        public init(projectID: ProjectID, runID: Int, failedOnly: Bool? = nil) {
            self.projectID = projectID
            self.runID = runID
            self.failedOnly = failedOnly
        }
    }
    public typealias Result = Empty
}

/// `builds.cancelRun`: cancels a queued or running run. Actors: user.
public enum BuildsCancelRun: EngineMethod {
    public static let name = "builds.cancelRun"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var runID: Int

        public init(projectID: ProjectID, runID: Int) {
            self.projectID = projectID
            self.runID = runID
        }
    }
    public typealias Result = Empty
}

/// `builds.listReleases`: the newest 50 published releases of the project's repository, newest
/// first. Actors: user.
public enum BuildsListReleases: EngineMethod {
    public static let name = "builds.listReleases"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [GitHubRelease]
}

/// `builds.getRelease`: one release with its notes and its assets. Actors: user.
public enum BuildsGetRelease: EngineMethod {
    public static let name = "builds.getRelease"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// Tag of the release.
        public var tag: String

        public init(projectID: ProjectID, tag: String) {
            self.projectID = projectID
            self.tag = tag
        }
    }
    public typealias Result = ReleaseDetail
}

/// `builds.downloadAsset`: saves an asset of a release in the Downloads folder of the main device.
/// Actors: user.
public enum BuildsDownloadAsset: EngineMethod {
    public static let name = "builds.downloadAsset"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// Tag of the release.
        public var tag: String
        /// Name of the asset (`ReleaseAsset.name`).
        public var asset: String

        public init(projectID: ProjectID, tag: String, asset: String) {
            self.projectID = projectID
            self.tag = tag
            self.asset = asset
        }
    }
    public typealias Result = DownloadedAsset
}
