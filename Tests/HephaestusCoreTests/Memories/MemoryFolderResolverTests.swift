import Foundation
import Testing
@testable import HephaestusCore

/// docs/memories.md › Resolution, on temporary folders: the resolver never reads `~/.claude` here.
@Suite("Memory folder resolution")
struct MemoryFolderResolverTests {
    /// A resolver whose home folder is `<folder>/home`, without managed settings.
    private func resolver(_ folder: URL, configDirectory: String? = nil, managed: String? = nil) -> ClaudeMemoryFolderResolver {
        ClaudeMemoryFolderResolver(homeDirectory: folder.appendingPathComponent("home").path, configDirectory: configDirectory,
                                   managedSettingsPath: managed)
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try makeFolder(url.deletingLastPathComponent())
        try Data(text.utf8).write(to: url)
    }

    /// The real path of a temporary folder: `/var/folders/…` is `/private/var/folders/…`.
    private func real(_ url: URL) -> String {
        ClaudeMemoryFolderResolver.realPath(url.path)
    }

    @Test("The folder name replaces each UTF-16 unit other than an ASCII letter or digit and hashes names past 200 units")
    func folderNames() {
        #expect(ClaudeMemoryFolderResolver.folderName(of: "/Users/example/Developer/HephaestusV2") == "-Users-example-Developer-HephaestusV2")
        #expect(ClaudeMemoryFolderResolver.folderName(of: "/Users/example/Café") == "-Users-example-Caf-")
        #expect(ClaudeMemoryFolderResolver.folderName(of: "/Users/example/a📁b") == "-Users-example-a--b")
        #expect(ClaudeMemoryFolderResolver.folderName(of: "/Users/example/my_app 2") == "-Users-example-my-app-2")
        // The vector of Claude Code 2.1.309: the first 200 units, then the base-36 Java hash.
        let long = "/Users/example/" + String(repeating: "x", count: 200)
        #expect(ClaudeMemoryFolderResolver.javaHashCode(long) == 396_783_419)
        #expect(ClaudeMemoryFolderResolver.folderName(of: long) == "-Users-example-" + String(repeating: "x", count: 185) + "-6k8g1n")
        #expect(ClaudeMemoryFolderResolver.folderName(of: String(repeating: "a", count: 200)) == String(repeating: "a", count: 200))
    }

    @Test("A project outside git uses its root, with its links resolved")
    func outsideGit() throws {
        try withTemporaryDirectory { folder in
            let root = folder.appendingPathComponent("Notes")
            try makeFolder(root)
            let config = folder.appendingPathComponent("config").path
            let path = resolver(folder, configDirectory: config).memoryFolder(projectRoot: root.path, environment: [:])
            #expect(real(root).hasPrefix("/private/"))
            #expect(path == config + "/projects/" + ClaudeMemoryFolderResolver.folderName(of: real(root)) + "/memory")
        }
    }

