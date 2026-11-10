// OWNER: ui-shell — WindowState and ProjectViewState with their coding and restoration rules
// (docs/ui.md › WindowState, › Persistence; docs/architecture.md › WindowState).
import Foundation
import HephaestusCore

/// The state of one main window (docs/ui.md › WindowState). Its active project is `projectID`,
/// a top-level project or a sub project at any depth. It belongs to its window: it is never sent
/// to an engine and never synced.
///
/// Coding: `Codable` encodes every property of the docs' table (`debug_ui_state` uses
/// `EngineJSON.encoder()`); with `WindowState.persistedOnlyKey` set in the encoder's `userInfo`
/// it encodes only the persisted properties, the active project's entry and the
/// `hidesClosedChats` of the other entries (`@SceneStorage`). Editor buffers are never encoded.
@MainActor @Observable
final class WindowState: Identifiable {
    /// The window's identity inside `AppModel`.
    let id: UUID
    /// The device the window shows. A switch of device leaves a sub project's Dashboard, the
    /// detail of a virtual machine and the setup view of an image, which belong to This Mac.
    var deviceID: String {
        didSet {
            if deviceID != oldValue {
                subProjectDashboardID = nil
                shownVirtualMachineID = nil
                shownImageSetupID = nil
            }
        }
    }
    /// The active project; nil when the device has no project or while the window waits for its
    /// device's default project. A switch of project leaves a sub project's Dashboard.
    var projectID: String? {
        didSet {
            if projectID != oldValue {
                subProjectDashboardID = nil
            }
        }
    }
    /// The selected sidebar section. Selecting a section, the selected one included, leaves the
    /// Global Memories view (docs/memories.md › Global Memories view), the Internal Skills view
    /// (docs/skills.md › Internal Skills view), a sub project's Dashboard (docs/ui.md › Sidebar),
    /// the detail of a virtual machine (docs/virtual-machines.md › Detail) and the setup view of an
    /// image (docs/virtual-machines.md › Setup view).
    var section: ProjectSection = .dashboard {
        didSet {
            showsGlobalMemories = false
            showsInternalSkills = false
            subProjectDashboardID = nil
            shownVirtualMachineID = nil
            shownImageSetupID = nil
        }
    }
    /// The centre column shows the Global Memories view; no sidebar row is selected. Showing it
    /// leaves the Internal Skills view, a sub project's Dashboard, the detail of a virtual machine
    /// and the setup view of an image.
    var showsGlobalMemories = false {
        didSet {
            if showsGlobalMemories {
                showsInternalSkills = false
                subProjectDashboardID = nil
                shownVirtualMachineID = nil
                shownImageSetupID = nil
            }
        }
    }
    /// The centre column shows the Internal Skills view; no sidebar row is selected. Showing it
    /// leaves the Global Memories view, a sub project's Dashboard, the detail of a virtual machine
    /// and the setup view of an image.
    var showsInternalSkills = false {
        didSet {
            if showsInternalSkills {
                showsGlobalMemories = false
                subProjectDashboardID = nil
                shownVirtualMachineID = nil
                shownImageSetupID = nil
            }
        }
    }
    /// The sub project whose Dashboard the centre column shows from the sidebar, without
    /// activating it; nil otherwise. Only its sidebar row is selected (docs/ui.md › Sidebar).
    /// Showing it leaves the detail of a virtual machine and the setup view of an image.
    var subProjectDashboardID: String? {
        didSet {
            if subProjectDashboardID != nil {
                shownVirtualMachineID = nil
                shownImageSetupID = nil
            }
        }
    }
    /// The virtual machine whose detail the centre column shows; no sidebar row is selected.
    /// Showing it leaves the Global Memories view, the Internal Skills view, a sub project's
    /// Dashboard and the setup view of an image; never persisted (docs/virtual-machines.md ›
    /// Detail).
    var shownVirtualMachineID: UUID? {
        didSet {
            if shownVirtualMachineID != nil {
                showsGlobalMemories = false
                showsInternalSkills = false
                subProjectDashboardID = nil
                shownImageSetupID = nil
            }
        }
    }
    /// The image whose setup view the centre column shows; no sidebar row is selected. Showing it
    /// leaves the Global Memories view, the Internal Skills view, a sub project's Dashboard and the
    /// detail of a virtual machine; never persisted (docs/virtual-machines.md › Setup view).
    var shownImageSetupID: UUID? {
        didSet {
            if shownImageSetupID != nil {
                showsGlobalMemories = false
                showsInternalSkills = false
                subProjectDashboardID = nil
                shownVirtualMachineID = nil
            }
            leavesImageSetupAfterAlert = false
        }
    }
    var sidebarVisible = true
    var inspectorVisible = true
    /// Inspector width in points.
    var inspectorWidth: Double = 380
    /// View state of every project this window showed.
    var projectStates: [ProjectKey: ProjectViewState] = [:]
    /// The Global Memories view's selected row, editor and mode for each device the window showed,
    /// by device id.
    var globalMemoryStates: [String: MemoryViewState] = [:]
    /// The Internal Skills view's selected skill and editor for each device the window showed, by
    /// device id.
    var internalSkillStates: [String: SkillViewState] = [:]
    /// Last active project per device in this window.
    var lastProjectByDevice: [String: String] = [:]
    /// Search panel shown. Closing the panel ends the adding of a resource (docs/search.md › Adding
    /// a resource).
    var searchVisible = false {
        didSet {
            if !searchVisible, searchPick != nil {
                searchPick = nil
            }
        }
    }
    /// The search panel's query, scope chips and project toggle.
    var search = SearchPanelState()
    /// The sheet shown on the window.
    var sheet: WindowSheet?
    /// A navigation waiting for the device to connect or for the sheet to close.
    var pendingTarget: NavigationTarget?

