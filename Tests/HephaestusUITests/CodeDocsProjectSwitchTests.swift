import AppKit
import Foundation
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// The modification date of the files of the tests.
private let modified = Date(timeIntervalSince1970: 1_800_000_000)

/// docs/ui.md › Sidebar, docs/code-editor.md › File tree (Loading) and docs/documentation-viewer.md
/// › Docs tree, › Opening a doc: switching project while the Code or Docs section is shown shows the
/// section of the new project as when it appears. The sections are hosted without a window and stay
/// in place across the switch, as in the centre column of a main window: the new project's file
/// tree lists its root, its docs tree loads its docs, its tabs and its selected doc are read and its
/// commands become the window's; switching back shows the first project's, still loaded.
@MainActor
@Suite("Project switch in the Code and Docs sections")
struct CodeDocsProjectSwitchTests {
    /// A connection that answers `files.list`, `files.read` and `docs.list` with the folders, files
    /// and docs of each project and records those calls; every other call fails.
    final class ProjectFilesConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        /// The entries of the folders of each project, by folder path (`""` for the root).
        let folders: [String: [String: [FileEntry]]]
        /// The text of the files of each project, by path.
        let files: [String: [String: String]]
        /// The docs of each project.
        let docs: [String: [DocEntry]]

        init(folders: [String: [String: [FileEntry]]], files: [String: [String: String]], docs: [String: [DocEntry]]) {
            self.folders = folders
            self.files = files
            self.docs = docs
        }

        /// The calls, in no fixed order since listings run concurrently: `files.list <project id>
        /// /<path>`, `files.read <project id> <path>` and `docs.list <project id>`.
        var calls: [String] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? FilesList.Params {
                record("files.list \(params.projectID) /\(params.path)")
                if let entries = folders[params.projectID]?[params.path], let result = entries as? M.Result {
                    return result
                }
                throw EngineError(.notFound, "\(params.path) was not found.")
            }
            if let params = params as? FilesRead.Params {
                record("files.read \(params.projectID) \(params.path)")
                if let text = files[params.projectID]?[params.path],
                   let result = FileContent(path: params.path, text: text, modified: modified, size: text.utf8.count) as? M.Result {
                    return result
                }
                throw EngineError(.notFound, "\(params.path) was not found.")
            }
            if let params = params as? DocsList.Params {
                record("docs.list \(params.projectID)")
                if let result = docs[params.projectID, default: []] as? M.Result {
                    return result
                }
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}

