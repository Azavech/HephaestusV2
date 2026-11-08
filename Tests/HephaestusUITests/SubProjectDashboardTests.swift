import AppKit
import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/ui.md › Sidebar and › WindowState, docs/dashboard.md › Section: the Dashboard of a sub
/// project shown from the sidebar without switching the active project, what leaves it, its
/// coding and its restoration.
@MainActor
@Suite("Sub project Dashboard")
struct SubProjectDashboardTests {
    /// DEMO with the sub projects MUS, whose sub project is API, and SHR; WEB is another top-level
    /// project.
    private func workspace() -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.projects = [
            ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo", subprojectIDs: ["MUS", "SHR"]),
            ProjectSummary(id: "MUS", name: "yc-music", rootPath: "/Users/example/Demo/music", parentID: "DEMO", subprojectIDs: ["API"]),
            ProjectSummary(id: "API", name: "Api", rootPath: "/Users/example/Demo/music/api", parentID: "MUS"),
            ProjectSummary(id: "SHR", name: "Shared", rootPath: "/Users/example/Demo/shared", parentID: "DEMO"),
            ProjectSummary(id: "WEB", name: "Website", rootPath: "/Users/example/Web"),
        ]
        workspace.hasSnapshot = true
        return workspace
    }

    /// A window on DEMO, its section Tickets, showing MUS's Dashboard.
    private func window() -> WindowState {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.activate(projectID: "DEMO")
        window.section = .tickets
        window.showSubProject("MUS")
        return window
    }

    @Test("The window keeps its project and section; no section is shown while the sub project's Dashboard shows")
    func show() {
        let window = window()
        #expect(window.projectID == "DEMO" && window.section == .tickets)
        #expect(window.subProjectDashboardID == "MUS")
        #expect(window.shownSection == nil)
        window.showSubProject("SHR")
        #expect(window.subProjectDashboardID == "SHR" && window.projectID == "DEMO" && window.section == .tickets)
    }

    @Test("Selecting a section, the kept one included, leaves the Dashboard", arguments: [ProjectSection.tickets, .dashboard, .costs])
    func leftBySection(_ section: ProjectSection) {
        let window = window()
        window.section = section
        #expect(window.subProjectDashboardID == nil)
        #expect(window.shownSection == section && window.projectID == "DEMO")
    }

    @Test("The Global Memories view leaves the Dashboard; a sub project row leaves the view")
    func globalMemories() {
        let window = window()
        window.showsGlobalMemories = true
        #expect(window.subProjectDashboardID == nil && window.section == .tickets)
        window.showSubProject("MUS")
        #expect(!window.showsGlobalMemories && window.subProjectDashboardID == "MUS")
        window.showsGlobalMemories = false
        #expect(window.subProjectDashboardID == "MUS")
    }

    @Test("A switch of project or device leaves the Dashboard and shows the kept section for the new project")
    func leftBySwitch() {
        let window = window()
        window.activate(projectID: "DEMO")
        #expect(window.subProjectDashboardID == "MUS")
        window.activate(projectID: "WEB")
        #expect(window.subProjectDashboardID == nil && window.shownSection == .tickets)

        // Choosing the shown sub project in the breadcrumb activates it on the kept section.
        window.activate(projectID: "DEMO")
        window.showSubProject("MUS")
        window.activate(projectID: "MUS")
        #expect(window.subProjectDashboardID == nil && window.shownSection == .tickets)

        window.activate(projectID: "DEMO")
        window.showSubProject("MUS")
        window.deviceID = "other"
        #expect(window.subProjectDashboardID == nil)
    }

    @Test("A sub project that is removed, hidden or no longer a loaded descendant is left")
    func leftWhenGone() {
        let workspace = workspace()
        let window = window()
        window.reconcileProject(with: workspace)
        #expect(window.subProjectDashboardID == "MUS" && window.projectID == "DEMO")

        // API, a descendant at depth 2, stays shown.
        window.showSubProject("API")
        window.reconcileProject(with: workspace)
        #expect(window.subProjectDashboardID == "API")

        // MUS and API removed.
        var demo = workspace.projects[0]
        demo.subprojectIDs = ["SHR"]
        _ = workspace.replaceProjects([demo, workspace.projects[3], workspace.projects[4]])
        window.reconcileProject(with: workspace)
        #expect(window.subProjectDashboardID == nil)
        #expect(window.projectID == "DEMO" && window.shownSection == .tickets)
    }

    @Test("The persisted state holds the shown sub project; debug_ui_state encodes it")
    func coding() throws {
        let window = window()
        let persisted = try #require(window.persistedJSON)
        #expect(persisted.contains(#""subProjectDashboardID":"MUS""#))
        let restored = try #require(WindowState.restored(fromJSON: persisted))
        #expect(restored.projectID == "DEMO" && restored.section == .tickets)
        #expect(restored.subProjectDashboardID == "MUS")
        #expect(restored.shownSection == nil)

        let json = try #require(String(data: try EngineJSON.encoder().encode(window), encoding: .utf8))
        #expect(json.contains(#""subProjectDashboardID":"MUS""#))

        // Without a shown sub project, the key is absent.
        window.section = .tickets
        #expect(window.persistedJSON?.contains("subProjectDashboardID") == false)
        let plainJSON = try #require(window.persistedJSON)
        let plain = try #require(WindowState.restored(fromJSON: plainJSON))
        #expect(plain.subProjectDashboardID == nil)
    }

    @Test("A restored window shows the sub project's Dashboard only while it is a loaded descendant of the active project")
    func restore() throws {
        let workspace = workspace()
        let persisted = try #require(window().persistedJSON)

        let kept = try #require(WindowState.restored(fromJSON: persisted))
        kept.reconcileProject(with: workspace)
        #expect(kept.subProjectDashboardID == "MUS" && kept.projectID == "DEMO")

        // Another active project: MUS is not its descendant.
        let other = try #require(WindowState.restored(fromJSON: persisted.replacingOccurrences(of: #""projectID":"DEMO""#,
                                                                                                 with: #""projectID":"WEB""#)))
        #expect(other.subProjectDashboardID == "MUS")
        other.reconcileProject(with: workspace)
        #expect(other.projectID == "WEB" && other.subProjectDashboardID == nil && other.shownSection == .tickets)

        // The sub project is no longer loaded.
        let gone = try #require(WindowState.restored(fromJSON: persisted))
        var demo = workspace.projects[0]
        demo.subprojectIDs = ["SHR"]
        _ = workspace.replaceProjects([demo, workspace.projects[3], workspace.projects[4]])
        gone.reconcileProject(with: workspace)
        #expect(gone.projectID == "DEMO" && gone.subProjectDashboardID == nil)
    }

    @Test("Every navigation leaves the Dashboard, a project target to the active project included")
    func leftByNavigation() async throws {
        try await withEngineApp { app, root in
            let workspace = app.localWorkspace
            #expect(await eventually { workspace.hasSnapshot })
            for (identifier, path, parent) in [("DEMO", "demo", nil), ("MUS", "demo/music", "DEMO"), ("WEB", "web", nil)] as [(String, String, String?)] {
                _ = try await workspace.call(ProjectsCreate.self, ProjectsCreate.Params(
                    rootPath: root.appendingPathComponent(path).path, name: identifier, identifier: identifier, parentID: parent,
                    createDirectory: true))
            }
            #expect(await eventually { workspace.project("MUS")?.parentID == "DEMO" && workspace.project("WEB") != nil })

            let window = WindowState(deviceID: app.localDeviceID)
            app.registerMainWindow(window)
            window.activate(projectID: "DEMO")
            window.section = .tickets
            window.showSubProject("MUS")
            await window.navigate(to: .project(projectID: "DEMO"))
            #expect(window.subProjectDashboardID == nil && window.projectID == "DEMO" && window.section == .tickets)

            window.showSubProject("MUS")
            await window.navigate(to: .section(projectID: "WEB", section: .chats))
            #expect(window.subProjectDashboardID == nil && window.projectID == "WEB" && window.section == .chats)
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