    // MARK: Window-only state, not part of the docs' table and never encoded

    /// The alert shown on the window. Its `OK` takes the window back to its section when it is the
    /// alert of a setup that failed (docs/virtual-machines.md › Setup view).
    var alert: WindowAlert? {
        didSet {
            if alert == nil, leavesImageSetupAfterAlert {
                shownImageSetupID = nil
            }
        }
    }
    /// True while the window shows the alert of a setup that failed, over its setup view.
    private(set) var leavesImageSetupAfterAlert = false
    /// The composer the search panel adds a result to, from `Add Resource…` until the panel closes;
    /// nil while a result navigates (docs/search.md › Adding a resource).
    var searchPick: SearchPick?
    /// A request of a menu item to the shown section.
    var pendingSectionCommand: SectionCommand?
    /// True while the window waits for its device's projects to choose the default project
    /// (docs/projects.md › Project selector).
    var needsDefaultProject = false
    /// True from a switch of the active project, or a navigation to the Builds section, until the
    /// project is loaded and Builds checked against its GitHub page (docs/builds.md › Visibility).
    var buildsCheckPending = false
    /// The active project and whether it had a GitHub page when the window last looked, so that
    /// a window that shows Builds follows a page that is lost (docs/builds.md › Visibility).
    var observedGitHubPage: ObservedGitHubPage?
    /// The app, set when the window registers.
    @ObservationIgnored weak var app: AppModel?
    /// The menu commands of the shown section, set by that section's view.
    @ObservationIgnored weak var sectionCommands: (any SectionCommandHandler)?

    /// A new window on `deviceID` with the defaults of the docs' table.
    init(id: UUID = UUID(), deviceID: String) {
        self.id = id
        self.deviceID = deviceID
    }

    /// The section the centre column shows: nil while it shows the Global Memories view, the
    /// Internal Skills view, a sub project's Dashboard, the detail of a virtual machine or the
    /// setup view of an image.
    var shownSection: ProjectSection? {
        showsGlobalMemories || showsInternalSkills || subProjectDashboardID != nil || shownVirtualMachineID != nil
            || shownImageSetupID != nil ? nil : section
    }

    /// The setup of an image has ended: a window that shows its setup view goes back to its
    /// section, after `OK` of the failure alert when `failure` is given. Returns true when the
    /// window showed it (docs/virtual-machines.md › Setup view).
    @discardableResult
    func imageSetupEnded(_ imageID: UUID, failure: WindowAlert?) -> Bool {
        guard shownImageSetupID == imageID else { return false }
        if let failure {
            alert = failure
            leavesImageSetupAfterAlert = true
        } else {
            shownImageSetupID = nil
        }
        return true
    }

    /// The key of the active project.
    var activeProjectKey: ProjectKey? {
        projectID.map { ProjectKey(deviceID: deviceID, projectID: $0) }
    }

    /// The view state of the active project; setting it stores the entry.
    var viewState: ProjectViewState {
        get { activeProjectKey.flatMap { projectStates[$0] } ?? ProjectViewState() }
        set {
            guard let key = activeProjectKey else { return }
            projectStates[key] = newValue
        }
    }

    /// Changes the view state of a project of this window, creating its entry when needed.
    func updateViewState(of projectID: String? = nil, _ change: (inout ProjectViewState) -> Void) {
        guard let projectID = projectID ?? self.projectID else { return }
        let key = ProjectKey(deviceID: deviceID, projectID: projectID)
        var state = projectStates[key] ?? ProjectViewState()
        change(&state)
        projectStates[key] = state
    }