        private func record(_ call: String) {
            lock.withLock { recorded.append(call) }
        }
    }

    /// The window's section for its active project, as the centre column of a main window shows it
    /// (`SectionContent`): the section view stays in place when the window switches project.
    struct SectionHost: View {
        let window: WindowState
        let workspace: DeviceWorkspace

        var body: some View {
            if let projectID = window.projectID {
                switch window.section {
                case .code:
                    CodeSectionView(window: window, workspace: workspace, projectID: projectID)
                case .docs:
                    DocsSectionView(window: window, workspace: workspace, projectID: projectID)
                default:
                    EmptyView()
                }
            }
        }
    }

    /// DEMO and its sub project API, with their folders, files and docs.
    static func workspace() -> (DeviceWorkspace, ProjectFilesConnection) {
        func entry(_ path: String, isDirectory: Bool = false) -> FileEntry {
            FileEntry(name: ProjectPaths.name(of: path), path: path, isDirectory: isDirectory, size: isDirectory ? 0 : 12,
                      modified: modified)
        }
        let connection = ProjectFilesConnection(
            folders: [
                "DEMO": ["": [entry("Sources", isDirectory: true), entry("api", isDirectory: true), entry("Package.swift")]],
                "API": ["": [entry("cmd", isDirectory: true), entry("go.mod")], "cmd": [entry("cmd/main.go")]],
            ],
            files: ["API": ["cmd/main.go": "package main\n", "docs/endpoints.md": "# Endpoints\n"]],
            docs: [
                "DEMO": [DocEntry(path: "docs/README.md", title: "Demo"), DocEntry(path: "docs/guides/setup.md", title: "Setup")],
                "API": [DocEntry(path: "docs/README.md", title: "Api"), DocEntry(path: "docs/endpoints.md", title: "Endpoints")],
            ])
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.projects = [
            ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo", subprojectIDs: ["API"]),
            ProjectSummary(id: "API", name: "Api", rootPath: "/Users/example/Demo/api", parentID: "DEMO"),
        ]
        return (workspace, connection)
    }

    /// The window's section, hosted without a window.
    static func host(_ window: WindowState, _ workspace: DeviceWorkspace) -> NSHostingView<SectionHost> {
        // The AppKit views of the sections need the application.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SectionHost(window: window, workspace: workspace))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        return host
    }

    /// Lays the host out until `condition` holds, so that its views appear and follow the window;
    /// the bound only ends a test that fails.
    static func settle(_ host: NSView, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition(), ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Code: a switch to the sub project lists its root and the folders above its file target, reads its tab and gives the window its commands; a switch back shows the first tree, still listed")
    func codeSection() async throws {
        let (workspace, connection) = Self.workspace()
        let window = WindowState(deviceID: workspace.deviceID)
        window.section = .code
        window.activate(projectID: "DEMO")
        let host = Self.host(window, workspace)
        let demo = CodeDocsStore.shared.fileTree(window: window, workspace: workspace, projectID: "DEMO")
        let demoCommands = CodeSectionCommands.of(window: window, workspace: workspace, projectID: "DEMO")
        try await Self.settle(host) { demo.listings[""] != nil && window.sectionCommands === demoCommands }
        #expect(demo.listings[""]?.map(\.name) == ["Sources", "api", "Package.swift"])
        #expect(window.sectionCommands === demoCommands)

        // A file target of the sub project opens its tab with the folders above it expanded, and the
        // window switches to the sub project while the Code section is shown.
        window.updateViewState(of: "API") { $0.revealFile(path: "cmd/main.go", line: nil) }
        window.activate(projectID: "API")
        let api = CodeDocsStore.shared.fileTree(window: window, workspace: workspace, projectID: "API")
        let apiCommands = CodeSectionCommands.of(window: window, workspace: workspace, projectID: "API")
        let tab = try #require(FileActions.viewState(window, "API").editorTabs.first?.buffer)
        try await Self.settle(host) {
            api.listings[""] != nil && api.listings["cmd"] != nil && tab.content == .text && window.sectionCommands === apiCommands
        }
        let rows = api.rows(of: "", expanded: FileActions.viewState(window, "API").expandedCodeFolders)
        #expect(rows.map(\.title) == ["cmd", "go.mod"])
        #expect(rows.first?.children.map(\.title) == ["main.go"])
        #expect(tab.text == "package main\n")
        #expect(window.sectionCommands === apiCommands)

        window.activate(projectID: "DEMO")
        try await Self.settle(host) { window.sectionCommands === demoCommands }
        #expect(window.sectionCommands === demoCommands)
        #expect(demo.listings[""]?.map(\.name) == ["Sources", "api", "Package.swift"])
        #expect(demo.loading.isEmpty)
        #expect(connection.calls.sorted() == ["files.list API /", "files.list API /cmd", "files.list DEMO /", "files.read API cmd/main.go"])
        workspace.close()
    }

    @Test("Docs: a switch to the sub project loads its docs, reads its selected doc and gives the window its commands; a switch back shows the first docs, still loaded")
    func docsSection() async throws {
        let (workspace, connection) = Self.workspace()
        let window = WindowState(deviceID: workspace.deviceID)
        window.section = .docs
        window.activate(projectID: "DEMO")
        let host = Self.host(window, workspace)
        let demo = CodeDocsStore.shared.docsTree(window: window, workspace: workspace, projectID: "DEMO")
        let demoCommands = DocsSectionCommands.of(window: window, workspace: workspace, projectID: "DEMO")
        try await Self.settle(host) { demo.docs != nil && !demo.isLoading && window.sectionCommands === demoCommands }
        #expect(demo.rows(expanded: []).map(\.title) == ["guides", "Demo"])
        #expect(window.sectionCommands === demoCommands)

        // The sub project shows its last selected doc in Edit mode, and the window switches to it
        // while the Docs section is shown.
        window.updateViewState(of: "API") {
            $0.selectedDocPath = "docs/endpoints.md"
            $0.docMode = .edit
        }
        window.activate(projectID: "API")
        let api = CodeDocsStore.shared.docsTree(window: window, workspace: workspace, projectID: "API")
        let apiCommands = DocsSectionCommands.of(window: window, workspace: workspace, projectID: "API")
        try await Self.settle(host) {
            api.docs != nil && !api.isLoading && FileActions.viewState(window, "API").docBuffer?.content == .text
                && window.sectionCommands === apiCommands
        }
        #expect(api.rows(expanded: []).map(\.title) == ["Api", "Endpoints"])
        let buffer = FileActions.viewState(window, "API").docBuffer
        #expect(buffer?.path == "docs/endpoints.md")
        #expect(buffer?.text == "# Endpoints\n")
        #expect(window.sectionCommands === apiCommands)

        window.activate(projectID: "DEMO")
        try await Self.settle(host) { window.sectionCommands === demoCommands }
        #expect(window.sectionCommands === demoCommands)
        #expect(demo.rows(expanded: []).map(\.title) == ["guides", "Demo"])
        #expect(!demo.isLoading)
        #expect(connection.calls.sorted() == ["docs.list API", "docs.list DEMO", "files.read API docs/endpoints.md"])
        workspace.close()
    }
}
