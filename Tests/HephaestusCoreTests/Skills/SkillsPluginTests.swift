import Foundation
import Testing
@testable import HephaestusCore

/// docs/skills.md › Generated plugin: layout, plugin.json and the generation steps.
@Suite("Skills plugin generation")
struct SkillsPluginTests {
    /// A data directory and a library with the skills `release-notes` and `swift-testing`, a
    /// folder without SKILL.md and an invalid name.
    private func withLibrary(_ body: (DataDirectory, URL) throws -> Void) throws {
        try withTemporaryDirectory { folder in
            let data = DataDirectory(url: folder.appendingPathComponent("Data", isDirectory: true))
            let library = folder.appendingPathComponent("Library", isDirectory: true)
            try writeSkill("release-notes", in: library, description: "Release notes.")
            try writeSkill("swift-testing", in: library, description: "Swift Testing.")
            try FileManager.default.createDirectory(at: library.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try writeSkill("Bad_Name", in: library, description: "Invalid.")
            try body(data, library)
        }
    }

    private func entries(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    @Test("The layout links each enabled skill of the library with an absolute target")
    func layout() throws {
        try withLibrary { data, library in
            let generator = SkillsPluginGenerator()
            let folder = try generator.preparePlugin(projectID: "HEPH", skills: ["swift-testing", "missing", "empty", "release-notes"],
                                                     library: library, dataDirectory: data)
            #expect(folder == data.pluginFolder(projectID: "HEPH"))
            #expect(try entries(folder) == ["hephaestus-skills"])
            let plugin = folder.appendingPathComponent("hephaestus-skills")
            #expect(try entries(plugin) == [".claude-plugin", "skills"])
            let manifest = try String(contentsOf: plugin.appendingPathComponent(".claude-plugin/plugin.json"), encoding: .utf8)
            #expect(manifest == """
            {
              "name": "hephaestus-skills",
              "version": "1.0.0",
              "description": "Skills enabled for project HEPH in HephaestusV2."
            }

            """)
            let decoded = try JSONDecoder().decode([String: String].self, from: Data(manifest.utf8))
            #expect(decoded == ["name": "hephaestus-skills", "version": "1.0.0", "description": "Skills enabled for project HEPH in HephaestusV2."])
            let skills = plugin.appendingPathComponent("skills")
            #expect(try entries(skills) == ["release-notes", "swift-testing"])
            for name in ["release-notes", "swift-testing"] {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: skills.appendingPathComponent(name).path)
                #expect(target == library.standardizedFileURL.path + "/" + name)
                #expect(FileManager.default.fileExists(atPath: skills.appendingPathComponent("\(name)/SKILL.md").path))
            }
        }
    }

    @Test("Regenerating removes stale entries, repairs wrong links and keeps correct ones")
    func regenerate() throws {
        try withLibrary { data, library in
            let generator = SkillsPluginGenerator()
            let folder = try generator.preparePlugin(projectID: "HEPH", skills: ["release-notes", "swift-testing"], library: library,
                                                     dataDirectory: data)
            let skills = folder.appendingPathComponent("hephaestus-skills/skills")
            let manager = FileManager.default
            try manager.removeItem(at: skills.appendingPathComponent("swift-testing"))
            try manager.createSymbolicLink(atPath: skills.appendingPathComponent("swift-testing").path, withDestinationPath: "/elsewhere")
            try manager.createDirectory(at: skills.appendingPathComponent("stray"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: skills.appendingPathComponent("file.txt"))
            let manifest = folder.appendingPathComponent("hephaestus-skills/.claude-plugin/plugin.json")
            try Data("{}".utf8).write(to: manifest)

            _ = try generator.preparePlugin(projectID: "HEPH", skills: ["swift-testing"], library: library, dataDirectory: data)
            #expect(try entries(skills) == ["swift-testing"])
            #expect(try manager.destinationOfSymbolicLink(atPath: skills.appendingPathComponent("swift-testing").path)
                == library.standardizedFileURL.path + "/swift-testing")
            #expect(try Data(contentsOf: manifest) == SkillsPluginGenerator.manifest(projectID: "HEPH"))
        }
    }

    @Test("Without an enabled skill of the library the folder is deleted, and missing Runtime folders are recreated")
    func emptySet() throws {
        try withLibrary { data, library in
            let generator = SkillsPluginGenerator()
            let folder = try generator.preparePlugin(projectID: "HEPH", skills: ["release-notes"], library: library, dataDirectory: data)
            #expect(FileManager.default.fileExists(atPath: folder.path))
            let empty = try generator.preparePlugin(projectID: "HEPH", skills: ["missing", "empty"], library: library, dataDirectory: data)
            #expect(empty == folder)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect(try generator.preparePlugin(projectID: "OTHER", skills: [], library: library, dataDirectory: data)
                == data.pluginFolder(projectID: "OTHER"))

            try FileManager.default.removeItem(at: data.runtimeFolder)
            _ = try generator.preparePlugin(projectID: "HEPH", skills: ["release-notes"], library: library, dataDirectory: data)
            #expect(try entries(folder.appendingPathComponent("hephaestus-skills/skills")) == ["release-notes"])
        }
    }

    @Test("A skill whose folder is a symbolic link to a folder is linked like any other")
    func linkedSkill() throws {
        try withLibrary { data, library in
            try withTemporaryDirectory { elsewhere in
                let target = try writeSkill("shared", in: elsewhere, description: "Shared.")
                try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("shared"), withDestinationURL: target)
                let folder = try SkillsPluginGenerator().preparePlugin(projectID: "HEPH", skills: ["shared"], library: library,
                                                                       dataDirectory: data)
                #expect(try entries(folder.appendingPathComponent("hephaestus-skills/skills")) == ["shared"])
            }
        }
    }

    @Test("A file system error is thrown")
    func failure() throws {
        try withLibrary { data, library in
            try FileManager.default.createDirectory(at: data.pluginsFolder, withIntermediateDirectories: true)
            try Data("not a folder".utf8).write(to: data.pluginFolder(projectID: "HEPH"))
            #expect(throws: (any Error).self) {
                try SkillsPluginGenerator().preparePlugin(projectID: "HEPH", skills: ["release-notes"], library: library, dataDirectory: data)
            }
        }
    }
}
