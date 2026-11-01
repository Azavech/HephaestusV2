import Foundation
import Testing
@testable import HephaestusCore

/// docs/search.md › Code search: the file list, the lines and the 100 results.
@Suite("Code search")
struct CodeSearchTests {
    /// A git executable and an environment that ignores the machine's git configuration, or nil
    /// when this Mac has no working git. Like every tool run of the tests, its exit is awaited, so
    /// that no thread of the test run waits for it.
    static func git() async -> SearchGit? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        guard let executable = path.split(separator: ":").map({ "\($0)/git" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HephaestusCoreTests-git-home", isDirectory: true).path
        let environment = ["PATH": path, "HOME": home, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let request = ChildProcessRequest(executable: executable, arguments: ["--version"], environment: environment)
        guard let result = try? await ChildProcessRunner.run(request, timeout: waitLimit), result.termination.isSuccess else { return nil }
        return SearchGit(executable: executable, environment: environment)
    }

    private func git(_ arguments: [String], in folder: URL) async throws {
        let git = try #require(await Self.git())
        let request = ChildProcessRequest(executable: git.executable, arguments: ["-C", folder.path] + arguments, environment: git.environment)
        let result = try await ChildProcessRunner.run(request, timeout: waitLimit)
        #expect(result.termination.isSuccess)
    }

    private func paths(_ data: SearchProjectData, git: SearchGit? = nil) async -> [String] {
        await CodeSearch.fileList(data, git: git).map(\.path)
    }

    @Test("The walk skips build folders at any depth, .hephaestus/chats, sub projects and symbolic links")
    func walk() async throws {
        try await withTemporaryDirectory { (root: URL) async throws in
            for path in ["b.swift", "C.swift", "a/x.swift", "é.swift", ".hidden", ".hephaestus/project.yml", ".hephaestus/ticket/HEPH-1.yml",
                         ".hephaestus/chats/x.jsonl", "nested/.git/config", "nested/build/out", ".build/x", "DerivedData/x",
                         "web/node_modules/x.js", "builder/kept.swift", "sub/file.swift", "sub/.hephaestus/project.yml",
                         "deeper/sub2/inner.swift"] {
                try writeFile(path, in: root, "x\n")
            }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.swift"),
                                                       withDestinationURL: root.appendingPathComponent("b.swift"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkdir"),
                                                       withDestinationURL: root.appendingPathComponent("a"))
            let data = SearchSourcesTests.project("HEPH", name: "H", root: root, subprojects: ["sub", "deeper/sub2"])
            #expect(await paths(data) == [".hephaestus/project.yml", ".hephaestus/ticket/HEPH-1.yml", ".hidden", "C.swift", "a/x.swift",
                                          "b.swift", "builder/kept.swift", "é.swift"])
        }
    }

    @Test("Lines: at most 1 MB, text only, CR removed, every term on the same line, 1-based numbers")
    func lines() async throws {
        try await withTemporaryDirectory { (root: URL) async throws in
            try writeFile("crlf.txt", in: root, "alpha beta\r\nbeta only\r\nBETA ALPHA\r\n")
            try writeFile("split.txt", in: root, "alpha\nbeta\n")
            try writeFile("big.txt", in: root, "alpha beta\n" + String(repeating: "x", count: 1_048_576))
            try Data("alpha beta\n\0".utf8).write(to: root.appendingPathComponent("nul.bin"))
            try Data([0x61, 0x6C, 0x70, 0x68, 0x61, 0x20, 0x62, 0x65, 0x74, 0x61, 0x0A, 0xFF]).write(to: root.appendingPathComponent("latin.txt"))
            let data = SearchSourcesTests.project("HEPH", name: "Hephaestus V2", root: root)
            let results = try await SearchSourcesTests.run("alpha beta", [data], scopes: [.code])
            #expect(results.map(\.id) == ["code:HEPH:crlf.txt:1", "code:HEPH:crlf.txt:3"])
            #expect(results.map(\.snippet) == ["alpha beta", "BETA ALPHA"])
            #expect(results[1].target == .file(projectID: "HEPH", path: "crlf.txt", line: 3))
            #expect(results[1].title == "crlf.txt:3")
        }
    }

