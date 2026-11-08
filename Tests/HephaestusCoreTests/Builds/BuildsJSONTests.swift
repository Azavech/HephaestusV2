import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › WorkflowRun, › GitHubRelease, › ReleaseDetail: the gh captures of
/// `Fixtures/gh/` read into the API types (docs/development.md › gh captures).
@Suite("Builds JSON")
struct BuildsJSONTests {
    private func date(_ text: String) -> Date {
        ISODate.date(from: text)!
    }

    @Test("gh run list gives the runs in its order, without jobs")
    func runList() throws {
        let runs = try BuildsJSON.runs(from: ghFixture("run-list"))
        #expect(runs.count == 3)
        let first = try #require(runs.first)
        #expect(first.id == 42415910670)
        #expect(first.workflowName == "Release")
        #expect(first.title == "feat: always load the HephaestusV2 project for feedback (HEPH-85)")
        #expect(first.branch == "main")
        #expect(first.commit == "ec49a8f2897f0d17737ccc2137d7506cb82d0d93")
        #expect(first.event == "push")
        #expect(first.status == "completed")
        #expect(first.conclusion == "success")
        #expect(first.createdAt == date("2026-11-07T21:27:02Z"))
        #expect(first.startedAt == date("2026-11-07T21:27:02Z"))
        #expect(first.updatedAt == date("2026-11-07T21:41:19Z"))
        #expect(first.jobs == nil)
        #expect(runs.map(\.id) == [42415910670, 42408559069, 42396389751])
    }