    /// The editors of this window with unsaved changes, in every project it showed, then those of
    /// its Global Memories view and its Internal Skills view for each device, which belong to no
    /// project (docs/ui.md › Unsaved changes and quitting).
    func unsavedEditors(deviceID: String? = nil, projectIDs: Set<String>? = nil) -> [any UnsavedEditor] {
        let projects = projectStates
            .filter { key, _ in
                (deviceID == nil || key.deviceID == deviceID) && (projectIDs == nil || projectIDs!.contains(key.projectID))
            }
            .sorted { ($0.key.deviceID, $0.key.projectID) < ($1.key.deviceID, $1.key.projectID) }
            .flatMap { $0.value.unsavedEditors }
        guard projectIDs == nil else { return projects }
        let global = globalMemoryStates
            .filter { deviceID == nil || $0.key == deviceID }
            .sorted { $0.key < $1.key }
            .flatMap { $0.value.memoryEditor?.unsavedEditors ?? [] }
        let skills = internalSkillStates
            .filter { deviceID == nil || $0.key == deviceID }
            .sorted { $0.key < $1.key }
            .flatMap { $0.value.skillEditor?.unsavedEditors ?? [] }
        return projects + global + skills
    }

    /// The `@SceneStorage` value: the persisted properties as JSON (docs/ui.md › Persistence).
    var persistedJSON: String? {
        let encoder = EngineJSON.encoder()
        encoder.userInfo[WindowState.persistedOnlyKey] = true
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A window state restored from its `@SceneStorage` value; nil when it cannot be decoded.
    /// The properties that are not persisted take their defaults.
    static func restored(fromJSON json: String) -> WindowState? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? EngineJSON.decode(WindowState.self, from: data)
    }

    /// `userInfo` key of an encoder that writes only the persisted properties.
    nonisolated static let persistedOnlyKey = CodingUserInfoKey(rawValue: "HephaestusPersistedWindowState")!
}

// MARK: - Coding

extension WindowState: @MainActor Codable {
    enum CodingKeys: String, CodingKey {
        case id, deviceID, projectID, section, showsGlobalMemories, showsInternalSkills, subProjectDashboardID, sidebarVisible,
             inspectorVisible, inspectorWidth, projectStates, globalMemoryStates, internalSkillStates, lastProjectByDevice,
             shownVirtualMachineID, shownImageSetupID, searchVisible, search, sheet, pendingTarget
    }

    /// One entry of `projectStates`.
    private enum EntryKeys: String, CodingKey {
        case deviceID, projectID, state
    }

