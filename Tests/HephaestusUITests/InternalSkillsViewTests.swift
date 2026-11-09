import AppKit
import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/skills.md › Internal Skills view and docs/ui.md › WindowState, › Resolving a target: the
/// window state of the view, the lists of the Skills section and of the view, the persisted state,
/// the menu item's condition and the navigation of a `skill` target of an internal skill.
@MainActor
@Suite("Internal Skills view")
struct InternalSkillsViewTests {
    @Test("Showing the view leaves the section unselected; a section, the Global Memories view or a sub project's row leaves it")
    func showAndLeave() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .tickets
        window.showsInternalSkills = true
        #expect(window.shownSection == nil)
        #expect(window.section == .tickets)
        window.section = .tickets
        #expect(!window.showsInternalSkills && window.shownSection == .tickets)

        // The two views replace each other.
        window.showsGlobalMemories = true
        window.showsInternalSkills = true
        #expect(window.showsInternalSkills && !window.showsGlobalMemories)
        window.showsGlobalMemories = true
        #expect(window.showsGlobalMemories && !window.showsInternalSkills)

        // The view leaves a sub project's Dashboard, and a sub project's row leaves the view.
        window.showSubProject("MUS")
        window.showsInternalSkills = true
        #expect(window.subProjectDashboardID == nil && window.shownSection == nil)
        window.showSubProject("MUS")
        #expect(!window.showsInternalSkills && window.subProjectDashboardID == "MUS")

