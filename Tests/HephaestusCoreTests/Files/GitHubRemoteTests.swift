import Foundation
import Testing
@testable import HephaestusCore

/// The page rule, the remote forms and the `ssh -G` output of docs/projects.md › GitHub page.
@Suite("GitHub page rules")
struct GitHubRemoteTests {
    /// Written in two parts, so that no line of this file holds an address.
    static let at = "@"

    @Test("A typed page is trimmed and loses one trailing /; anything else than https://github.com/<owner>/<name> is refused")
    func pageRule() {
        let valid: [(String, String)] = [
            ("https://github.com/owner/name", "https://github.com/owner/name"),
            ("https://github.com/owner/name/", "https://github.com/owner/name"),
            ("  https://github.com/Owner-1/my_repo.swift \n", "https://github.com/Owner-1/my_repo.swift"),
            ("https://github.com/owner/name.git", "https://github.com/owner/name.git"),
            ("https://github.com/mona-cat_octo/notes", "https://github.com/mona-cat_octo/notes"),
        ]
        for (text, page) in valid {
            #expect(GitHubPage.normalized(text) == page)
            #expect((try? GitHubPage.validated(text)) == page)
        }
        let invalid = ["", "github.com/x", "http://github.com/owner/name", "https://www.github.com/owner/name",
                       "https://GitHub.com/owner/name", "https://github.com/owner", "https://github.com/owner/",
                       "https://github.com/owner/name/more", "https://github.com/owner/name//", "https://github.com//name",
                       "https://github.com/own.er/name", "https://github.com/owner/na me", "https://github.com/owner/..",
                       "https://github.com/ownér/name", "https://github.com/owner/nâme",
                       "https://github.com/owner/.", "https://github.com/owner/name?tab=readme"]
        for text in invalid {
            #expect(GitHubPage.normalized(text) == nil, "\(text)")
        }
        #expect(throws: ValidationError.invalid("githubPage", "use a page of the form https://github.com/<owner>/<name>")) {
            try GitHubPage.validated("github.com/x")
        }
        #expect(GitHubPage.page(owner: "owner", name: "name") == "https://github.com/owner/name")
        #expect(GitHubPage.page(owner: "a/b", name: "name") == nil)
    }

    @Test("The three remote forms give the host, owner and name, with or without .git, a user or a port")
    func remoteForms() throws {
        let at = Self.at
        let forms: [(String, String, String, String, Bool)] = [
            ("git\(at)github.com:owner/name.git", "github.com", "owner", "name", true),
            ("git\(at)github.com:owner/name", "github.com", "owner", "name", true),
            ("github-work:owner/name.git", "github-work", "owner", "name", true),
            ("deploy\(at)github-work:owner/name.git", "github-work", "owner", "name", true),
            ("ssh://git\(at)github.com/owner/name.git", "github.com", "owner", "name", true),
            ("ssh://git\(at)github-work:22/owner/name", "github-work", "owner", "name", true),
            ("ssh://github-work/owner/name.git", "github-work", "owner", "name", true),
            ("https://github.com/owner/name.git", "github.com", "owner", "name", false),
            ("https://github.com/owner/name", "github.com", "owner", "name", false),
            ("https://token\(at)GitHub.com:443/owner/name.git", "GitHub.com", "owner", "name", false),
            ("https://example.com/owner/name.git", "example.com", "owner", "name", false),
        ]
        for (url, host, owner, name, isSSH) in forms {
            let remote = try #require(GitHubRemote(remoteURL: url), "\(url)")
            #expect(remote == GitHubRemote(host: host, owner: owner, name: name, isSSH: isSSH), "\(url)")
        }
        #expect(GitHubRemote(remoteURL: "https://GitHub.com/owner/name")?.isGitHubHost == true)
        #expect(GitHubRemote(remoteURL: "https://example.com/owner/name")?.isGitHubHost == false)
        let others = ["http://github.com/owner/name.git", "git://github.com/owner/name.git", "https://github.com/owner/name/",
                      "https://github.com/owner", "https://github.com/group/owner/name", "git\(at)github.com:/owner/name.git",
                      "git\(at)github.com:owner/name/", "/Users/example/repo", "../repo", "file:///Users/example/repo",
                      "https://github.com/owner/name?x=1", "", "github.com"]
        for url in others {
            #expect(GitHubRemote(remoteURL: url) == nil, "\(url)")
        }
    }

    @Test("The hostname line of ssh -G is read")
    func sshHostName() {
        #expect(FileTools.hostName(inSSHConfiguration: "user git\nhostname github.com\nport 22\n") == "github.com")
        #expect(FileTools.hostName(inSSHConfiguration: "hostname   ssh.example.com  \n") == "ssh.example.com")
        #expect(FileTools.hostName(inSSHConfiguration: "user git\nport 22\n") == nil)
        #expect(FileTools.hostName(inSSHConfiguration: "hostnamefoo bar\n") == nil)
    }

    @Test("ssh -G runs with the alias in the given folder; an alias that starts with - and a missing ssh give none")
    func sshRun() async throws {
        try await withTemporaryDirectory { folder in
            let ssh = try writeScript(folder.appendingPathComponent("bin/ssh"), """
                [ "$1" = -G ] || exit 2
                echo "$2" >> "\(folder.path)/calls"
                if [ "$2" = github-work ]; then echo "user git"; echo "hostname github.com"; else echo "hostname $2"; fi
                """)
            let tools = FileTools(environment: ["PATH": "/usr/bin:/bin"], ssh: ssh)
            #expect(await tools.sshHostName(alias: "github-work", in: folder.path) == "github.com")
            #expect(await tools.sshHostName(alias: "gitlab-work", in: folder.path) == "gitlab-work")
            #expect(await tools.sshHostName(alias: "-oProxyCommand=x", in: folder.path) == nil)
            #expect(try readFile(folder.appendingPathComponent("calls")) == "github-work\ngitlab-work\n")
            #expect(await FileTools(environment: [:]).sshHostName(alias: "github-work", in: folder.path) == nil)
            let failing = try writeScript(folder.appendingPathComponent("bin/failing-ssh"), "echo 'hostname github.com'; exit 255")
            #expect(await FileTools(environment: [:], ssh: failing).sshHostName(alias: "github-work", in: folder.path) == nil)
        }
    }

    @Test("ssh is looked up in PATH")
    func sshLookUp() async throws {
        try await withTemporaryDirectory { folder in
            let ssh = try writeScript(folder.appendingPathComponent("bin/ssh"), "exit 0")
            let tools = await FileTools.lookUp(environment: ["PATH": folder.appendingPathComponent("bin").path])
            #expect(tools.ssh == ssh)
            #expect(await FileTools.lookUp(environment: ["PATH": folder.path]).ssh == nil)
        }
    }
}
