import AppKit
import Foundation
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/views.md › Editor and › Refresh: the Views section shows the selected view's file in the
/// code editor beside its previews; what the user types stays in the editor, and a save writes the
/// file with `files.write`, after which the previews show the engine's new build. The section is
/// hosted without a window, as in the centre column of a main window.
@MainActor
@Suite("Editor of the Views section")
struct ViewsEditorTests {
    /// The modification date of the files of the tests.
    static let modified = Date(timeIntervalSince1970: 1_800_000_000)
    /// The end of the build of the previews before any save.
    static let firstBuild = Date(timeIntervalSince1970: 1_800_000_100)

    static let counter = """
    import SwiftUI

    struct CounterView: View {
        var body: some View { Text("Old") }
    }

    struct CounterRow: View {
        var body: some View { Text("Row") }
    }

    #Preview { CounterView() }

    """

    static let profile = """
    import SwiftUI

    struct ProfileView: View {
        var body: some View { Text("Profile") }
    }

    """

    static let counterView = ProjectView(name: "CounterView", path: "Sources/App/Counter.swift", line: 3, kind: .swiftUI,
                                         previews: [ViewPreview(line: 11)])
    static let counterRow = ProjectView(name: "CounterRow", path: "Sources/App/Counter.swift", line: 7, kind: .swiftUI)
    static let profileView = ProjectView(name: "ProfileView", path: "Sources/App/Profile.swift", line: 3, kind: .swiftUI)

    /// An engine for the project `DEMO`: `views.list` gives `views`, `files.read` and `files.write`
    /// act on `files`, and each write builds the previews again, as the engine does when a file
    /// of the package changes on disk: the next polls give the time its build ended.
    final class ViewsConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var storedViews = [ViewsEditorTests.counterView, ViewsEditorTests.counterRow, ViewsEditorTests.profileView]
        private var storedFiles: [String: (text: String, modified: Date)] = [
            "Sources/App/Counter.swift": (ViewsEditorTests.counter, ViewsEditorTests.modified),
            "Sources/App/Profile.swift": (ViewsEditorTests.profile, ViewsEditorTests.modified),
        ]
        private var recordedWrites: [FilesWrite.Params] = []
        private var recordedStarts: [String] = []
        private var builds = 0

        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        var views: [ProjectView] {
            get { lock.withLock { storedViews } }
            set { lock.withLock { storedViews = newValue } }
        }
        /// The `files.write` calls, in order.
        var writes: [FilesWrite.Params] { lock.withLock { recordedWrites } }
        /// The `previews.start` calls: `<path> <name>`.
        var starts: [String] { lock.withLock { recordedStarts } }