    @Test("A repository, a sub project inside it and a linked worktree of it share the main working tree's folder")
    func gitWorkingTrees() throws {
        try withTemporaryDirectory { folder in
            let base = URL(fileURLWithPath: real(folder))
            let repository = base.appendingPathComponent("Repo")
            try makeFolder(repository.appendingPathComponent(".git/worktrees/HEPH-12"))
            try makeFolder(repository.appendingPathComponent("site"))
            // The layout `git worktree add` writes: a `.git` file in the worktree, and `commondir`
            // and `gitdir` in the repository's `.git/worktrees/<name>`.
            let worktree = base.appendingPathComponent("Worktrees/HEPH/HEPH-12")
            try write("gitdir: \(repository.path)/.git/worktrees/HEPH-12\n", to: worktree.appendingPathComponent(".git"))
            try write("../..\n", to: repository.appendingPathComponent(".git/worktrees/HEPH-12/commondir"))
            try write("\(worktree.path)/.git\n", to: repository.appendingPathComponent(".git/worktrees/HEPH-12/gitdir"))

            let config = base.appendingPathComponent("config").path
            let expected = config + "/projects/" + ClaudeMemoryFolderResolver.folderName(of: repository.path) + "/memory"
            let resolver = resolver(folder, configDirectory: config)
            #expect(resolver.memoryFolder(projectRoot: repository.path, environment: [:]) == expected)
            #expect(resolver.memoryFolder(projectRoot: repository.appendingPathComponent("site").path, environment: [:]) == expected)
            #expect(resolver.memoryFolder(projectRoot: worktree.path, environment: [:]) == expected)

            // A `gitdir` file that does not point back to the worktree: the worktree is its own base.
            try write("/elsewhere/.git\n", to: repository.appendingPathComponent(".git/worktrees/HEPH-12/gitdir"))
            #expect(resolver.memoryFolder(projectRoot: worktree.path, environment: [:])
                == config + "/projects/" + ClaudeMemoryFolderResolver.folderName(of: worktree.path) + "/memory")
        }
    }

    @Test("A submodule, whose git folder is not under worktrees, is its own base")
    func submodule() throws {
        try withTemporaryDirectory { folder in
            let base = URL(fileURLWithPath: real(folder))
            let repository = base.appendingPathComponent("Repo")
            let module = repository.appendingPathComponent("vendor/lib")
            try makeFolder(repository.appendingPathComponent(".git/modules/lib"))
            try write("gitdir: ../../.git/modules/lib\n", to: module.appendingPathComponent(".git"))
            let config = base.appendingPathComponent("config").path
            #expect(resolver(folder, configDirectory: config).memoryFolder(projectRoot: module.path, environment: [:])
                == config + "/projects/" + ClaudeMemoryFolderResolver.folderName(of: module.path) + "/memory")
        }
    }

    @Test("The config folder is CLAUDE_CONFIG_DIR when it is set and not empty, otherwise ~/.claude")
    func configFolder() throws {
        try withTemporaryDirectory { folder in
            let root = URL(fileURLWithPath: real(folder)).appendingPathComponent("Notes")
            try makeFolder(root)
            let name = ClaudeMemoryFolderResolver.folderName(of: root.path)
            let resolver = resolver(folder)
            let home = folder.appendingPathComponent("home").path
            #expect(resolver.memoryFolder(projectRoot: root.path, environment: [:]) == "\(home)/.claude/projects/\(name)/memory")
            #expect(resolver.memoryFolder(projectRoot: root.path, environment: ["CLAUDE_CONFIG_DIR": ""])
                == "\(home)/.claude/projects/\(name)/memory")
            let config = folder.appendingPathComponent("Other Config").path
            #expect(resolver.memoryFolder(projectRoot: root.path, environment: ["CLAUDE_CONFIG_DIR": config])
                == "\(config)/projects/\(name)/memory")
        }
    }

    @Test("autoMemoryDirectory: managed, local, project, then user settings; ~/ is the home folder; a refused value gives the default")
    func autoMemoryDirectory() throws {
        try withTemporaryDirectory { folder in
            let root = URL(fileURLWithPath: real(folder)).appendingPathComponent("Notes")
            try makeFolder(root)
            let config = folder.appendingPathComponent("config")
            let managed = folder.appendingPathComponent("managed-settings.json")
            let home = folder.appendingPathComponent("home").path
            let resolver = resolver(folder, configDirectory: config.path, managed: managed.path)
            let standard = config.path + "/projects/" + ClaudeMemoryFolderResolver.folderName(of: root.path) + "/memory"
            func folderNow() -> String { resolver.memoryFolder(projectRoot: root.path, environment: [:]) }

            #expect(folderNow() == standard)
            try write(#"{"autoMemoryDirectory": "~/Memories/"}"#, to: config.appendingPathComponent("settings.json"))
            #expect(folderNow() == "\(home)/Memories")
            try write(#"{"autoMemoryDirectory": "/Volumes/Data/./project/../memories"}"#, to: root.appendingPathComponent(".claude/settings.json"))
            #expect(folderNow() == "/Volumes/Data/memories")
            try write(#"{"autoMemoryDirectory": null}"#, to: root.appendingPathComponent(".claude/settings.local.json"))
            #expect(folderNow() == "/Volumes/Data/memories")
            try write(#"{"autoMemoryDirectory": "/Volumes/Local"}"#, to: root.appendingPathComponent(".claude/settings.local.json"))
            #expect(folderNow() == "/Volumes/Local")
            try write(#"{"autoMemoryDirectory": "/Volumes/Managed"}"#, to: managed)
            #expect(folderNow() == "/Volumes/Managed")

            // A refused value does not fall through to the next source.
            for refused in ["relative/memories", "~/", "~/../outside", "~", "/net/host/x", "/Network/Servers/x", "/.vol/1/2", "/a"] {
                try write(#"{"autoMemoryDirectory": "\#(refused)"}"#, to: managed)
                #expect(folderNow() == standard, "value \(refused)")
            }
            // As Node's path.normalize, `//` at the start is one `/`.
            try write(#"{"autoMemoryDirectory": "//Volumes/Shared/"}"#, to: managed)
            #expect(folderNow() == "/Volumes/Shared")
            try write("not json", to: managed)
            #expect(folderNow() == "/Volumes/Local")
        }
    }

    @Test("Settings files are strict JSON; a non-string value drops the file; local settings of the main working tree win; managed drop-ins merge")
    func settingsSources() throws {
        try withTemporaryDirectory { folder in
            let base = URL(fileURLWithPath: real(folder))
            let repository = base.appendingPathComponent("Repo")
            let root = repository.appendingPathComponent("site")
            try makeFolder(repository.appendingPathComponent(".git"))
            try makeFolder(root)
            let config = base.appendingPathComponent("config")
            let managed = base.appendingPathComponent("ClaudeCode/managed-settings.json")
            let home = folder.appendingPathComponent("home").path
            let resolver = resolver(folder, configDirectory: config.path, managed: managed.path)
            let standard = config.path + "/projects/" + ClaudeMemoryFolderResolver.folderName(of: repository.path) + "/memory"
            func folderNow() -> String { resolver.memoryFolder(projectRoot: root.path, environment: [:]) }

            // A comment makes the file invalid JSON for the CLI: it gives nothing.
            try write("{\"autoMemoryDirectory\": \"~/Commented\", // note\n}", to: config.appendingPathComponent("settings.json"))
            #expect(folderNow() == standard)
            try write("\u{FEFF}{\"autoMemoryDirectory\": \"~/User\"}", to: config.appendingPathComponent("settings.json"))
            #expect(folderNow() == "\(home)/User")
            // A value that is not a string makes the CLI drop the file: the next source applies.
            try write(#"{"autoMemoryDirectory": false}"#, to: root.appendingPathComponent(".claude/settings.json"))
            #expect(folderNow() == "\(home)/User")
            // The project root's local settings, then the main working tree's, which win.
            try write(#"{"autoMemoryDirectory": "/Volumes/Site"}"#, to: root.appendingPathComponent(".claude/settings.local.json"))
            #expect(folderNow() == "/Volumes/Site")
            try write(#"{"permissions": {"allow": []}}"#, to: repository.appendingPathComponent(".claude/settings.local.json"))
            #expect(folderNow() == "/Volumes/Site")
            try write(#"{"autoMemoryDirectory": "/Volumes/Repo"}"#, to: repository.appendingPathComponent(".claude/settings.local.json"))
            #expect(folderNow() == "/Volumes/Repo")
            // Managed: managed-settings.json, then managed-settings.d by name; the last value wins.
            try write(#"{"autoMemoryDirectory": "/Volumes/Managed"}"#, to: managed)
            #expect(folderNow() == "/Volumes/Managed")
            try write(#"{"autoMemoryDirectory": "/Volumes/DropIn20"}"#, to: managed.deletingLastPathComponent().appendingPathComponent("managed-settings.d/20-b.json"))
            try write(#"{"autoMemoryDirectory": "/Volumes/DropIn10"}"#, to: managed.deletingLastPathComponent().appendingPathComponent("managed-settings.d/10-a.json"))
            try write(#"{"autoMemoryDirectory": "/Volumes/Hidden"}"#, to: managed.deletingLastPathComponent().appendingPathComponent("managed-settings.d/.30-c.json"))
            #expect(folderNow() == "/Volumes/DropIn20")
        }
    }

    @Test("autoMemoryDirectory values are checked as the CLI checks them")
    func directoryValues() {
        let home = "/Users/example"
        func folder(_ value: String) -> String? { ClaudeMemoryFolderResolver.memoryDirectory(value, homeDirectory: home) }
        #expect(folder("~\\Memories") == "/Users/example/Memories")
        #expect(folder("/Volumes/Data/Memories\\") == "/Volumes/Data/Memories")
        #expect(folder("~/./") == "/Users/example")
        #expect(folder("~/a/../") == "/Users/example")
        #expect(folder("/net") == "/net")
        #expect(folder("/ab") == "/ab")
        #expect(folder("/e\u{301}") == "/\u{E9}")
        for refused in ["/\\x", "/??/x", "/net/host", "/NET/host/share", "/Network", "/network/x", "/.VOL/1", "~/..\\x", "~", "rel/x", "/a"] {
            #expect(folder(refused) == nil, "value \(refused)")
        }
    }

    @Test("A worktree whose paths hold a backslash is its own base, as for the CLI")
    func backslashWorktree() throws {
        try withTemporaryDirectory { folder in
            let base = URL(fileURLWithPath: real(folder))
            let repository = base.appendingPathComponent("Dev\\Repo")
            try makeFolder(repository.appendingPathComponent(".git/worktrees/wt"))
            let worktree = base.appendingPathComponent("wt")
            try write("gitdir: \(repository.path)/.git/worktrees/wt\n", to: worktree.appendingPathComponent(".git"))
            try write("../..\n", to: repository.appendingPathComponent(".git/worktrees/wt/commondir"))
            try write("\(worktree.path)/.git\n", to: repository.appendingPathComponent(".git/worktrees/wt/gitdir"))
            #expect(ClaudeMemoryFolderResolver.mainWorkingTree(ofRoot: worktree.path) == worktree.path)
        }
    }

    @Test("The test configuration resolves under folders next to the data directory, never ~/.claude")
    func testConfiguration() async throws {
        try await withTestEngine { engine, _, folder in
            let resolver = try #require(engine.configuration.memoryFolders as? ClaudeMemoryFolderResolver)
            #expect(resolver.configDirectory == folder.appendingPathComponent("Claude").path)
            #expect(resolver.homeDirectory == folder.appendingPathComponent("Home").path)
            #expect(resolver.managedSettingsPath == nil)
        }
    }
}