        // Switching project or device keeps the view.
        window.showsInternalSkills = true
        window.projectID = "WEB"
        window.deviceID = "other"
        #expect(window.showsInternalSkills && window.shownSection == nil)
    }

    @Test("The Skills section of every project, HEPH included, leaves the internal skills out; the view lists only them")
    func lists() {
        let skills = (InternalSkills.names + ["release-notes", "swift-testing"]).map { SkillSummary(name: $0, description: $0) }
        for projectID in [HephaestusRepository.identifier, "DEMO"] {
            #expect(SkillsVisibility.listed(skills, in: .project(projectID)).map(\.name) == ["release-notes", "swift-testing"])
            #expect(!SkillsVisibility.isListed("bundle", in: .project(projectID)))
        }
        #expect(SkillsVisibility.listed(skills, in: .internalSkills).map(\.name) == InternalSkills.names)
        #expect(InternalSkills.names.count == 14)
        #expect(!SkillsVisibility.isListed("release-notes", in: .internalSkills))
    }

    @Test("The view's state is kept per device; the persisted state holds the view and the selected skill of the window's device")
    func coding() throws {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .skills
        window.showsInternalSkills = true
        let editor = SkillEditorState(skillName: "ci", scope: .internalSkills, bodyMode: .edit)
        window.updateSkillViewState(.internalSkills, deviceID: "device") {
            $0.selectedSkillName = "ci"
            $0.skillEditor = editor
        }
        window.updateSkillViewState(.internalSkills, deviceID: "other") { $0.selectedSkillName = "common" }
        window.updateSkillViewState(.project("DEMO"), deviceID: "device") { $0.selectedSkillName = "release-notes" }
        #expect(window.skillViewState(.internalSkills, deviceID: "device").skillEditor === editor)
        #expect(window.skillViewState(.internalSkills, deviceID: "other").selectedSkillName == "common")
        #expect(window.projectStates[ProjectKey(deviceID: "device", projectID: "DEMO")]?.selectedSkillName == "release-notes")
        #expect(window.skillViewState(.project("DEMO"), deviceID: "device").selectedSkillName == "release-notes")

        let persisted = try #require(window.persistedJSON)
        let restored = try #require(WindowState.restored(fromJSON: persisted))
        #expect(restored.showsInternalSkills && !restored.showsGlobalMemories)
        #expect(restored.section == .skills && restored.shownSection == nil)
        #expect(restored.internalSkillStates.keys.sorted() == ["device"])
        #expect(restored.skillViewState(.internalSkills, deviceID: "device").selectedSkillName == "ci")
        // The editor, with its body mode, is never encoded.
        #expect(restored.skillViewState(.internalSkills, deviceID: "device").skillEditor == nil)

        // debug_ui_state encodes every device's entry.
        let data = try EngineJSON.encoder().encode(window)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""internalSkillStates":{"device":{"selectedSkillName":"ci"},"other":{"selectedSkillName":"common"}}"#))
        #expect(json.contains(#""showsInternalSkills":true"#))

        // A state persisted before the view shows the window's section.
        let older = try #require(WindowState.restored(fromJSON: persisted
            .replacingOccurrences(of: #""showsInternalSkills":true,"#, with: "")
            .replacingOccurrences(of: #","internalSkillStates":{"device":{"selectedSkillName":"ci"}}"#, with: "")))
        #expect(!older.showsInternalSkills && older.internalSkillStates.isEmpty && older.shownSection == .skills)
    }

    @Test("Closing the window counts the view's unsaved skill; removing a project does not")
    func unsavedEditors() {
        let window = WindowState(id: UUID(), deviceID: "device")
        let editor = SkillEditorState(skillName: "ci", scope: .internalSkills)
        editor.form.reset(to: Skill(name: "ci", description: "Saved.", body: ""))
        editor.form.description = "Edited."
        window.updateSkillViewState(.internalSkills, deviceID: "device") { $0.skillEditor = editor }
        #expect(window.unsavedEditors().count == 1)
        #expect(window.unsavedEditors().first?.savePromptTitle == "Do you want to save the changes to “ci”?")
        #expect(window.unsavedEditors(deviceID: "device").count == 1)
        #expect(window.unsavedEditors(deviceID: "other").isEmpty)
        #expect(window.unsavedEditors(deviceID: "device", projectIDs: ["DEMO"]).isEmpty)
    }

    @Test("View ▸ Internal Skills is enabled in a main window whose device is connected, with or without project")
    func menuItem() async throws {
        #expect(!WindowState(id: UUID(), deviceID: "device").canShowInternalSkills)
        try await withEngineApp { app, _ in
            let workspace = app.localWorkspace
            #expect(await eventually { workspace.isConnected && workspace.hasSnapshot })
            let window = WindowState(deviceID: app.localDeviceID)
            app.registerMainWindow(window)
            #expect(window.projectID == nil)
            #expect(window.canShowInternalSkills)
        }
    }

    @Test("A skill target of an internal skill shows the view without changing the project or the section; other skills keep the Skills section")
    func navigation() async throws {
        try await withEngineApp { app, root in
            let workspace = app.localWorkspace
            #expect(await eventually { workspace.hasSnapshot })
            let window = WindowState(deviceID: app.localDeviceID)
            app.registerMainWindow(window)

            // Without any project: the view takes the welcome view's place.
            #expect(workspace.projects.isEmpty)
            await window.navigate(to: .skill(name: "common"))
            #expect(window.showsInternalSkills && window.projectID == nil)
            #expect(window.skillViewState(.internalSkills, deviceID: app.localDeviceID).selectedSkillName == "common")

            // With a project but without a HephaestusV2 project.
            _ = try await workspace.call(ProjectsCreate.self, ProjectsCreate.Params(
                rootPath: root.appendingPathComponent("demo").path, name: "Demo", identifier: "DEMO", createDirectory: true))
            #expect(await eventually { workspace.project("DEMO") != nil })
            window.activate(projectID: "DEMO")
            window.section = .tickets
            window.showSubProject("MUS")
            await window.navigate(to: .skill(name: "bundle"))
            #expect(window.showsInternalSkills && window.subProjectDashboardID == nil)
            #expect(window.projectID == "DEMO" && window.section == .tickets && window.shownSection == nil)
            #expect(window.skillViewState(.internalSkills, deviceID: app.localDeviceID).selectedSkillName == "bundle")
            #expect(window.skillViewState(.project("DEMO"), deviceID: app.localDeviceID).selectedSkillName == nil)

            // With a loaded HephaestusV2 project: the view still shows, and the project stays.
            let clone = root.appendingPathComponent("HephaestusV2")
            try FileManager.default.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try "[remote \"origin\"]\n\turl = https://github.com/Azavech/HephaestusV2.git\n"
                .write(to: clone.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
            _ = try await workspace.call(ProjectsCreate.self, ProjectsCreate.Params(
                rootPath: clone.path, name: "HephaestusV2", identifier: HephaestusRepository.identifier, createDirectory: false))
            #expect(await eventually { workspace.project(HephaestusRepository.identifier) != nil })
            window.section = .chats
            await window.navigate(to: .skill(name: "ci"))
            #expect(window.showsInternalSkills && window.projectID == "DEMO" && window.section == .chats)
            #expect(window.skillViewState(.internalSkills, deviceID: app.localDeviceID).selectedSkillName == "ci")
            #expect(window.skillViewState(.project(HephaestusRepository.identifier), deviceID: app.localDeviceID).selectedSkillName == nil)

            // Another skill selects the Skills section of the active project, which leaves the view.
            await window.navigate(to: .skill(name: "release-notes"))
            #expect(!window.showsInternalSkills && window.shownSection == .skills && window.projectID == "DEMO")
            #expect(window.viewState.selectedSkillName == "release-notes")
        }
    }
}

/// Waits until a condition holds, at most `seconds`.
@MainActor
private func eventually(seconds: Int = 5, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<(seconds * 100) {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// An app on an engine with its own temporary data directory, and a folder for its projects.
@MainActor
private func withEngineApp(_ check: (AppModel, URL) async throws -> Void) async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = folder.appendingPathComponent("Data", isDirectory: true)
    let projects = folder.appendingPathComponent("Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: SilentClaudeLauncher()))
    let connection = await LocalEngineConnection(engine: engine)
    let app = AppModel(environment: LaunchEnvironment(dataDirectory: data), engine: engine,
                       appVersion: AppVersion(version: "0.0.0", build: 0), connection: connection, restartWindows: nil)
    do {
        try await check(app, projects)
    } catch {
        connection.close()
        await engine.shutdown()
        throw error
    }
    connection.close()
    await engine.shutdown()
}

/// A launcher that starts nothing: no Claude process runs.
private struct SilentClaudeLauncher: ClaudeProcessLauncher {}
