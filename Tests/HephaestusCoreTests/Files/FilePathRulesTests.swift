import Foundation
import Testing
@testable import HephaestusCore

@Suite("Project paths")
struct ProjectPathsTests {
    @Test("Valid project paths are kept; one trailing / is removed first")
    func valid() throws {
        #expect(try ProjectPaths.normalize("Sources/App.swift", param: "path", allowRoot: false) == "Sources/App.swift")
        #expect(try ProjectPaths.normalize("Sources/", param: "path", allowRoot: false) == "Sources")
        #expect(try ProjectPaths.normalize(".hephaestus/project.yml", param: "path", allowRoot: false) == ".hephaestus/project.yml")
        #expect(try ProjectPaths.normalize("..hidden/a...b", param: "path", allowRoot: false) == "..hidden/a...b")
        #expect(try ProjectPaths.normalize("", param: "path", allowRoot: true) == "")
        #expect(try ProjectPaths.normalize("/", param: "path", allowRoot: true) == "")
    }

    @Test("Paths that break a rule fail with invalid, naming the param")
    func invalid() {
        for value in ["/Sources", "a//b", "./a", "a/./b", "a/..", "../a", "a/b//", "a\u{0}b", "."] {
            #expect(throws: EngineError.self) { try ProjectPaths.normalize(value, param: "path", allowRoot: true) }
            do {
                _ = try ProjectPaths.normalize(value, param: "newPath", allowRoot: true)
            } catch let error as EngineError {
                #expect(error.code == .invalid)
                #expect(error.message.hasPrefix("newPath: "))
                #expect(error.message.hasSuffix("."))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        #expect(throws: EngineError(.invalid, "path: name a file or folder inside the project, not the project root.")) {
            try ProjectPaths.normalize("", param: "path", allowRoot: false)
        }
    }

    @Test("Chats folders and .git folders are recognized at any depth")
    func protectedFolders() {
        #expect(ProjectPaths.isInChatsFolder(".hephaestus/chats"))
        #expect(ProjectPaths.isInChatsFolder(".hephaestus/chats/A.yml"))
        #expect(ProjectPaths.isInChatsFolder("Sub/.hephaestus/chats/A.jsonl"))
        #expect(!ProjectPaths.isInChatsFolder(".hephaestus"))
        #expect(!ProjectPaths.isInChatsFolder(".hephaestus/chatsx"))
        #expect(!ProjectPaths.isInChatsFolder("chats/.hephaestus"))
        #expect(ProjectPaths.isInGitFolder(".git"))
        #expect(ProjectPaths.isInGitFolder(".git/index"))
        #expect(ProjectPaths.isInGitFolder("Sub/.git/HEAD"))
        #expect(!ProjectPaths.isInGitFolder(".gitignore"))
        #expect(!ProjectPaths.isInGitFolder(""))
    }

    @Test("Joining, parents, names and ancestors")
    func helpers() {
        #expect(ProjectPaths.join("", "a") == "a")
        #expect(ProjectPaths.join("a", "b") == "a/b")
        #expect(ProjectPaths.parent("a/b/c") == "a/b")
        #expect(ProjectPaths.parent("a") == "")
        #expect(ProjectPaths.name("a/b/c.txt") == "c.txt")
        #expect(ProjectPaths.isStrictlyInside("a/b", "a"))
        #expect(!ProjectPaths.isStrictlyInside("a", "a"))
        #expect(!ProjectPaths.isStrictlyInside("ab", "a"))
        #expect(ProjectPaths.ancestor(of: "a/b/c", depth: 1) == "a")
        #expect(ProjectPaths.ancestor(of: "a/b/c", depth: 2) == "a/b")
        #expect(ProjectPaths.ancestor(of: "a", depth: 2) == "a")
    }

    @Test("Absolute paths are standardized without resolving links")
    func absolutePaths() {
        #expect(FileSystemItems.standardizedAbsolutePath("/Users/example/./Developer//x/../y/") == "/Users/example/Developer/y")
        #expect(FileSystemItems.standardizedAbsolutePath("/..") == "/")
        #expect(FileSystemItems.standardizedAbsolutePath("/") == "/")
        #expect(FileSystemItems.standardizedAbsolutePath("/var/folders") == "/var/folders")
        #expect(FileSystemItems.standardizedAbsolutePath("relative") == nil)
        #expect(FileSystemItems.standardizedAbsolutePath("~/x") == nil)
    }
}

@Suite("files.changed paths")
struct ChangedPathsTests {
    @Test("Up to 500 paths are sent sorted and distinct; the root wins")
    func underLimit() {
        #expect(ChangedPaths.limited(["b", "a/c", "a"]) == ["a", "a/c", "b"])
        #expect(ChangedPaths.limited(["b", "", "a"]) == [""])
        let many = Set((0..<500).map { "f\($0)" })
        #expect(ChangedPaths.limited(many).count == 500)
    }