    @Test("gh run view of a completed run gives its jobs and their steps in step order")
    func completedRun() throws {
        let run = try BuildsJSON.run(from: ghFixture("run-view"))
        #expect(run.id == 42415910670)
        let jobs = try #require(run.jobs)
        #expect(jobs.count == 1)
        let job = jobs[0]
        #expect(job.id == 128533835918)
        #expect(job.name == "release")
        #expect(job.status == "completed")
        #expect(job.conclusion == "success")
        #expect(job.startedAt == date("2026-11-07T21:27:06Z"))
        #expect(job.completedAt == date("2026-11-07T21:41:19Z"))
        #expect(job.steps.count == 16)
        #expect(job.steps.map(\.number) == Array(1...14) + [28, 29])
        #expect(job.steps[0] == WorkflowStep(number: 1, name: "Set up job", status: "completed", conclusion: "success",
                                             startedAt: date("2026-11-07T21:27:06Z"), completedAt: date("2026-11-07T21:27:07Z")))
    }

    @Test("gh run view of a run not completed: an empty conclusion and the date 0001-01-01 are absent")
    func runningRun() throws {
        let run = try BuildsJSON.run(from: ghFixture("run-view-running"))
        #expect(run.status == "queued")
        #expect(run.conclusion == nil)
        let jobs = try #require(run.jobs)
        #expect(jobs.map(\.name) == ["activation", "agent"])
        let running = jobs[1]
        #expect(running.status == "in_progress")
        #expect(running.conclusion == nil)
        #expect(running.startedAt == date("2026-11-08T02:26:39Z"))
        #expect(running.completedAt == nil)
        #expect(running.steps.isEmpty)
        #expect(jobs[0].steps.map(\.number) == [1, 2, 45])
    }

    @Test("A step not started yet has no dates")
    func stepWithoutDates() throws {
        let json = """
        {"conclusion": "", "createdAt": "2026-11-08T02:20:21Z", "databaseId": 7, "displayTitle": "CI", "event": "push",
         "headBranch": "main", "headSha": "abc", "startedAt": "0001-01-01T00:00:00Z", "status": "queued",
         "updatedAt": "2026-11-08T02:20:21Z", "workflowName": "",
         "jobs": [{"completedAt": "0001-01-01T00:00:00Z", "conclusion": "", "databaseId": 8, "name": "build",
                   "startedAt": "0001-01-01T00:00:00Z", "status": "queued",
                   "steps": [{"completedAt": "0001-01-01T00:00:00Z", "conclusion": "", "name": "Build", "number": 2,
                              "startedAt": "0001-01-01T00:00:00Z", "status": "pending"},
                             {"completedAt": "0001-01-01T00:00:00Z", "conclusion": "", "name": "Set up", "number": 1,
                              "startedAt": "2026-11-08T02:20:22.5Z", "status": "in_progress"}]}]}
        """
        let run = try BuildsJSON.run(from: Data(json.utf8))
        #expect(run.startedAt == nil)
        #expect(run.workflowName == "")
        let job = try #require(run.jobs?.first)
        #expect(job.startedAt == nil && job.completedAt == nil && job.conclusion == nil)
        #expect(job.steps.map(\.name) == ["Set up", "Build"])
        #expect(job.steps[0].startedAt == Date(timeIntervalSince1970: date("2026-11-08T02:20:22Z").timeIntervalSince1970 + 0.5))
        #expect(job.steps[1].startedAt == nil)
    }

    @Test("gh release list gives the releases with their badges")
    func releaseList() throws {
        let releases = try BuildsJSON.releases(from: ghFixture("release-list"))
        #expect(releases.map(\.tag) == ["v0.41.0", "v0.40.0", "v0.39.0"])
        #expect(releases[0] == GitHubRelease(tag: "v0.41.0", name: "v0.41.0(302)", createdAt: date("2026-11-07T21:26:58Z"),
                                             publishedAt: date("2026-11-07T21:41:14Z"), isLatest: true, isPrerelease: false))
        #expect(releases.dropFirst().allSatisfy { !$0.isLatest })
    }

    @Test("gh release view gives the notes and the assets with their sizes")
    func releaseView() throws {
        let release = try BuildsJSON.releaseDetail(from: ghFixture("release-view"))
        #expect(release.tag == "v0.41.0")
        #expect(release.name == "v0.41.0(302)")
        #expect(release.isPrerelease == false)
        #expect(release.notes == "- feat: always load the HephaestusV2 project for feedback (HEPH-85)\n")
        #expect(release.assets == [ReleaseAsset(name: "HephaestusV2.zip", size: 19039339), ReleaseAsset(name: "release.json", size: 299)])
        #expect(release.publishedAt == date("2026-11-07T21:41:14Z"))
    }

    @Test("A release without name, notes or assets reads as empty")
    func emptyRelease() throws {
        let json = #"{"assets": [], "body": "", "createdAt": "2026-11-07T21:26:58Z", "isPrerelease": true, "name": "", "publishedAt": "2026-11-07T21:41:14Z", "tagName": "v1.0.0-beta"}"#
        let release = try BuildsJSON.releaseDetail(from: Data(json.utf8))
        #expect(release == ReleaseDetail(tag: "v1.0.0-beta", name: "", createdAt: date("2026-11-07T21:26:58Z"),
                                         publishedAt: date("2026-11-07T21:41:14Z"), isPrerelease: true, notes: "", assets: []))
    }

    @Test("The owner and the name of a GitHub page")
    func repositoryOfPage() {
        #expect(GitHubPage.ownerAndName(of: "https://github.com/example/name")! == ("example", "name"))
        #expect(GitHubPage.ownerAndName(of: "https://github.com/owner/name.git/")! == ("owner", "name.git"))
        #expect(GitHubPage.ownerAndName(of: "https://gitlab.com/owner/name") == nil)
    }

    @Test("The pattern of an asset matches its name only")
    func assetPattern() {
        #expect(ReleaseDownloads.pattern(forAsset: "HephaestusV2.zip") == "HephaestusV2.zip")
        #expect(ReleaseDownloads.pattern(forAsset: #"a*b?c[d]\e.zip"#) == #"a\*b\?c\[d]\\e.zip"#)
    }

    @Test("The URLs of the quarantine attributes are percent-encoded")
    func releaseURLs() {
        #expect(ReleaseDownloads.releaseURL(owner: "example", name: "name", components: ["download", "v1.0", "My App.zip"])?.absoluteString
                == "https://github.com/example/name/releases/download/v1.0/My%20App.zip")
        #expect(ReleaseDownloads.releaseURL(owner: "example", name: "name", components: ["tag", "release/1"])?.absoluteString
                == "https://github.com/example/name/releases/tag/release%2F1")
    }
}
