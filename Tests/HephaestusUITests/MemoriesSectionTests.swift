import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/memories.md › List and › Saving: the groups of the list, the filter and the field
/// validation messages; the read-only groups and editor of the inherited memories.
@MainActor
@Suite("Memories section")
struct MemoriesSectionTests {
    @Test("Memories are grouped under User, Feedback, Project, Reference and Other, sorted by name; empty groups are hidden")
    func groups() {
        let memories = [
            MemorySummary(file: "b.md", name: "beta", description: "", type: "project"),
            MemorySummary(file: "z.md", name: "alpha", description: "", type: nil),
            MemorySummary(file: "c.md", name: "gamma", description: "", type: "Project"),
            MemorySummary(file: "a.md", name: "alpha", description: "", type: "project"),
            MemorySummary(file: "u.md", name: "you", description: "", type: "user"),
            MemorySummary(file: "y.md", name: "alpha", description: "", type: nil),
        ]
        let groups = MemoryGroups.groups(of: memories)
        #expect(groups.map(\.title) == ["User", "Project", "Other"])
        #expect(groups[1].memories.map(\.file) == ["a.md", "b.md"])
        #expect(groups[2].memories.map(\.file) == ["y.md", "z.md", "c.md"])
    }

    @Test("The filter matches the name and the description without case")
    func filter() {
        #expect(MemoryGroups.matches(name: "user-role", description: "Backend developer", filter: ""))
        #expect(MemoryGroups.matches(name: "user-role", description: "Backend developer", filter: "ROLE"))
        #expect(MemoryGroups.matches(name: "user-role", description: "Backend developer", filter: "backend"))
        #expect(!MemoryGroups.matches(name: "user-role", description: "Backend developer", filter: "swift"))
        #expect(MemoryGroups.matches(name: "MEMORY.md", description: "", filter: "memory"))
    }

    @Test("Names follow the skill name rules and must not be taken by another memory's name or file")
    func validation() {
        let folder = MemoryFolder(projectID: "MEM", path: "/tmp/memory", hasIndex: true, memories: [
            MemorySummary(file: "user_role.md", name: "user-role", description: "", type: "user"),
            MemorySummary(file: "Style.md", name: "answer-style", description: "", type: "feedback"),
        ])
        #expect(MemoryValidation.nameMessage("User Role", folder: folder) == "Use 1–64 lowercase letters, digits and single hyphens.")
        #expect(MemoryValidation.nameMessage("user-role", folder: folder) == "A memory named “user-role” already exists.")
        #expect(MemoryValidation.nameMessage("style", folder: folder) == "A memory named “style” already exists.")
        #expect(MemoryValidation.nameMessage("user-role", folder: folder, except: "user_role.md") == nil)
        #expect(MemoryValidation.nameMessage("new-one", folder: folder) == nil)
        #expect(MemoryValidation.descriptionMessage("") == "A description is required.")
        #expect(MemoryValidation.descriptionMessage("x") == nil)
    }

    @Test("The form checks a field only when it differs from the saved value and keeps an Other type until one is chosen")
    func form() {
        let form = MemoryForm()
        form.reset(to: Memory(file: "Old Name.md", name: "Old Name", description: "", type: "notes", body: "Body"))
        #expect(form.type == nil)
        #expect(!form.hasUnsavedChanges)
        #expect(form.isValid(folder: nil, file: "Old Name.md"))
        form.body.text = "Changed"
        #expect(form.hasUnsavedChanges)
        #expect(form.isValid(folder: nil, file: "Old Name.md"))
        form.description = "x"
        form.description = ""
        form.name = "Bad Name"
        #expect(form.nameMessage(folder: nil, file: "Old Name.md") == "Use 1–64 lowercase letters, digits and single hyphens.")
        form.type = .reference
        form.discardChanges()
        #expect(form.type == nil)
        #expect(!form.hasUnsavedChanges)
    }

    @Test("After a save, the fields not edited meanwhile show the saved file's values")
    func formAfterSave() {
        let form = MemoryForm()
        form.reset(to: Memory(file: "m.md", name: "m", description: "D1", type: "user", body: "B1"))
        form.body.text = "B2"
        let sent = form.values
        // Saved elsewhere meanwhile: the description; the response carries it with the new body.
        form.adoptSaved(Memory(file: "m.md", name: "m", description: "D2", type: "user", body: "B2"), keepingEditsSince: sent)
        #expect(form.description == "D2")
        #expect(form.body.text == "B2")
        #expect(!form.hasUnsavedChanges)
    }

    // MARK: Inherited memories (docs/memories.md › Inherited memories)