    // `projectStates` is encoded as an array of `{deviceID, projectID, state}` objects sorted by
    // device and project (docs/ui.md › WindowState).
    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), deviceID: try c.decode(String.self, forKey: .deviceID))
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        section = try c.decodeIfPresent(ProjectSection.self, forKey: .section) ?? .dashboard
        // After the section, which leaves the views.
        showsGlobalMemories = try c.decodeIfPresent(Bool.self, forKey: .showsGlobalMemories) ?? false
        showsInternalSkills = try c.decodeIfPresent(Bool.self, forKey: .showsInternalSkills) ?? false
        // After the project, the section and the views, which leave the sub project's Dashboard. The
        // window checks it once the device's projects are known (docs/ui.md › WindowState).
        subProjectDashboardID = try c.decodeIfPresent(String.self, forKey: .subProjectDashboardID)
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        inspectorVisible = try c.decodeIfPresent(Bool.self, forKey: .inspectorVisible) ?? true
        inspectorWidth = try c.decodeIfPresent(Double.self, forKey: .inspectorWidth) ?? 380
        lastProjectByDevice = try c.decodeIfPresent([String: String].self, forKey: .lastProjectByDevice) ?? [:]
        globalMemoryStates = try c.decodeIfPresent([String: MemoryViewState].self, forKey: .globalMemoryStates) ?? [:]
        internalSkillStates = try c.decodeIfPresent([String: SkillViewState].self, forKey: .internalSkillStates) ?? [:]
        if c.contains(.projectStates) {
            var entries = try c.nestedUnkeyedContainer(forKey: .projectStates)
            while !entries.isAtEnd {
                let entry = try entries.nestedContainer(keyedBy: EntryKeys.self)
                let key = ProjectKey(deviceID: try entry.decode(String.self, forKey: .deviceID),
                                     projectID: try entry.decode(String.self, forKey: .projectID))
                projectStates[key] = try entry.decode(ProjectViewState.self, forKey: .state)
            }
        }
        if decoder.userInfo[WindowState.persistedOnlyKey] as? Bool != true {
            shownVirtualMachineID = try c.decodeIfPresent(UUID.self, forKey: .shownVirtualMachineID)
            shownImageSetupID = try c.decodeIfPresent(UUID.self, forKey: .shownImageSetupID)
            searchVisible = try c.decodeIfPresent(Bool.self, forKey: .searchVisible) ?? false
            search = try c.decodeIfPresent(SearchPanelState.self, forKey: .search) ?? SearchPanelState()
            sheet = try c.decodeIfPresent(WindowSheet.self, forKey: .sheet)
            pendingTarget = try c.decodeIfPresent(NavigationTarget.self, forKey: .pendingTarget)
        }
    }

    func encode(to encoder: Encoder) throws {
        let persistedOnly = encoder.userInfo[WindowState.persistedOnlyKey] as? Bool == true
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encode(section, forKey: .section)
        try c.encode(showsGlobalMemories, forKey: .showsGlobalMemories)
        try c.encode(showsInternalSkills, forKey: .showsInternalSkills)
        try c.encodeIfPresent(subProjectDashboardID, forKey: .subProjectDashboardID)
        try c.encode(sidebarVisible, forKey: .sidebarVisible)
        try c.encode(inspectorVisible, forKey: .inspectorVisible)
        try c.encode(inspectorWidth, forKey: .inspectorWidth)
        var entries = c.nestedUnkeyedContainer(forKey: .projectStates)
        let keys = projectStates.keys.sorted { ($0.deviceID, $0.projectID) < ($1.deviceID, $1.projectID) }
        for key in keys {
            guard let state = projectStates[key] else { continue }
            var entry = entries.nestedContainer(keyedBy: EntryKeys.self)
            try entry.encode(key.deviceID, forKey: .deviceID)
            try entry.encode(key.projectID, forKey: .projectID)
            if persistedOnly, key != activeProjectKey {
                // The other projects keep only the filter of the chat lists (docs/ui.md ›
                // WindowState).
                var persisted = entry.nestedContainer(keyedBy: ProjectViewState.CodingKeys.self, forKey: .state)
                try persisted.encode(state.hidesClosedChats, forKey: .hidesClosedChats)
            } else {
                try entry.encode(state, forKey: .state)
            }
        }
        // Persisted: the entry of the window's device only (docs/ui.md › WindowState).
        try c.encode(persistedOnly ? globalMemoryStates.filter { $0.key == deviceID } : globalMemoryStates, forKey: .globalMemoryStates)
        try c.encode(persistedOnly ? internalSkillStates.filter { $0.key == deviceID } : internalSkillStates, forKey: .internalSkillStates)
        try c.encode(lastProjectByDevice, forKey: .lastProjectByDevice)
        guard !persistedOnly else { return }
        try c.encodeIfPresent(shownVirtualMachineID, forKey: .shownVirtualMachineID)
        try c.encodeIfPresent(shownImageSetupID, forKey: .shownImageSetupID)
        try c.encode(searchVisible, forKey: .searchVisible)
        try c.encode(search, forKey: .search)
        try c.encodeIfPresent(sheet, forKey: .sheet)
        try c.encodeIfPresent(pendingTarget, forKey: .pendingTarget)
    }
}

// MARK: - ProjectViewState

/// The view state of one project in one window (docs/ui.md › WindowState). It stays in memory
/// while its window is open, so returning to a project restores its selections and its unsaved
/// editors.
struct ProjectViewState {
    /// Selected tickets; a single selected ticket shows its detail.
    var selectedTicketIDs: Set<String> = []
    var selectedBundleID: String?
    /// Selected chats of the Chats section; a single selected chat shows its view beside the list.
    var selectedChatIDs: Set<String> = []
    /// Project chat shown in the inspector; nil shows the most recently updated project chat, or a
    /// draft when the project has none.
    var inspectorChatID: String?
    /// True while the inspector shows a draft opened with New Chat.
    var inspectorShowsDraft = false
    /// Items open in the shown section that the user unlinked from the inspector chat, as
    /// `LinkedItemRef.key` values; an item leaves it as soon as it is no longer open.
    var unlinkedItems: Set<String> = []
    /// Open editor tabs in order, with their buffers. Buffers are never encoded: a tab encodes its
    /// path only, and docBuffer and skillEditor are left out (docs/architecture.md › WindowState).
    var editorTabs: [EditorTabState] = []
    /// Project path of the selected editor tab.
    var selectedEditorPath: String?
    /// Project path of the selected doc (`DocEntry.path`).
    var selectedDocPath: String?
    var docMode: DocMode = .preview
    var selectedWebTabID: String?
    var selectedSkillName: String?
    /// Selected row of the Memories section: a memory's file name, `MEMORY.md`, or
    /// `<ancestor id>/<file name>` for an inherited memory.
    var selectedMemoryFile: String?
    /// The tab of the Builds section (docs/builds.md › Layout).
    var buildsTab: BuildsTab = .runs
    /// Selected workflow run of the Builds section, by id (docs/builds.md › Run details).
    var selectedRunID: Int?
    /// Selected release of the Builds section, by tag (docs/builds.md › Release details).
    var selectedReleaseTag: String?
    /// The release asset downloads of the Builds section that run, or that saved their file since
    /// the section was last shown (docs/builds.md › Downloads); never encoded.
    var buildsDownloads: BuildsDownloads = [:]

