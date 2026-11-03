import Foundation
import Testing
@testable import HephaestusCore

@Suite("docs.list")
struct DocsListTests {
    @Test("Lists the Markdown files under docsPath, recursively, in Finder order, with their titles")
    func list() async throws {
        try await withFileTestEngine(files: [
            "docs/README.md": "# Read me\n",
            "docs/engine-api.md": "Intro\n\n# Engine API\n",
            "docs/guides/setup.markdown": "no heading",
            "docs/guides/UPPER.MD": "#  Upper  \n",
            "docs/notes.txt": "# Not a doc",
            "docs/.hidden.md": "# Hidden",
            "docs/.drafts/draft.md": "# Draft",
            "docs/file10.md": "# Ten",
            "docs/file2.md": "# Two",
            "README.md": "# Outside",
        ]) { _, connection, _ in
            let docs = try await connection.call(DocsList.self, .init(projectID: "test"))
            #expect(docs == [
                DocEntry(path: "docs/engine-api.md", title: "Engine API"),
                DocEntry(path: "docs/file2.md", title: "Two"),
                DocEntry(path: "docs/file10.md", title: "Ten"),
                DocEntry(path: "docs/guides/setup.markdown", title: "setup"),
                DocEntry(path: "docs/guides/UPPER.MD", title: "Upper"),
                DocEntry(path: "docs/README.md", title: "Read me"),
            ])
        }
    }

    @Test("A nested docsPath is used; a missing docs folder gives an empty list")
    func docsPath() async throws {
        try await withFileTestEngine(docsPath: "documentation/guides", files: ["documentation/guides/a.md": "# A", "docs/b.md": "# B"]) { _, connection, project in
            #expect(try await connection.call(DocsList.self, .init(projectID: "TEST")) == [DocEntry(path: "documentation/guides/a.md", title: "A")])
            try FileManager.default.removeItem(at: project.url("documentation"))
            #expect(try await connection.call(DocsList.self, .init(projectID: "TEST")).isEmpty)
            try project.write("documentation/guides", "a file, not a folder")
            #expect(try await connection.call(DocsList.self, .init(projectID: "TEST")).isEmpty)
        }
    }

    @Test("Links to doc files are listed; links to folders are not followed")
    func links() async throws {
        try await withFileTestEngine(files: ["docs/a.md": "# A", "other/b.md": "# B", "other/c.md": "# C"]) { _, connection, project in
            try FileManager.default.createSymbolicLink(atPath: project.url("docs/b.md").path, withDestinationPath: "../other/b.md")
            try FileManager.default.createSymbolicLink(atPath: project.url("docs/other").path, withDestinationPath: "../other")
            try FileManager.default.createSymbolicLink(atPath: project.url("docs/loop").path, withDestinationPath: ".")
            let docs = try await connection.call(DocsList.self, .init(projectID: "TEST"))
            #expect(docs.map(\.path) == ["docs/a.md", "docs/b.md"])
        }
    }

    @Test("Errors: unknown and malformed project identifiers")
    func errors() async throws {
        try await withFileTestEngine { _, connection, _ in
            #expect(await engineError { try await connection.call(DocsList.self, .init(projectID: "NOPE")) } == EngineError(.notFound, "Project NOPE not found."))
            #expect(await engineError { try await connection.call(DocsList.self, .init(projectID: "N0PE")) }?.code == .invalid)
        }
    }
}

@Suite("fs.browse")
struct FSBrowseTests {
    @Test("Lists the visible sub-directories in Finder order, each telling whether it holds a project")
    func browse() async throws {
        try await withFileTestEngine(files: ["Project2/file.txt": "x"]) { _, connection, project in
            let base = project.folder.appendingPathComponent("Browse", isDirectory: true)
            for name in ["beta", "Alpha", "item10", "item2", ".hidden", "withProject/.hephaestus"] {
                try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try Data("id: X".utf8).write(to: base.appendingPathComponent("withProject/.hephaestus/project.yml"))
            try Data().write(to: base.appendingPathComponent("file.txt"))
            try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("linked").path, withDestinationPath: "beta")

            let result = try await connection.call(FSBrowse.self, .init(path: base.path + "/./beta/..//"))
            #expect(result.path == base.path)
            #expect(result.parent == project.folder.path)
            #expect(result.entries.map(\.name) == ["Alpha", "beta", "item2", "item10", "linked", "withProject"])
            #expect(result.entries.map(\.path) == result.entries.map { base.path + "/" + $0.name })
            #expect(result.entries.filter(\.hasProject).map(\.name) == ["withProject"])
        }
    }

    @Test("hasGoMod tells whether the listed folder itself has a go.mod file")
    func goMod() async throws {
        try await withFileTestEngine { _, connection, project in
            let base = project.folder.appendingPathComponent("Modules", isDirectory: true)
            for name in ["service", "linked", "plain", "folderNamedGoMod/go.mod", "parentOfModule/child"] {
                try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try Data("module example.com/service\n".utf8).write(to: base.appendingPathComponent("service/go.mod"))
            try Data().write(to: base.appendingPathComponent("parentOfModule/child/go.mod"))
            try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("linked/go.mod").path,
                                                       withDestinationPath: "../service/go.mod")

            for (name, expected) in [("service", true), ("linked", true), ("plain", false), ("folderNamedGoMod", false), ("parentOfModule", false)] {
                let result = try await connection.call(FSBrowse.self, .init(path: base.appendingPathComponent(name).path))
                #expect(result.hasGoMod == expected, "\(name)")
            }
        }
    }

    @Test("The root has no parent")
    func root() async throws {
        try await withFileTestEngine { _, connection, _ in
            let result = try await connection.call(FSBrowse.self, .init(path: "/"))
            #expect(result.path == "/")
            #expect(result.parent == nil)
            #expect(result.entries.allSatisfy { !$0.name.hasPrefix(".") && $0.path == "/" + $0.name })
        }
    }

    @Test("Errors: relative paths, files, missing folders")
    func errors() async throws {
        try await withFileTestEngine(files: ["a.txt": "a"]) { _, connection, project in
            #expect(await engineError { try await connection.call(FSBrowse.self, .init(path: "relative/path")) }
                == EngineError(.invalid, "path: use an absolute path."))
            #expect(await engineError { try await connection.call(FSBrowse.self, .init(path: project.url("a.txt").path)) }
                == EngineError(.invalid, "path: \(project.url("a.txt").path) is not a directory."))
            let missing = project.folder.appendingPathComponent("missing").path
            #expect(await engineError { try await connection.call(FSBrowse.self, .init(path: missing)) }
                == EngineError(.notFound, "Directory \(missing) not found."))
        }
    }
}
