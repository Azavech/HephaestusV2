import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/projects.md › Project settings, › GitHub page: the message and the applied value of the
/// GitHub page field.
@Suite("Project Settings GitHub page")
struct ProjectSettingsGitHubPageTests {
    static let message = "Enter a GitHub page, for example https://github.com/owner/name."

    @Test func anEmptyFieldOrAPageHasNoMessage() {
        for text in ["", "  ", "https://github.com/owner/name", "https://github.com/owner/name/", " https://github.com/owner/name "] {
            #expect(ProjectRules.githubPageMessage(text) == nil, "\(text)")
        }
    }

    @Test func anythingElseShowsTheMessage() {
        for text in ["github.com/x", "https://github.com/owner", "http://github.com/owner/name", "https://gitlab.com/owner/name",
                     "https://github.com/owner/name/more"] {
            #expect(ProjectRules.githubPageMessage(text) == Self.message, "\(text)")
        }
    }

    @Test func thePageAppliesTrimmedWithoutItsTrailingSlash() {
        #expect(ProjectRules.normalizedGithubPage(" https://github.com/owner/name/ ") == "https://github.com/owner/name")
        #expect(ProjectRules.normalizedGithubPage("https://github.com/owner/name") == "https://github.com/owner/name")
        #expect(ProjectRules.normalizedGithubPage("  ") == "")
    }
}