    // Fields added by the section documents (docs/ui.md › WindowState, first rule).

    /// Expanded folders of the Code section's file tree (docs/code-editor.md › File tree).
    var expandedCodeFolders: Set<String> = []
    /// Selected row of the file tree (docs/code-editor.md › File tree).
    var selectedTreePath: String?
    /// The selected doc's buffer (docs/documentation-viewer.md › Opening a doc); never encoded.
    var docBuffer: EditorBuffer?
    /// Expanded folders of the docs tree (docs/documentation-viewer.md › Docs tree).
    var expandedDocFolders: Set<String> = []
    /// The buffer of `openapi/contract.yaml` that the API Explorer shows (docs/openapi.md ›
    /// Explorer view); never encoded.
    var apiExplorerBuffer: EditorBuffer?
    /// The state of the Graph section (docs/graph.md); created when the section first shows; never
    /// encoded.
    var graphState: GraphSectionState?
    /// Filters and sort order of the ticket list, kept per window and project while the window is
    /// open (docs/tickets.md › Ticket list).
    var ticketList = TicketListState()
    /// The tab of the ticket detail (docs/tickets.md › Ticket detail).
    var ticketTab = TicketDetailTab.details
    /// The sort order of the bundle list (docs/tickets.md › Bundles section).
    var bundleList = BundleListState()
    /// The tab of the bundle detail (docs/tickets.md › Bundles section).
    var bundleTab = BundleDetailTab.tickets
    /// The chat shown in the Chats tab of a ticket or bundle, by ticket or bundle id
    /// (docs/tickets.md › Ticket chats and Implement).
    var chatsTabSelection: [String: String] = [:]
    /// The tickets and bundles whose Chats tab shows a draft chat.
    var chatsTabDrafts: Set<String> = []
    /// The chat shown in the Mentioned In tab of a ticket or bundle, by ticket or bundle id
    /// (docs/tickets.md › Mentioned In tab).
    var mentionedInSelection: [String: String] = [:]
    /// The workflow or agent shown in the Chats section in place of the chat view; its chat is
    /// then the only chat of `selectedChatIDs` (docs/chats.md › Where chats appear).
    var selectedChatAgent: ChatAgentSelection?
    /// The workflow or agent shown in the Chats tab of a ticket or bundle in place of the chat
    /// view, by ticket or bundle id.
    var chatsTabAgentSelection: [String: ChatAgentSelection] = [:]
    /// Chats whose ended workflows and agents are unfolded in the chat lists.
    var expandedAgentChats: Set<String> = []
    /// Whether the Chats section and the Chats tabs of tickets and bundles hide closed chats;
    /// persisted for every project the window showed (docs/chats.md › Where chats appear).
    var hidesClosedChats = true
    /// Comment composer drafts by ticket id; an empty draft is removed (docs/tickets.md ›
    /// Comments).
    var commentDrafts: [String: CommentDraft] = [:]
    /// The skill form and the open extra file of the Skills section; never encoded
    /// (docs/skills.md › Editor).
    var skillEditor: SkillEditorState?
    /// The memory form or the `MEMORY.md` text of the Memories section; never encoded
    /// (docs/memories.md › Saving).
    var memoryEditor: MemoryEditorState?
    /// The mode of the Memories editors, kept when the editor closes (docs/memories.md › Memory
    /// editor); not encoded.
    var memoryBodyMode: DocMode = .preview

    /// The editors of this project with unsaved changes: editor tabs in order, the doc buffer, the
    /// skill form and its open extra file, then the memory or `MEMORY.md`.
    @MainActor
    var unsavedEditors: [any UnsavedEditor] {
        var editors: [any UnsavedEditor] = editorTabs.map { $0.buffer }.filter { $0.hasUnsavedChanges }
        if let docBuffer, docBuffer.hasUnsavedChanges { editors.append(docBuffer) }
        editors += skillEditor?.unsavedEditors ?? []
        editors += memoryEditor?.unsavedEditors ?? []
        return editors
    }
}

