import Foundation
import Testing
@testable import HephaestusCore

/// docs/skills.md › Internal skills: the defaults written when missing, the record that lets an
/// unedited copy follow a new default, Restore Default, the refusals, the plugin of every project
/// and the visibility for Claude's skill tools.
@Suite("Internal skills")
struct InternalSkillsTests {
    private func skillFile(_ name: String, in library: URL) -> URL {
        library.appendingPathComponent("\(name)/SKILL.md")
    }

    private func defaultContent(_ name: String) throws -> Data {
        try #require(InternalSkills.defaultContent(name))
    }

    private func record(in library: URL) -> [String: String] {
        InternalSkills.record(in: library)
    }

    // MARK: Defaults

    @Test("At start the library holds the four internal skills with their default content and the digests of what was written")
    func writtenAtStart() async throws {
        try await withTestEngine { engine, connection, _ in
            let library = engine.dataDirectory.skillsFolder
            for name in InternalSkills.names {
                #expect(try Data(contentsOf: skillFile(name, in: library)) == defaultContent(name))
            }
            #expect(record(in: library) == Dictionary(uniqueKeysWithValues: try InternalSkills.names.map { ($0, AtomicFile.sha256(try defaultContent($0))) }))
            // The record is hidden: the library skips it.
            #expect(try await connection.call(SkillsList.self).map(\.name) == InternalSkills.names)
            let skill = try await connection.call(SkillsGet.self, .init(name: "implement-ticket"))
            #expect(skill.body.contains("Arguments: $ARGUMENTS"))
            #expect(skill.files.isEmpty)
        }
    }

    @Test("A missing skill folder or SKILL.md is written again before a project's plugin is generated, and the plugin of a project with an empty skills list links the four")
    func missingWrittenAgain() async throws {
        try await withTestEngine { engine, connection, folder in
            let library = engine.dataDirectory.skillsFolder
            _ = try await connection.call(ProjectsCreate.self, .init(rootPath: folder.appendingPathComponent("Demo").path, name: "Demo",
                                                                     identifier: "DEMO", createDirectory: true))
            try FileManager.default.removeItem(at: library.appendingPathComponent("feedback"))
            try FileManager.default.removeItem(at: skillFile("implement-ticket", in: library))
            try writeFile("implement-ticket/notes.md", in: library, "kept")
            await engine.regenerateSkillsPlugin("DEMO")
            #expect(try Data(contentsOf: skillFile("feedback", in: library)) == defaultContent("feedback"))
            #expect(try Data(contentsOf: skillFile("implement-ticket", in: library)) == defaultContent("implement-ticket"))
            #expect(try String(contentsOf: library.appendingPathComponent("implement-ticket/notes.md"), encoding: .utf8) == "kept")
            let skills = engine.dataDirectory.pluginFolder(projectID: "DEMO").appendingPathComponent("hephaestus-skills/skills")
            #expect(try FileManager.default.contentsOfDirectory(atPath: skills.path).sorted() == InternalSkills.names)
            #expect(await engine.domain.project("DEMO")?.skills == [])
        }
    }

    @Test("An unedited copy takes the app's new default; an edited copy, or one without a recorded digest, is kept")
    func newDefaults() async throws {
        try await withTestEngine { engine, _, _ in
            let library = engine.dataDirectory.skillsFolder
            // An older default that the user never edited: its digest is the recorded one.
            let older = Data("---\nname: implement-ticket\ndescription: An older default.\n---\n\nOld steps.\n".utf8)
            try older.write(to: skillFile("implement-ticket", in: library))
            var recorded = record(in: library)
            recorded["implement-ticket"] = AtomicFile.sha256(older)
            // A copy the user edited after the default was written.
            let edited = Data("---\nname: feedback\ndescription: Edited by the user.\n---\n\nMy steps.\n".utf8)
            try edited.write(to: skillFile("feedback", in: library))
            // A copy without a recorded digest.
            let unrecorded = Data("---\nname: implement-bundle\ndescription: Mine.\n---\n".utf8)
            try unrecorded.write(to: skillFile("implement-bundle", in: library))
            recorded["implement-bundle"] = nil
            // A copy equal to the default whose digest is not recorded yet.
            recorded["finish-implementation"] = nil
            try await engine.writeInternalSkillsRecord(recorded, in: library)

            await engine.ensureInternalSkills()
            #expect(try Data(contentsOf: skillFile("implement-ticket", in: library)) == defaultContent("implement-ticket"))
            #expect(try Data(contentsOf: skillFile("feedback", in: library)) == edited)
            #expect(try Data(contentsOf: skillFile("implement-bundle", in: library)) == unrecorded)
            let after = record(in: library)
            #expect(after["implement-ticket"] == AtomicFile.sha256(try defaultContent("implement-ticket")))
            #expect(after["feedback"] == AtomicFile.sha256(try defaultContent("feedback")))
            #expect(after["implement-bundle"] == nil)
            #expect(after["finish-implementation"] == AtomicFile.sha256(try defaultContent("finish-implementation")))
        }
    }