        func removeFile(_ path: String) {
            lock.withLock { storedFiles[path] = nil }
        }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            let result: Any
            switch params {
            case is ViewsList.Params:
                result = views
            case let params as FilesRead.Params:
                guard let file = lock.withLock({ storedFiles[params.path] }) else {
                    throw EngineError(.notFound, "\(params.path) was not found.")
                }
                result = FileContent(path: params.path, text: file.text, modified: file.modified, size: file.text.utf8.count)
            case let params as FilesWrite.Params:
                result = try lock.withLock { () throws -> FileContent in
                    guard storedFiles[params.path]?.modified == params.expectedModified else {
                        throw EngineError(.conflict, "\(params.path) changed on disk.")
                    }
                    let written = (params.text, ViewsEditorTests.modified.addingTimeInterval(Double(recordedWrites.count + 1)))
                    storedFiles[params.path] = written
                    recordedWrites.append(params)
                    builds += 1
                    return FileContent(path: params.path, text: written.0, modified: written.1, size: written.0.utf8.count)
                }
            case let params as PreviewsStart.Params:
                lock.withLock { recordedStarts.append("\(params.path) \(params.name)") }
                result = PreviewSession(sessionID: UUID())
            case is PreviewsPoll.Params:
                try await Task.sleep(for: .milliseconds(20))
                let builds = lock.withLock { self.builds }
                result = PreviewStatus(sequence: builds + 1, state: .running,
                                       builtAt: ViewsEditorTests.firstBuild.addingTimeInterval(Double(builds)),
                                       previews: [PreviewFrame(index: 0, title: "Preview 1")])
            case is PreviewsStop.Params, is PreviewsUpdate.Params, is PreviewsInput.Params:
                result = Empty()
            default:
                throw EngineError(.unavailable, "Offline.")
            }
            guard let typed = result as? M.Result else { throw EngineError(.internal, "Unexpected result.") }
            return typed
        }

        func close() {}
    }

    struct Host: View {
        let window: WindowState
        let workspace: DeviceWorkspace

        var body: some View {
            ViewsSectionView(window: window, workspace: workspace, projectID: "DEMO")
        }
    }

    /// The Views section of `DEMO`, hosted without a window, once its list is read.
    static func showSection() async throws -> (WindowState, ViewsSectionState, ViewsConnection, DeviceWorkspace, NSView) {
        let connection = ViewsConnection()
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.projects = [ProjectSummary(id: "DEMO", name: "Demo", type: .swiftApplication, rootPath: "/Users/example/Demo")]
        let window = WindowState(deviceID: workspace.deviceID)
        window.section = .views
        window.activate(projectID: "DEMO")
        // The AppKit views of the editor need the application.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Host(window: window, workspace: workspace))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 700)
        try await settle(host) { window.viewsState(of: "DEMO")?.views != nil }
        let state = try #require(window.viewsState(of: "DEMO"))
        return (window, state, connection, workspace, host)
    }

    /// Lays the host out until `condition` holds; the bound only ends a test that fails.
    static func settle(_ host: NSView, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition(), ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Selecting a view shows its file in the editor beside the previews; a view of the same file keeps the editor's buffer, a view of another file opens its own")
    func editorShowsTheViewsFile() async throws {
        let (window, state, connection, workspace, host) = try await Self.showSection()
        #expect(window.sectionCommands === state)
        #expect(state.editor == nil)

        state.select(Self.counterView)
        try await Self.settle(host) { state.editor?.content == .text && state.session?.builtAt != nil }
        let editor = try #require(state.editor)
        #expect(editor.path == "Sources/App/Counter.swift")
        #expect(editor.text == Self.counter)
        #expect(editor.language == .swift)
        #expect(connection.starts == ["Sources/App/Counter.swift CounterView"])

        // Another view of the same file keeps the buffer and moves to its declaration.
        state.select(Self.counterRow)
        #expect(state.editor === editor)
        #expect(state.session == nil)

        state.select(Self.profileView)
        try await Self.settle(host) { state.editor?.content == .text }
        #expect(state.editor !== editor)
        #expect(state.editor?.path == "Sources/App/Profile.swift")
        #expect(state.editor?.text == Self.profile)
        workspace.close()
    }

    @Test("What the user types neither writes the file nor builds the previews; Save writes it with files.write, then the previews show the build that follows, in the same session")
    func saveRefreshesThePreviews() async throws {
        let (window, state, connection, workspace, host) = try await Self.showSection()
        state.select(Self.counterView)
        try await Self.settle(host) { state.editor?.content == .text && state.session?.builtAt == Self.firstBuild }
        let editor = try #require(state.editor)
        let session = try #require(state.session)

        // Typing, as the text view reports it.
        let typed = Self.counter.replacingOccurrences(of: "Text(\"Old\")", with: "Text(\"New\")")
        editor.editorTextDidChange(typed)
        #expect(editor.isDirty)
        #expect(state.canSave)
        #expect(window.unsavedEditors().count == 1)
        #expect(window.unsavedEditors().first === editor)
        try await Task.sleep(for: .milliseconds(200))
        #expect(connection.writes.isEmpty)
        #expect(session.builtAt == Self.firstBuild)

        state.save()
        try await Self.settle(host) { !editor.isDirty && session.builtAt == Self.firstBuild.addingTimeInterval(1) }
        #expect(connection.writes == [FilesWrite.Params(projectID: "DEMO", path: "Sources/App/Counter.swift", text: typed,
                                                        expectedModified: Self.modified)])
        #expect(session.builtAt == Self.firstBuild.addingTimeInterval(1))
        #expect(state.session === session)
        #expect(connection.starts == ["Sources/App/Counter.swift CounterView"])
        #expect(!state.canSave)
        #expect(window.unsavedEditors().isEmpty)
        workspace.close()
    }

    @Test("The editor keeps its file when its view disappears from the list, and closes when the file is deleted on disk without unsaved changes")
    func editorOutlivesItsView() async throws {
        let (_, state, connection, workspace, host) = try await Self.showSection()
        state.select(Self.counterView)
        try await Self.settle(host) { state.editor?.content == .text && state.session != nil }
        let editor = try #require(state.editor)

        // The view renamed on disk: the list no longer has it.
        connection.views = [ProjectView(name: "CounterScreen", path: "Sources/App/Counter.swift", line: 3, kind: .swiftUI),
                            Self.counterRow, Self.profileView]
        state.reload()
        try await Self.settle(host) { state.selection == nil }
        #expect(state.session == nil)
        #expect(state.editor === editor)

        connection.removeFile("Sources/App/Counter.swift")
        editor.checkDisk()
        try await Self.settle(host) { state.editor == nil }
        #expect(state.editor == nil)
        workspace.close()
    }
}
