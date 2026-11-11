import AppKit
import Foundation
import HephaestusCore
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/views.md › New View sheet and › New view's file.
@MainActor
@Suite("New View sheet")
struct NewViewTests {
    @Test("The file of a view holds a SwiftUI view of its name and a #Preview of it")
    func fileText() {
        #expect(NewViewFile.text(name: "ProfileView") == """
        import SwiftUI

        struct ProfileView: View {
            var body: some View {
                Text("Hello, World!")
            }
        }

        #Preview {
            ProfileView()
        }

        """)
        #expect(NewViewFile.path(name: "ProfileView", folder: "Sources/App") == "Sources/App/ProfileView.swift")
        #expect(NewViewFile.path(name: "ProfileView", folder: "") == "ProfileView.swift")
    }

    @Test("A name is trimmed, loses its .swift and must be a Swift type name",
          arguments: [
              ("ProfileView", "ProfileView"),
              ("  ProfileView \n", "ProfileView"),
              ("ProfileView.swift", "ProfileView"),
              ("ProfileView.SWIFT", "ProfileView"),
              ("_Row2", "_Row2"),
              ("row", "row"),
              ("", nil),
              (".swift", nil),
              ("_", nil),
              ("2View", nil),
              ("Profile View", nil),
              ("Profile-View", nil),
              ("Sources/ProfileView", nil),
              ("Vue\u{E9}", nil),
          ] as [(String, String?)])
    func names(_ text: String, expected: String?) {
        #expect(NewViewFile.typeName(text) == expected)
    }

    @Test("A folder is trimmed and loses its / at both ends; / or nothing is the root",
          arguments: [
              ("Sources/App", "Sources/App"),
              (" /Sources/App/ ", "Sources/App"),
              ("/", ""),
              ("", ""),
              ("App", "App"),
              ("Sources//App", nil),
              ("Sources/./App", nil),
              ("../App", nil),
          ] as [(String, String?)])
    func folders(_ text: String, expected: String?) {
        #expect(NewViewFile.folder(text) == expected)
        #expect(NewViewFile.folderText("") == "/")
        #expect(NewViewFile.folderText("Sources/App") == "Sources/App")
    }

    @Test("Create writes the file in the chosen folder, creating its folders, and the list selects the new view")
    func createInFolder() async throws {
        try await withEngineApp { app, root in
            let workspace = app.localWorkspace
            #expect(await eventually { workspace.hasSnapshot })
            let projectRoot = root.appendingPathComponent("app", isDirectory: true)
            _ = try await workspace.call(ProjectsCreate.self, ProjectsCreate.Params(
                rootPath: projectRoot.path, name: "App", identifier: "APP", type: .swiftApplication, createDirectory: true))
            let kit = projectRoot.appendingPathComponent("Sources/Kit", isDirectory: true)
            try FileManager.default.createDirectory(at: kit, withIntermediateDirectories: true)
            try "import SwiftUI\n\nstruct Canvas: View {\n    var body: some View { EmptyView() }\n}\n"
                .write(to: kit.appendingPathComponent("Canvas.swift"), atomically: true, encoding: .utf8)
            #expect(await eventually { workspace.project("APP") != nil })

            let window = WindowState(deviceID: app.localDeviceID)
            app.registerMainWindow(window)
            window.projectID = "APP"
            let state = window.ensureViewsState(of: "APP")
            state.appear(workspace: workspace, projectID: "APP", window: nil)
            defer { state.disappear() }
            #expect(await eventually { state.views?.count == 1 })
            // Without a view selected, the folder of the first view of the list.
            #expect(state.newViewFolder == "Sources/Kit")
            #expect(state.folders == ["Sources", "Sources/Kit"])

            // Sources/App does not exist yet: it is created.
            let path = try await NewViewFile.create(name: "ProfileView", folder: "Sources/App", projectID: "APP", workspace: workspace)
            #expect(path == "Sources/App/ProfileView.swift")
            let file = projectRoot.appendingPathComponent("Sources/App/ProfileView.swift")
            #expect(try String(contentsOf: file, encoding: .utf8) == NewViewFile.text(name: "ProfileView"))

            state.collapsed = ["Sources", "Sources/App", "Sources/Kit"]
            state.reveal(path: path, name: "ProfileView")
            #expect(state.collapsed == ["Sources/Kit"])
            #expect(await eventually(seconds: 10) { state.selection == ViewSelection(path: path, name: "ProfileView") })
            let view = try #require(state.selectedView)
            #expect(view.kind == .swiftUI)
            #expect(view.previews.count == 1)
            #expect(state.scrollTarget == ViewSelection(path: path, name: "ProfileView").id)
            #expect(state.session != nil)
            #expect(state.newViewFolder == "Sources/App")
            #expect(state.folders == ["Sources", "Sources/App", "Sources/Kit"])

            // A second view of the same name in the same folder is refused with conflict.
            await #expect {
                _ = try await NewViewFile.create(name: "ProfileView", folder: "Sources/App", projectID: "APP", workspace: workspace)
            } throws: { error in
                (error as? EngineError)?.code == .conflict
            }

            // In the root.
            let rootPath = try await NewViewFile.create(name: "RootView", folder: "", projectID: "APP", workspace: workspace)
            #expect(rootPath == "RootView.swift")
            #expect(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("RootView.swift").path))
        }
    }

    @Test("The New View sheet acts on its project")
    func sheetCase() {
        let sheet = WindowSheet.newView(projectID: "APP", folder: "Sources/App")
        #expect(sheet.projectID == "APP")
    }
}

/// Waits until a condition holds, at most `seconds`.
@MainActor
private func eventually(seconds: Int = 2, _ condition: () -> Bool) async -> Bool {
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
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: NoClaudeLauncher()))
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
private struct NoClaudeLauncher: ClaudeProcessLauncher {}