    @Test("The action for a SKILL.md from its digest, the recorded digest and the default's")
    func actions() {
        #expect(InternalSkills.action(current: nil, recorded: nil, defaultDigest: "d") == .writeDefault)
        #expect(InternalSkills.action(current: nil, recorded: "d", defaultDigest: "d") == .writeDefault)
        #expect(InternalSkills.action(current: "d", recorded: "d", defaultDigest: "d") == .keep)
        #expect(InternalSkills.action(current: "d", recorded: nil, defaultDigest: "d") == .recordDigest)
        #expect(InternalSkills.action(current: "d", recorded: "old", defaultDigest: "d") == .recordDigest)
        #expect(InternalSkills.action(current: "old", recorded: "old", defaultDigest: "d") == .writeDefault)
        #expect(InternalSkills.action(current: "edited", recorded: "d", defaultDigest: "d") == .keep)
        #expect(InternalSkills.action(current: "edited", recorded: nil, defaultDigest: "d") == .keep)
    }

    @Test("Restore Default writes the default SKILL.md and records it, keeps the extra files, and refuses another skill")
    func restoreDefault() async throws {
        try await withTestEngine { engine, connection, _ in
            let library = engine.dataDirectory.skillsFolder
            _ = try await connection.call(SkillsUpdate.self, .init(name: "implement-ticket", description: "Changed.", body: "Added step.\n"))
            try writeFile("implement-ticket/templates/x.md", in: library, "x")
            await engine.ensureInternalSkills()
            #expect(try String(contentsOf: skillFile("implement-ticket", in: library), encoding: .utf8).contains("Added step."))

            let events = connection.events
            let skill = try await connection.call(SkillsRestoreDefault.self, .init(name: "implement-ticket"))
            #expect(try Data(contentsOf: skillFile("implement-ticket", in: library)) == defaultContent("implement-ticket"))
            #expect(skill.description.hasPrefix("Implements a ticket of HephaestusV2"))
            #expect(skill.files == ["templates/x.md"])
            #expect(record(in: library)["implement-ticket"] == AtomicFile.sha256(try defaultContent("implement-ticket")))
            #expect(await firstEvent(named: SkillsChangedEvent.name, on: events) != nil)

            // A missing folder is created.
            try FileManager.default.removeItem(at: library.appendingPathComponent("feedback"))
            _ = try await connection.call(SkillsRestoreDefault.self, .init(name: "feedback"))
            #expect(try Data(contentsOf: skillFile("feedback", in: library)) == defaultContent("feedback"))

            try writeSkill("release-notes", in: library, description: "Release notes.")
            #expect(await engineError { try await connection.call(SkillsRestoreDefault.self, .init(name: "release-notes")) }
                == EngineError(.invalid, "release-notes is not an internal skill of HephaestusV2."))
            #expect(await engineError { try await engine.call(SkillsRestoreDefault.self, .init(name: "feedback"), actor: .claude(chatID: "external")) }?
                .code == .forbidden)
        }
    }

    // MARK: Protection and visibility

    @Test("A rename, a delete and disabling are refused; enabling changes nothing; creating the name conflicts; other projects' chats do not find them")
    func refusalsAndVisibility() async throws {
        let hephaestusChat = UUID()
        let otherChat = UUID()
        try await withDomainEngine(hephaestusProject: HephaestusProjectTests.unreachable, prepare: { directory, projects in
            let clone = projects.appendingPathComponent("HephaestusV2")
            try HephaestusProjectTests.writeOrigin("https://github.com/Azavech/HephaestusV2.git", in: clone)
            try writeFile(projectYAML(id: "HEPH", name: "HephaestusV2"), to: clone.appendingPathComponent(".hephaestus/project.yml"))
            let other = projects.appendingPathComponent("Other")
            try writeFile(projectYAML(id: "OTHER", name: "Other"), to: other.appendingPathComponent(".hephaestus/project.yml"))
            try writeFile(registryYAML([clone.path, other.path]), to: directory.registryFile)
            try ProjectFileStore.write(ChatMeta(id: hephaestusChat, kind: .project, created: ISODate.now()), to: ProjectFolder(root: clone))
            try ProjectFileStore.write(ChatMeta(id: otherChat, kind: .project, created: ISODate.now()), to: ProjectFolder(root: other))
        }) { (h: DomainHarness) async throws in
            #expect(await h.engine.hephaestusProjectID == "HEPH")
            let inHephaestus = Actor.claude(chatID: hephaestusChat.uuidString)
            let elsewhere = Actor.claude(chatID: otherChat.uuidString)
            try writeSkill("release-notes", in: h.engine.dataDirectory.skillsFolder, description: "Release notes.")

            // list_skills, get_skill and update_skill see them only from a chat of the HephaestusV2 project.
            #expect(try await h.call(SkillsList.self, Empty(), as: inHephaestus).map(\.name) == InternalSkills.names + ["release-notes"])
            #expect(try await h.call(SkillsList.self, Empty(), as: elsewhere).map(\.name) == ["release-notes"])
            #expect(try await h.call(SkillsList.self, Empty(), as: h.claude).map(\.name) == ["release-notes"])
            #expect(try await h.connection.call(SkillsList.self).map(\.name) == InternalSkills.names + ["release-notes"])
            let notFound = EngineError(.notFound, "Skill feedback not found.")
            #expect(await engineError { try await h.call(SkillsGet.self, .init(name: "feedback"), as: elsewhere) } == notFound)
            #expect(await engineError { try await h.call(SkillsUpdate.self, .init(name: "feedback", body: "x"), as: elsewhere) } == notFound)
            #expect(await engineError { try await h.call(SkillsDelete.self, .init(name: "feedback"), as: elsewhere) } == notFound)
            #expect(await engineError { try await h.call(SkillsGet.self, .init(name: "feedback"), as: h.claude) } == notFound)
            #expect(try await h.call(SkillsGet.self, .init(name: "feedback"), as: inHephaestus).name == "feedback")
            #expect(try await h.call(SkillsUpdate.self, .init(name: "feedback", body: "My steps.\n"), as: inHephaestus).body == "My steps.\n")

            // The refusals, for Claude and for the user.
            for actor in [inHephaestus, Actor.user(deviceID: "test")] {
                #expect(await engineError { try await h.call(SkillsUpdate.self, .init(name: "feedback", newName: "notes"), as: actor) }
                    == EngineError(.forbidden, "feedback is an internal skill of HephaestusV2: it cannot be renamed."))
                #expect(await engineError { try await h.call(SkillsDelete.self, .init(name: "implement-ticket"), as: actor) }
                    == EngineError(.forbidden, "implement-ticket is an internal skill of HephaestusV2: it cannot be moved to the Trash."))
                #expect(await engineError {
                    try await h.call(SkillsSetEnabled.self, .init(projectID: "OTHER", name: "implement-bundle", enabled: false), as: actor)
                } == EngineError(.forbidden, "implement-bundle is an internal skill of HephaestusV2: it is always enabled."))
                let enabled = try await h.call(SkillsSetEnabled.self, .init(projectID: "OTHER", name: "implement-bundle", enabled: true), as: actor)
                #expect(enabled.project.skills == [])
                #expect(await engineError { try await h.call(SkillsCreate.self, .init(name: "finish-implementation", description: "Mine."), as: actor) }
                    == EngineError(.conflict, "A skill named finish-implementation already exists."))
            }
            #expect(FileManager.default.fileExists(atPath: h.engine.dataDirectory.skillsFolder.appendingPathComponent("implement-ticket/SKILL.md").path))
            // A rename to the same name is no rename.
            #expect(try await h.call(SkillsUpdate.self, .init(name: "feedback", newName: "feedback"), as: inHephaestus).name == "feedback")
            // Without its folder, the name of an internal skill still conflicts.
            try FileManager.default.removeItem(at: h.engine.dataDirectory.skillsFolder.appendingPathComponent("finish-implementation"))
            #expect(await engineError { try await h.connection.call(SkillsCreate.self, .init(name: "finish-implementation", description: "Mine.")) }?
                .code == .conflict)
        }
    }

    @Test("Without a HephaestusV2 project, no chat's skill tools find them")
    func noHephaestusProject() async throws {
        try await withTestEngine { (engine: Engine, connection: LocalEngineConnection, _: URL) async throws in
            #expect(await engine.hephaestusProjectID == nil)
            #expect(try await engine.call(SkillsList.self, Empty(), actor: .claude(chatID: UUID().uuidString)).map(\.name) == [])
            #expect(try await connection.call(SkillsList.self).map(\.name) == InternalSkills.names)
        }
    }
}