    /// A connection that records the projects of its `memories.get` calls and answers them with
    /// `memory`.
    final class InheritedConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private var answer: Memory

        init(memory: Memory) {
            answer = memory
        }

        var memory: Memory {
            get { lock.withLock { answer } }
            set { lock.withLock { answer = newValue } }
        }

        var projects: [String] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let get = params as? MemoriesGet.Params {
                lock.withLock { recorded.append(get.projectID) }
                if let result = memory as? M.Result { return result }
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    /// The sub project SUB with one memory, inheriting the folders of APP and SUITE.
    static let subFolder = MemoryFolder(projectID: "SUB", path: "/Users/example/.claude/projects/sub/memory", hasIndex: false, memories: [
        MemorySummary(file: "own.md", name: "own", description: "Own", type: "user"),
    ], inherited: [
        InheritedMemoryFolder(projectID: "APP", path: "/Users/example/.claude/projects/app/memory", memories: [
            MemorySummary(file: "z.md", name: "zeta", description: "Last", type: "user"),
            MemorySummary(file: "b.md", name: "alpha", description: "Backend developer", type: nil),
            MemorySummary(file: "a.md", name: "alpha", description: "Answer style", type: "feedback"),
        ]),
        InheritedMemoryFolder(projectID: "SUITE", path: "/Users/example/.claude/projects/suite/memory", memories: []),
        InheritedMemoryFolder(projectID: "GONE", path: "/Users/example/.claude/projects/gone/memory", memories: [
            MemorySummary(file: "g.md", name: "gamma", description: "", type: "project"),
        ]),
    ])

    @Test("Inherited groups keep the engine's order, headed Inherited from <parent name>, sorted by name, filtered, empty ones hidden")
    func inheritedGroups() {
        let names = ["APP": "App", "SUITE": "Suite"]
        let groups = MemoryGroups.inheritedGroups(of: Self.subFolder.inherited, filter: "") { names[$0] }
        #expect(groups.map(\.title) == ["Inherited from App", "Inherited from GONE"])
        #expect(groups.map(\.projectID) == ["APP", "GONE"])
        #expect(groups[0].memories.map(\.file) == ["a.md", "b.md", "z.md"])
        let filtered = MemoryGroups.inheritedGroups(of: Self.subFolder.inherited, filter: "BACKEND") { names[$0] }
        #expect(filtered == [MemoryGroups.InheritedGroup(projectID: "APP", title: "Inherited from App", memories: [
            MemorySummary(file: "b.md", name: "alpha", description: "Backend developer", type: nil),
        ])])
    }

    @Test("No Memories shows only without own memory, MEMORY.md and inherited memory, without list error or unsaved changes")
    func emptyState() {
        var folder = MemoryFolder(projectID: "SUB", path: "/m", hasIndex: false, memories: [])
        #expect(MemoryGroups.showsEmptyState(folder, listError: nil, hasUnsavedChanges: false))
        #expect(!MemoryGroups.showsEmptyState(folder, listError: "Failed", hasUnsavedChanges: false))
        #expect(!MemoryGroups.showsEmptyState(folder, listError: nil, hasUnsavedChanges: true))
        folder.inherited = [InheritedMemoryFolder(projectID: "APP", path: "/a", memories: [])]
        #expect(MemoryGroups.showsEmptyState(folder, listError: nil, hasUnsavedChanges: false))
        folder.inherited[0].memories = [MemorySummary(file: "a.md", name: "a", description: "")]
        #expect(!MemoryGroups.showsEmptyState(folder, listError: nil, hasUnsavedChanges: false))
    }

    @Test("An inherited row's selection is <ancestor id>/<file name>; − and ⌫ act only on the project's own memories")
    func inheritedSelection() {
        #expect(MemoryActions.inheritedTag(projectID: "APP", file: "a.md") == "APP/a.md")
        #expect(MemoryActions.target(of: "MEMORY.md") == .index)
        #expect(MemoryActions.target(of: "own.md") == .memory(file: "own.md"))
        #expect(MemoryActions.target(of: "APP/a.md") == .inherited(projectID: "APP", file: "a.md"))
        #expect(MemoryEditorState(target: .inherited(projectID: "APP", file: "a.md"), projectID: "SUB").selection == "APP/a.md")
        #expect(MemoryActions.ownMemoryFile(of: "own.md") == "own.md")
        #expect(MemoryActions.ownMemoryFile(of: "APP/a.md") == nil)
        #expect(MemoryActions.ownMemoryFile(of: "MEMORY.md") == nil)
        #expect(MemoryActions.ownMemoryFile(of: nil) == nil)
    }

    @Test("An inherited memory's path is in its ancestor's folder; the feedback names it")
    func inheritedPaths() {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: false)
        workspace.memoryFolders["SUB"] = Self.subFolder
        #expect(MemoryActions.displayPath(of: .inherited(projectID: "APP", file: "a.md"), in: workspace, projectID: "SUB")
            == "~/.claude/projects/app/memory/a.md")
        #expect(MemoryActions.displayPath(of: .memory(file: "own.md"), in: workspace, projectID: "SUB") == "~/.claude/projects/sub/memory/own.md")
        #expect(MemoryActions.displayPath(of: .index, in: workspace, projectID: "SUB") == "~/.claude/projects/sub/memory/MEMORY.md")
        #expect(MemoryActions.displayPath(of: .inherited(projectID: "NONE", file: "a.md"), in: workspace, projectID: "SUB") == "a.md")
        // A selection whose folder is no longer inherited shows as not found.
        #expect(!MemoryActions.isNoLongerInherited(.inherited(projectID: "APP", file: "a.md"), in: Self.subFolder))
        #expect(MemoryActions.isNoLongerInherited(.inherited(projectID: "NONE", file: "a.md"), in: Self.subFolder))
        #expect(!MemoryActions.isNoLongerInherited(.inherited(projectID: "NONE", file: "a.md"), in: nil))
        #expect(!MemoryActions.isNoLongerInherited(.memory(file: "own.md"), in: Self.subFolder))
        var view = ProjectViewState()
        view.selectedMemoryFile = "APP/z.md"
        #expect(MemoryActions.selectedItemName(of: view, in: workspace, projectID: "SUB") == "zeta")
        view.selectedMemoryFile = "APP/missing.md"
        #expect(MemoryActions.selectedItemName(of: view, in: workspace, projectID: "SUB") == "missing")
    }

    @Test("An inherited memory is read with the ancestor's projectID and is read-only: never unsaved, never saved, replaced on refresh")
    func inheritedEditor() async {
        let connection = InheritedConnection(memory: Memory(file: "a.md", name: "answer-style", description: "D1", type: "feedback", body: "B1"))
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.memoryFolders["SUB"] = Self.subFolder
        let window = WindowState(deviceID: "device")
        let editor = MemoryEditorState(target: .inherited(projectID: "APP", file: "a.md"), projectID: "SUB", bodyMode: .edit)
        editor.attach(window: window, workspace: workspace)
        #expect(editor.isReadOnly)
        #expect(editor.displayName == "a")
        await editor.refresh()
        #expect(connection.projects == ["APP"])
        #expect(editor.hasLoaded)
        #expect(editor.form.savedName == "answer-style")
        #expect(editor.form.body.text == "B1")
        editor.form.body.text = "changed"
        editor.form.name = "other"
        #expect(!editor.hasUnsavedChanges)
        #expect(!editor.canSave)
        #expect(editor.unsavedEditors.isEmpty)
        // Go to Line and Toggle Comment never act on its body, even with the focus in Edit mode.
        editor.form.body.hasEditorFocus = true
        #expect(editor.focusedEditor == nil)
        let own = MemoryEditorState(target: .memory(file: "own.md"), projectID: "SUB", bodyMode: .edit)
        own.form.body.hasEditorFocus = true
        #expect(own.focusedEditor === own.form.body)
        connection.memory = Memory(file: "a.md", name: "answer-style", description: "D2", type: "feedback", body: "B2")
        await editor.refresh()
        #expect(editor.conflict == nil)
        #expect(editor.form.description == "D2")
        #expect(editor.form.body.text == "B2")
        #expect(!MemoryEditorState(target: .memory(file: "own.md"), projectID: "SUB").isReadOnly)
    }

    @Test("Paths are written with ~: This Mac's home folder locally, a folder under /Users/<name> in a remote window")
    func displayPaths() {
        let path = "/Users/example/.claude/projects/-Users-example-Notes/memory"
        #expect(MemoryActions.displayPath(path, isLocal: true, home: "/Users/example") == "~/.claude/projects/-Users-example-Notes/memory")
        #expect(MemoryActions.displayPath(path, isLocal: true, home: "/Users/Shared") == path)
        #expect(MemoryActions.displayPath(path, isLocal: false, home: "/Users/Shared") == "~/.claude/projects/-Users-example-Notes/memory")
        #expect(MemoryActions.displayPath("/Volumes/Data/memory", isLocal: false, home: "/Users/Shared") == "/Volumes/Data/memory")
    }
}