extension ProjectViewState: @MainActor Codable {
    enum CodingKeys: String, CodingKey {
        case selectedTicketIDs, selectedBundleID, selectedChatIDs, inspectorChatID, inspectorShowsDraft, unlinkedItems, editorTabs,
             selectedEditorPath, selectedDocPath, docMode, selectedWebTabID, selectedSkillName, selectedMemoryFile,
             buildsTab, selectedRunID, selectedReleaseTag, expandedCodeFolders, selectedTreePath, expandedDocFolders, ticketList, ticketTab, bundleList, bundleTab,
             chatsTabSelection, chatsTabDrafts, mentionedInSelection, hidesClosedChats, commentDrafts, selectedChatAgent,
             chatsTabAgentSelection, expandedAgentChats
        /// The single selected chat of a state persisted before `selectedChatIDs`; decoded only.
        case selectedChatID
    }

    @MainActor
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedTicketIDs = Set(try c.decodeIfPresent([String].self, forKey: .selectedTicketIDs) ?? [])
        selectedBundleID = try c.decodeIfPresent(String.self, forKey: .selectedBundleID)
        if let ids = try c.decodeIfPresent([String].self, forKey: .selectedChatIDs) {
            selectedChatIDs = Set(ids)
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .selectedChatID) {
            selectedChatIDs = [legacy]
        }
        inspectorChatID = try c.decodeIfPresent(String.self, forKey: .inspectorChatID)
        inspectorShowsDraft = try c.decodeIfPresent(Bool.self, forKey: .inspectorShowsDraft) ?? false
        unlinkedItems = Set(try c.decodeIfPresent([String].self, forKey: .unlinkedItems) ?? [])
        editorTabs = try c.decodeIfPresent([EditorTabState].self, forKey: .editorTabs) ?? []
        selectedEditorPath = try c.decodeIfPresent(String.self, forKey: .selectedEditorPath)
        selectedDocPath = try c.decodeIfPresent(String.self, forKey: .selectedDocPath)
        docMode = try c.decodeIfPresent(DocMode.self, forKey: .docMode) ?? .preview
        selectedWebTabID = try c.decodeIfPresent(String.self, forKey: .selectedWebTabID)
        selectedSkillName = try c.decodeIfPresent(String.self, forKey: .selectedSkillName)
        selectedMemoryFile = try c.decodeIfPresent(String.self, forKey: .selectedMemoryFile)
        buildsTab = try c.decodeIfPresent(BuildsTab.self, forKey: .buildsTab) ?? .runs
        selectedRunID = try c.decodeIfPresent(Int.self, forKey: .selectedRunID)
        selectedReleaseTag = try c.decodeIfPresent(String.self, forKey: .selectedReleaseTag)
        expandedCodeFolders = Set(try c.decodeIfPresent([String].self, forKey: .expandedCodeFolders) ?? [])
        selectedTreePath = try c.decodeIfPresent(String.self, forKey: .selectedTreePath)
        expandedDocFolders = Set(try c.decodeIfPresent([String].self, forKey: .expandedDocFolders) ?? [])
        ticketList = try c.decodeIfPresent(TicketListState.self, forKey: .ticketList) ?? TicketListState()
        ticketTab = try c.decodeIfPresent(TicketDetailTab.self, forKey: .ticketTab) ?? .details
        bundleList = try c.decodeIfPresent(BundleListState.self, forKey: .bundleList) ?? BundleListState()
        bundleTab = try c.decodeIfPresent(BundleDetailTab.self, forKey: .bundleTab) ?? .tickets
        chatsTabSelection = try c.decodeIfPresent([String: String].self, forKey: .chatsTabSelection) ?? [:]
        chatsTabDrafts = Set(try c.decodeIfPresent([String].self, forKey: .chatsTabDrafts) ?? [])
        mentionedInSelection = try c.decodeIfPresent([String: String].self, forKey: .mentionedInSelection) ?? [:]
        hidesClosedChats = try c.decodeIfPresent(Bool.self, forKey: .hidesClosedChats) ?? true
        commentDrafts = try c.decodeIfPresent([String: CommentDraft].self, forKey: .commentDrafts) ?? [:]
        selectedChatAgent = try c.decodeIfPresent(ChatAgentSelection.self, forKey: .selectedChatAgent)
        chatsTabAgentSelection = try c.decodeIfPresent([String: ChatAgentSelection].self, forKey: .chatsTabAgentSelection) ?? [:]
        expandedAgentChats = Set(try c.decodeIfPresent([String].self, forKey: .expandedAgentChats) ?? [])
    }

    // Sets are encoded as sorted arrays so that the JSON is stable.
    @MainActor
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedTicketIDs.sorted(), forKey: .selectedTicketIDs)
        try c.encodeIfPresent(selectedBundleID, forKey: .selectedBundleID)
        try c.encode(selectedChatIDs.sorted(), forKey: .selectedChatIDs)
        try c.encodeIfPresent(inspectorChatID, forKey: .inspectorChatID)
        try c.encode(inspectorShowsDraft, forKey: .inspectorShowsDraft)
        try c.encode(editorTabs, forKey: .editorTabs)
        try c.encodeIfPresent(selectedEditorPath, forKey: .selectedEditorPath)
        try c.encodeIfPresent(selectedDocPath, forKey: .selectedDocPath)
        try c.encode(docMode, forKey: .docMode)
        try c.encodeIfPresent(selectedWebTabID, forKey: .selectedWebTabID)
        try c.encodeIfPresent(selectedSkillName, forKey: .selectedSkillName)
        try c.encodeIfPresent(selectedMemoryFile, forKey: .selectedMemoryFile)
        try c.encode(buildsTab, forKey: .buildsTab)
        try c.encodeIfPresent(selectedRunID, forKey: .selectedRunID)
        try c.encodeIfPresent(selectedReleaseTag, forKey: .selectedReleaseTag)
        try c.encode(hidesClosedChats, forKey: .hidesClosedChats)
        if encoder.userInfo[WindowState.persistedOnlyKey] as? Bool != true {
            try c.encode(expandedCodeFolders.sorted(), forKey: .expandedCodeFolders)
            try c.encodeIfPresent(selectedTreePath, forKey: .selectedTreePath)
            try c.encode(expandedDocFolders.sorted(), forKey: .expandedDocFolders)
            try c.encode(ticketList, forKey: .ticketList)
            try c.encode(ticketTab, forKey: .ticketTab)
            try c.encode(bundleList, forKey: .bundleList)
            try c.encode(bundleTab, forKey: .bundleTab)
            try c.encode(chatsTabSelection, forKey: .chatsTabSelection)
            try c.encode(chatsTabDrafts.sorted(), forKey: .chatsTabDrafts)
            try c.encode(mentionedInSelection, forKey: .mentionedInSelection)
            try c.encode(commentDrafts, forKey: .commentDrafts)
            try c.encode(unlinkedItems.sorted(), forKey: .unlinkedItems)
            try c.encodeIfPresent(selectedChatAgent, forKey: .selectedChatAgent)
            try c.encode(chatsTabAgentSelection, forKey: .chatsTabAgentSelection)
            try c.encode(expandedAgentChats.sorted(), forKey: .expandedAgentChats)
        }
    }
}