    @Test("At most 100 code results, the best ranked: newest files first, then project, then path")
    func hundred() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            let one = folder.appendingPathComponent("one", isDirectory: true)
            let two = folder.appendingPathComponent("two", isDirectory: true)
            let base = SearchSourcesTests.base
            try writeFile("old.txt", in: one, String(repeating: "match\n", count: 60))
            try setModified(one.appendingPathComponent("old.txt"), base)
            try writeFile("new.txt", in: one, String(repeating: "match\n", count: 60))
            try setModified(one.appendingPathComponent("new.txt"), base.addingTimeInterval(100))
            try writeFile("same.txt", in: two, "match\n")
            try setModified(two.appendingPathComponent("same.txt"), base.addingTimeInterval(100.5))
            try writeFile("a.txt", in: two, "match\n")
            try setModified(two.appendingPathComponent("a.txt"), base.addingTimeInterval(100.2))
            let projects = [SearchSourcesTests.project("BB", name: "B", root: two), SearchSourcesTests.project("AA", name: "A", root: one)]
            let results = try await SearchSourcesTests.run("match", projects, scopes: [.code])
            #expect(results.count == 100)
            #expect(results.prefix(3).map(\.id) == ["code:AA:new.txt:1", "code:AA:new.txt:2", "code:AA:new.txt:3"])
            #expect(results[59].id == "code:AA:new.txt:60")
            #expect(results[60].id == "code:BB:a.txt:1")
            #expect(results[61].id == "code:BB:same.txt:1")
            #expect(results[62].id == "code:AA:old.txt:1")
            #expect(results[99].id == "code:AA:old.txt:38")
        }
    }

    @Test("Inside a git work tree: tracked and untracked files that are not ignored, nested repositories dropped",
          .enabled { await CodeSearchTests.git() != nil })
    func gitList() async throws {
        try await withTemporaryDirectory { (root: URL) async throws in
            try await git(["init", "-q"], in: root)
            for path in ["tracked.swift", "untracked.swift", "ignored.log", "build/kept-by-git.swift", "removed.swift",
                         "sub/inner.swift", ".hephaestus/project.yml", ".hephaestus/chats/x.jsonl"] {
                try writeFile(path, in: root, "x\n")
            }
            try writeFile(".gitignore", in: root, "*.log\n")
            try writeFile(".hephaestus/.gitignore", in: root, "chats/\n")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try await git(["init", "-q"], in: root.appendingPathComponent("nested"))
            try writeFile("nested/inside.swift", in: root, "x\n")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.swift"),
                                                       withDestinationURL: root.appendingPathComponent("tracked.swift"))
            try await git(["add", "tracked.swift", "removed.swift", "link.swift"], in: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent("removed.swift"))

            let data = SearchSourcesTests.project("HEPH", name: "H", root: root, subprojects: ["sub"])
            #expect(await paths(data, git: await CodeSearchTests.git()) == [".gitignore", ".hephaestus/.gitignore", ".hephaestus/project.yml",
                                                                     "build/kept-by-git.swift", "tracked.swift", "untracked.swift"])

            let subfolder = SearchSourcesTests.project("SUB", name: "S", root: root.appendingPathComponent("sub"))
            #expect(await paths(subfolder, git: await CodeSearchTests.git()) == ["inner.swift"])
        }
    }

    @Test("Outside a git work tree, or when git fails, the folder is walked", .enabled { await CodeSearchTests.git() != nil })
    func gitFallback() async throws {
        try await withTemporaryDirectory { (root: URL) async throws in
            try writeFile("file.swift", in: root, "x\n")
            try writeFile("build/out", in: root, "x\n")
            let data = SearchSourcesTests.project("HEPH", name: "H", root: root)
            #expect(await paths(data, git: await CodeSearchTests.git()) == ["file.swift"])
            let broken = SearchGit(executable: "/nonexistent/git", environment: [:])
            #expect(await paths(data, git: broken) == ["file.swift"])
        }
    }
}
