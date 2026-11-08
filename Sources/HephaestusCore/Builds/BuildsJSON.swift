import Foundation

/// Reads the `--json` output of the gh commands of docs/builds.md › gh calls into the API types.
/// A date that gh writes as `0001-01-01T00:00:00Z`, for a time GitHub has not set, and an empty
/// conclusion are absent.
enum BuildsJSON {
    /// The fields of `gh run list`.
    static let runListFields = "conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,startedAt,status,updatedAt,workflowName"
    /// The fields of `gh run view`: those of `gh run list` and the jobs.
    static let runViewFields = "conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,jobs,startedAt,status,updatedAt,workflowName"
    /// The fields of `gh release list`.
    static let releaseListFields = "createdAt,isLatest,isPrerelease,name,publishedAt,tagName"
    /// The fields of `gh release view`.
    static let releaseViewFields = "assets,body,createdAt,isPrerelease,name,publishedAt,tagName"

    /// The output of `gh run list`.
    static func runs(from data: Data) throws -> [WorkflowRun] {
        try EngineJSON.decode([GHRun].self, from: data).map(\.run)
    }

    /// The output of `gh run view`, with its jobs.
    static func run(from data: Data) throws -> WorkflowRun {
        let run = try EngineJSON.decode(GHRun.self, from: data)
        var result = run.run
        result.jobs = (run.jobs ?? []).map(\.job)
        return result
    }

    /// The output of `gh release list`.
    static func releases(from data: Data) throws -> [GitHubRelease] {
        try EngineJSON.decode([GHRelease].self, from: data).map(\.release)
    }

    /// The output of `gh release view`.
    static func releaseDetail(from data: Data) throws -> ReleaseDetail {
        try EngineJSON.decode(GHReleaseDetail.self, from: data).detail
    }

    /// nil for a date before 1970, which gh writes for a time GitHub has not set.
    static func setDate(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    /// nil for an empty conclusion, which gh writes before an item is completed.
    static func setText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - gh output

private struct GHRun: Decodable {
    var conclusion: String?
    var createdAt: Date
    var databaseId: Int
    var displayTitle: String
    var event: String
    var headBranch: String
    var headSha: String
    var startedAt: Date?
    var status: String
    var updatedAt: Date
    var workflowName: String?
    var jobs: [GHJob]?

    var run: WorkflowRun {
        WorkflowRun(id: databaseId, workflowName: workflowName ?? "", title: displayTitle, branch: headBranch,
                    commit: headSha, event: event, status: status, conclusion: BuildsJSON.setText(conclusion),
                    createdAt: createdAt, startedAt: BuildsJSON.setDate(startedAt), updatedAt: updatedAt)
    }
}

private struct GHJob: Decodable {
    var completedAt: Date?
    var conclusion: String?
    var databaseId: Int
    var name: String
    var startedAt: Date?
    var status: String
    var steps: [GHStep]?

    var job: WorkflowJob {
        WorkflowJob(id: databaseId, name: name, status: status, conclusion: BuildsJSON.setText(conclusion),
                    startedAt: BuildsJSON.setDate(startedAt), completedAt: BuildsJSON.setDate(completedAt),
                    steps: (steps ?? []).map(\.step).sorted { $0.number < $1.number })
    }
}

private struct GHStep: Decodable {
    var completedAt: Date?
    var conclusion: String?
    var name: String
    var number: Int
    var startedAt: Date?
    var status: String

    var step: WorkflowStep {
        WorkflowStep(number: number, name: name, status: status, conclusion: BuildsJSON.setText(conclusion),
                     startedAt: BuildsJSON.setDate(startedAt), completedAt: BuildsJSON.setDate(completedAt))
    }
}

private struct GHRelease: Decodable {
    var createdAt: Date
    var isLatest: Bool
    var isPrerelease: Bool
    var name: String?
    var publishedAt: Date?
    var tagName: String

    var release: GitHubRelease {
        GitHubRelease(tag: tagName, name: name ?? "", createdAt: createdAt, publishedAt: BuildsJSON.setDate(publishedAt),
                      isLatest: isLatest, isPrerelease: isPrerelease)
    }
}

private struct GHReleaseDetail: Decodable {
    var assets: [GHAsset]?
    var body: String?
    var createdAt: Date
    var isPrerelease: Bool
    var name: String?
    var publishedAt: Date?
    var tagName: String

    var detail: ReleaseDetail {
        ReleaseDetail(tag: tagName, name: name ?? "", createdAt: createdAt, publishedAt: BuildsJSON.setDate(publishedAt),
                      isPrerelease: isPrerelease, notes: body ?? "", assets: (assets ?? []).map(\.asset))
    }
}

private struct GHAsset: Decodable {
    var name: String
    var size: Int

    var asset: ReleaseAsset {
        ReleaseAsset(name: name, size: size)
    }
}