// MARK: - Memories views

/// The state of the Global Memories view for one device (docs/ui.md › WindowState): the fields of
/// the same names of `ProjectViewState`. Only `selectedMemoryFile` is encoded.
struct MemoryViewState {
    /// Selected row: a memory's file name, or `MEMORY.md`.
    var selectedMemoryFile: String?
    /// The memory form or the `MEMORY.md` text shown, with its unsaved changes.
    var memoryEditor: MemoryEditorState?
    /// The mode of the editors, kept when the editor closes.
    var memoryBodyMode: DocMode = .preview
}

extension MemoryViewState: Codable {
    enum CodingKeys: String, CodingKey {
        case selectedMemoryFile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedMemoryFile = try c.decodeIfPresent(String.self, forKey: .selectedMemoryFile)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(selectedMemoryFile, forKey: .selectedMemoryFile)
    }
}

extension WindowState {
    /// The state of a memories view of this window on a device: the Memories section of a project,
    /// from its entry of `projectStates`, or the Global Memories view, from `globalMemoryStates`.
    func memoryViewState(_ scope: MemoryScope, deviceID: String) -> MemoryViewState {
        switch scope {
        case .project(let projectID):
            guard let state = projectStates[ProjectKey(deviceID: deviceID, projectID: projectID)] else { return MemoryViewState() }
            return MemoryViewState(selectedMemoryFile: state.selectedMemoryFile, memoryEditor: state.memoryEditor,
                                   memoryBodyMode: state.memoryBodyMode)
        case .global:
            return globalMemoryStates[deviceID] ?? MemoryViewState()
        }
    }