    @Test("More than 500 paths are replaced by their ancestors at the deepest depth that fits")
    func overLimit() {
        // 600 files in 3 folders of 2 folders each: depth 2 gives 6 paths.
        var paths: Set<String> = []
        for index in 0..<600 {
            paths.insert("top\(index % 3)/mid\(index % 2)/file\(index).txt")
        }
        #expect(ChangedPaths.limited(paths) == ["top0/mid0", "top0/mid1", "top1/mid0", "top1/mid1", "top2/mid0", "top2/mid1"])

        // 400 folders at depth 2 under each of 2 top-level folders: depth 2 is 800, depth 1 fits.
        paths = []
        for index in 0..<800 {
            paths.insert("t\(index % 2)/d\(index)/f")
        }
        #expect(ChangedPaths.limited(paths) == ["t0", "t1"])

        // Shallow paths stay themselves at a depth larger than theirs.
        paths = ["README.md"]
        for index in 0..<600 {
            paths.insert(".build/x\(index % 10)/y\(index)")
        }
        #expect(ChangedPaths.limited(paths) == [".build/x0", ".build/x1", ".build/x2", ".build/x3", ".build/x4",
                                                ".build/x5", ".build/x6", ".build/x7", ".build/x8", ".build/x9", "README.md"])
    }

    @Test("More than 500 top-level entries give the whole project")
    func wholeProject() {
        let paths = Set((0..<501).map { "entry\($0)/file" })
        #expect(ChangedPaths.limited(paths) == [""])
        #expect(ChangedPaths.limited(Set((0..<501).map { "entry\($0)" })) == [""])
    }

    @Test("Only the data files the engine loads reach projectDataFilesChanged")
    func dataPaths() {
        #expect(ChangedPaths.dataPath(of: "") == ".hephaestus")
        #expect(ChangedPaths.dataPath(of: ".hephaestus") == ".hephaestus")
        #expect(ChangedPaths.dataPath(of: ".hephaestus/project.yml") == ".hephaestus/project.yml")
        #expect(ChangedPaths.dataPath(of: ".hephaestus/ticket") == ".hephaestus/ticket")
        #expect(ChangedPaths.dataPath(of: ".hephaestus/bundle") == ".hephaestus/bundle")
        #expect(ChangedPaths.dataPath(of: ".hephaestus/ticket/HEPH-12.yml") == ".hephaestus/ticket/HEPH-12.yml")
        #expect(ChangedPaths.dataPath(of: ".hephaestus/bundle/HEPH-B2.yml") == ".hephaestus/bundle/HEPH-B2.yml")
        for path in [".hephaestus/ticket/HEPH-12.yml.orig", ".hephaestus/ticket/.HEPH-12.yml.\(UUID().uuidString).tmp",
                     ".hephaestus/ticket/.DS_Store", ".hephaestus/bundle/HEPH-12.yml", ".hephaestus/chats/A.yml",
                     ".hephaestus/chats", ".hephaestus/attachments/HEPH-1/x.png", ".hephaestus/.gitignore",
                     ".hephaestus/project.yml.bak", "Sources/a.swift", "Sub/.hephaestus/project.yml", ".hephaestusx/project.yml"] {
            #expect(ChangedPaths.dataPath(of: path) == nil, "\(path)")
        }
    }

    @Test("Event paths map to project paths in both forms of the root")
    func eventPaths() {
        let root = WatchedProjectRoot(id: "TEST", path: "/var/example/Project")
        #expect(root.resolvedPath == FileSystemItems.resolvedPath("/var/example/Project"))
        #expect(root.projectPath(ofEventPath: "/var/example/Project") == "")
        #expect(root.projectPath(ofEventPath: "/var/example/Project/a/b.txt") == "a/b.txt")
        #expect(root.projectPath(ofEventPath: root.resolvedPath + "/a/b.txt") == "a/b.txt")
        #expect(root.projectPath(ofEventPath: "/var/example") == "")
        #expect(root.projectPath(ofEventPath: "/var/example/ProjectX/a") == nil)
        #expect(root.projectPath(ofEventPath: "/elsewhere/a") == nil)
    }

    @Test("Data directory events concern registry.yml and settings.yml only")
    func dataDirectoryNames() {
        let folders: Set<String> = ["/data"]
        func names(_ path: String, _ flags: Int) -> Set<String> {
            Engine.dataDirectoryFileNames(of: FileWatcher.Event(path: path, flags: FSEventStreamEventFlags(flags)), folders: folders)
        }
        #expect(names("/data/settings.yml", kFSEventStreamEventFlagItemModified) == ["settings.yml"])
        #expect(names("/data/registry.yml", kFSEventStreamEventFlagItemRenamed) == ["registry.yml"])
        #expect(names("/data/Logs/engine.log", kFSEventStreamEventFlagItemModified).isEmpty)
        #expect(names("/data/remotes.yml", kFSEventStreamEventFlagItemModified).isEmpty)
        #expect(names("/data/Skills/settings.yml", kFSEventStreamEventFlagItemModified).isEmpty)
        #expect(names("/data", kFSEventStreamEventFlagMustScanSubDirs) == ["registry.yml", "settings.yml"])
        #expect(names("/data", kFSEventStreamEventFlagRootChanged) == ["registry.yml", "settings.yml"])
    }
}

@Suite("Doc titles")
struct DocTitleTests {
    @Test("The first line starting with # gives the title, trimmed")
    func titles() {
        #expect(DocsFolder.title(in: Data("# Engine API\n\nText".utf8)) == "Engine API")
        #expect(DocsFolder.title(in: Data("---\ntitle: x\n---\n#  Spaced title  \r\nmore".utf8)) == "Spaced title")
        #expect(DocsFolder.title(in: Data("#NoSpace\n## Second\n# Third\n".utf8)) == "Third")
        #expect(DocsFolder.title(in: Data("\u{FEFF}# With BOM\n".utf8)) == "With BOM")
        #expect(DocsFolder.title(in: Data("text\n # indented\n".utf8)) == nil)
        #expect(DocsFolder.title(in: Data("# ".utf8)) == "")
        #expect(DocsFolder.title(in: Data()) == nil)
    }

    @Test("Doc names end in .md or .markdown in any case")
    func names() {
        #expect(DocsFolder.isDocName("a.md"))
        #expect(DocsFolder.isDocName("A.MD"))
        #expect(DocsFolder.isDocName("b.Markdown"))
        #expect(!DocsFolder.isDocName("c.mdown"))
        #expect(!DocsFolder.isDocName("md"))
    }
}