    /// Changes the state of a memories view of this window on a device, creating its entry when
    /// needed.
    func updateMemoryViewState(_ scope: MemoryScope, deviceID: String, _ change: (inout MemoryViewState) -> Void) {
        switch scope {
        case .project(let projectID):
            let key = ProjectKey(deviceID: deviceID, projectID: projectID)
            var state = projectStates[key] ?? ProjectViewState()
            var memories = MemoryViewState(selectedMemoryFile: state.selectedMemoryFile, memoryEditor: state.memoryEditor,
                                           memoryBodyMode: state.memoryBodyMode)
            change(&memories)
            state.selectedMemoryFile = memories.selectedMemoryFile
            state.memoryEditor = memories.memoryEditor
            state.memoryBodyMode = memories.memoryBodyMode
            projectStates[key] = state
        case .global:
            var state = globalMemoryStates[deviceID] ?? MemoryViewState()
            change(&state)
            globalMemoryStates[deviceID] = state
        }
    }
}

// MARK: - Skills views

/// The view a skill editor belongs to: the Skills section of a project, or the Internal Skills
/// view of the window's device (docs/skills.md › Skills section, › Internal Skills view).
enum SkillsScope: Hashable {
    case project(String)
    case internalSkills

    /// The project of the Skills section; nil for the Internal Skills view.
    var projectID: String? {
        if case .project(let projectID) = self { return projectID }
        return nil
    }
}

/// The state of the Internal Skills view for one device (docs/ui.md › WindowState): the fields of
/// the same names of `ProjectViewState`; the editor keeps the body's mode. Only
/// `selectedSkillName` is encoded.
struct SkillViewState {
    var selectedSkillName: String?
    /// The skill form and the open extra file shown, with their unsaved changes.
    var skillEditor: SkillEditorState?
}

extension SkillViewState: Codable {
    enum CodingKeys: String, CodingKey {
        case selectedSkillName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSkillName = try c.decodeIfPresent(String.self, forKey: .selectedSkillName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(selectedSkillName, forKey: .selectedSkillName)
    }
}

extension WindowState {
    /// The state of a skills view of this window on a device: the Skills section of a project,
    /// from its entry of `projectStates`, or the Internal Skills view, from `internalSkillStates`.
    func skillViewState(_ scope: SkillsScope, deviceID: String) -> SkillViewState {
        switch scope {
        case .project(let projectID):
            guard let state = projectStates[ProjectKey(deviceID: deviceID, projectID: projectID)] else { return SkillViewState() }
            return SkillViewState(selectedSkillName: state.selectedSkillName, skillEditor: state.skillEditor)
        case .internalSkills:
            return internalSkillStates[deviceID] ?? SkillViewState()
        }
    }

    /// Changes the state of a skills view of this window on a device, creating its entry when
    /// needed.
    func updateSkillViewState(_ scope: SkillsScope, deviceID: String, _ change: (inout SkillViewState) -> Void) {
        switch scope {
        case .project(let projectID):
            let key = ProjectKey(deviceID: deviceID, projectID: projectID)
            var state = projectStates[key] ?? ProjectViewState()
            var skills = SkillViewState(selectedSkillName: state.selectedSkillName, skillEditor: state.skillEditor)
            change(&skills)
            state.selectedSkillName = skills.selectedSkillName
            state.skillEditor = skills.skillEditor
            projectStates[key] = state
        case .internalSkills:
            var state = internalSkillStates[deviceID] ?? SkillViewState()
            change(&state)
            internalSkillStates[deviceID] = state
        }
    }

    /// The skill editor of the view the centre column shows: the Internal Skills view's, or the
    /// active project's Skills section's.
    var shownSkillEditor: SkillEditorState? {
        showsInternalSkills ? internalSkillStates[deviceID]?.skillEditor : viewState.skillEditor
    }
}

/// A workflow or an agent of a chat shown in place of the chat view (docs/chats.md › Where chats
/// appear).
enum ChatAgentSelection: Codable, Hashable, Sendable {
    case workflow(chatID: String, workflowID: String)
    case agent(chatID: String, agentID: String)

    var chatID: String {
        switch self {
        case .workflow(let chatID, _), .agent(let chatID, _): return chatID
        }
    }

    /// The tag of its row in a chat list: `workflow:<chat id>:<workflow id>` or
    /// `agent:<chat id>:<agent id>`; a chat row's tag is the chat id.
    var tag: String {
        switch self {
        case .workflow(let chatID, let workflowID): return "workflow:\(chatID):\(workflowID)"
        case .agent(let chatID, let agentID): return "agent:\(chatID):\(agentID)"
        }
    }

    /// The selection of a row tag; nil for a chat row's tag.
    init?(tag: String) {
        let parts = tag.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        switch parts[0] {
        case "workflow": self = .workflow(chatID: parts[1], workflowID: parts[2])
        case "agent": self = .agent(chatID: parts[1], agentID: parts[2])
        default: return nil
        }
    }
}
