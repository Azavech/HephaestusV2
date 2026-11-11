// OWNER: ui-views — the Views section of a Swift application (docs/views.md).
import AppKit
import HephaestusCore
import SwiftUI

/// The views of the active project in a tree of folders, the editor of the selected view's file and
/// its previews (docs/views.md › Layout). The section's state is the window's `sectionCommands`
/// while it shows.
struct ViewsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        if let state = window.viewsState(of: projectID) {
            ViewsSectionContent(window: window, workspace: workspace, projectID: projectID, state: state, devices: window.app?.previewDevices)
        } else {
            Color.clear
                .onAppear { _ = window.ensureViewsState(of: projectID) }
        }
    }
}

extension WindowState {
    /// The state of the Views section of a project in this window; nil until the section first
    /// shows.
    func viewsState(of projectID: String) -> ViewsSectionState? {
        projectStates[ProjectKey(deviceID: deviceID, projectID: projectID)]?.viewsState
    }

    /// The state of the Views section of a project in this window, created when it has none.
    func ensureViewsState(of projectID: String) -> ViewsSectionState {
        if let state = viewsState(of: projectID) {
            return state
        }
        let state = ViewsSectionState(appearance: ViewsSectionState.currentAppearance)
        updateViewState(of: projectID) { $0.viewsState = state }
        return state
    }

    /// True while the active project's sidebar shows the Views row: View ▸ Views is enabled
    /// (docs/views.md › Visibility).
    var showsViews: Bool {
        guard let projectID, let workspace else { return false }
        return workspace.project(projectID)?.type == .swiftApplication
    }

    /// Selects Dashboard when the section is the Views of a project that is not a Swift
    /// application (docs/views.md › Visibility).
    func leaveHiddenViews(in workspace: DeviceWorkspace) {
        guard section == .views, workspace.deviceID == deviceID, let projectID,
              let project = workspace.project(projectID), project.type != .swiftApplication else { return }
        section = .dashboard
    }
}

private struct ViewsSectionContent: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Bindable var state: ViewsSectionState
    /// The devices of this Mac's `devices.json` (docs/views.md › Devices file).
    let devices: PreviewDevicesModel?

    var body: some View {
        // The editor and the previews keep at least 180 pt each (docs/views.md › Layout).
        SplitPanes(leadingWidth: $state.listWidth, leadingRange: 180...480, minimumTrailingWidth: 361) {
            ViewsList(state: state) {
                window.sheet = .newView(projectID: projectID, folder: state.newViewFolder)
            }
        } trailing: {
            ViewsDetail(window: window, workspace: workspace, state: state, devices: devices)
        }
        .onAppear {
            window.sectionCommands = state
            state.syncDevices(devices?.devices ?? [])
            state.appear(workspace: workspace, projectID: projectID, window: window)
        }
        .onDisappear {
            if window.sectionCommands === state {
                window.sectionCommands = nil
            }
            state.disappear()
        }
        .onChange(of: devices?.devices ?? []) { _, list in state.syncDevices(list) }
    }
}

// MARK: List

private struct ViewsList: View {
    @Bindable var state: ViewsSectionState
    /// Opens the New View sheet.
    let newView: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Views")
                    .font(.headline)
                Spacer()
                if let views = state.views {
                    Text(String(views.count))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // docs/views.md › New View sheet.
                Button(action: newView) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New View…")
                .accessibilityLabel("New View…")
            }
            .padding(.horizontal, 12)
            .paneHeaderBar()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let views = state.views {
            if views.isEmpty {
                VStack(spacing: 6) {
                    Text("No Views")
                        .font(.headline)
                    Text("This project declares no SwiftUI, AppKit or UIKit view.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(ViewTree.rows(state.tree, collapsed: state.collapsed)) { row in
                                ViewsListRow(row: row, state: state)
                                    .id(row.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    // The row of the view the New View sheet created (docs/views.md › New View sheet).
                    .task(id: state.scrollTarget) {
                        guard let target = state.scrollTarget else { return }
                        await Task.yield()
                        proxy.scrollTo(target)
                        state.scrollTarget = nil
                    }
                }
            }
        } else if let error = state.listError {
            VStack(spacing: 10) {
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") { state.retry() }
            }
            .padding()
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the views…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ViewsListRow: View {
    let row: ViewTreeRow
    let state: ViewsSectionState

    /// The indentation of one level, in points.
    static let indentation: CGFloat = 14

    var body: some View {
        switch row.node.kind {
        case .folder(let path, let name):
            let collapsed = state.collapsed.contains(path)
            Button {
                state.toggle(folder: path)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8 + CGFloat(row.depth) * Self.indentation)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .view(let view):
            let selected = state.selection == ViewSelection(view)
            Button {
                state.select(view)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(view.kind))
                        .foregroundStyle(selected ? Color.white : Color.accentColor)
                        .frame(width: 16)
                    Text(view.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8 + CGFloat(row.depth) * Self.indentation + 16)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : Color.clear).padding(.horizontal, 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(view.path):\(view.line)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    /// The symbol of a view's kind (docs/views.md › Folder tree).
    static func symbol(_ kind: ViewKind) -> String {
        switch kind {
        case .swiftUI: return "swift"
        case .appKit: return "macwindow"
        case .uiKit: return "iphone"
        }
    }
}

// MARK: Detail

/// The editor of the view's file beside the previews, or the previews alone while the editor holds
/// no file (docs/views.md › Layout).
private struct ViewsDetail: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    @Bindable var state: ViewsSectionState
    let devices: PreviewDevicesModel?

    var body: some View {
        if let editor = state.editor {
            FractionSplitPanes(fraction: $state.editorFraction, minimumWidth: 180) {
                ViewEditorPane(workspace: workspace, state: state, editor: editor)
            } trailing: {
                PreviewsPane(window: window, workspace: workspace, state: state, devices: devices)
            }
        } else {
            PreviewsPane(window: window, workspace: workspace, state: state, devices: devices)
        }
    }
}

/// The pane header with the file's project path and `●` while it has unsaved changes, then the
/// code editor of the Code section with its banner (docs/views.md › Editor).
private struct ViewEditorPane: View {
    let workspace: DeviceWorkspace
    @Bindable var state: ViewsSectionState
    let editor: EditorBuffer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(editor.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(editor.path)
                if editor.isDirty {
                    Text("●")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .paneHeaderBar()
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            CodeEditorView(buffer: editor, workspace: workspace)
                .overlay(alignment: .top) {
                    GoToLineAnchor(isPresented: $state.goToLineShown) {
                        editor.loadedTextController
                    }
                }
        }
        .background(Color(nsColor: EditorTheme.background))
    }
}

/// The pane header of the previews, the controls bar and the previews of the selected view.
private struct PreviewsPane: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    @Bindable var state: ViewsSectionState
    let devices: PreviewDevicesModel?

    /// `Create Preview` needs what Send needs besides the text: the window's device connected and
    /// its Claude CLI available (docs/views.md › Create Preview).
    private var canAskClaude: Bool {
        let status = workspace.claudeStatus
        return workspace.isConnected && status?.available == true && status?.checking == false
    }

    var body: some View {
        if let view = state.selectedView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(view.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let session = state.session {
                        PreviewStatusLine(session: session)
                    }
                }
                .padding(.horizontal, 12)
                .paneHeaderBar()
                Divider()
                PreviewControls(state: state, devices: devices)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
                if view.previews.isEmpty {
                    VStack(spacing: 6) {
                        Text("No Preview")
                            .font(.headline)
                        Text("\(view.name) has no #Preview.")
                            .foregroundStyle(.secondary)
                        Button("Create Preview") {
                            window.sendFromInspector(ViewsSectionState.createPreviewMessage(view))
                        }
                        .disabled(!canAskClaude)
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let session = state.session {
                    PreviewsArea(session: session, settings: state.settings, viewName: view.name)
                } else {
                    Color.clear
                }
            }
        } else {
            VStack(spacing: 6) {
                Text("No View Selected")
                    .font(.headline)
                Text("Select a view in the list.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// `Building… n/m`, `Built at HH:mm:ss`, `Build failed`, `The previews stopped` (docs/views.md ›
/// Status line).
private struct PreviewStatusLine: View {
    let session: PreviewSessionModel

    var body: some View {
        Group {
            switch session.state {
            case .building, nil:
                Text(session.progress.map { "Building… \($0)" } ?? "Building…")
                    .foregroundStyle(.secondary)
            case .running:
                if let builtAt = session.builtAt {
                    Text("Built at \(Self.time(builtAt))")
                        .foregroundStyle(.secondary)
                }
            case .buildFailed:
                Text("Build failed")
                    .foregroundStyle(.red)
            case .stopped:
                Text("The previews stopped")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// The Width and Height fields, Light / Dark, the Dynamic Type pop-up, Portrait / Landscape and
/// the device button (docs/views.md › Preview settings).
private struct PreviewControls: View {
    @Bindable var state: ViewsSectionState
    let devices: PreviewDevicesModel?
    @State private var showsDevices = false

    var body: some View {
        // The orientation and the device button go to a second line when one is too narrow, and
        // the two lines scroll when the pane is narrower still (docs/views.md › Layout).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                macControls
                deviceControls
                Spacer(minLength: 0)
            }
            twoLines
            ScrollView(.horizontal, showsIndicators: false) {
                twoLines
            }
        }
    }

    private var twoLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                macControls
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                deviceControls
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var macControls: some View {
        SizeField(title: "Width", value: state.settings.width) { value in
            state.settings.width = value
            state.settingsChanged()
        }
        SizeField(title: "Height", value: state.settings.height) { value in
            state.settings.height = value
            state.settingsChanged()
        }
        Picker("Appearance", selection: Binding(get: { state.settings.appearance }, set: { appearance in
            state.settings.appearance = appearance
            state.settingsChanged()
        })) {
            Text("Light").tag(PreviewAppearance.light)
            Text("Dark").tag(PreviewAppearance.dark)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Picker("Dynamic Type", selection: Binding(get: { state.settings.dynamicTypeSize }, set: { size in
            state.settings.dynamicTypeSize = size
            state.settingsChanged()
        })) {
            ForEach(DynamicTypeSize.allCases, id: \.self) { size in
                Text(size.title).tag(size)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    @ViewBuilder
    private var deviceControls: some View {
        Picker("Orientation", selection: Binding(get: { state.settings.orientation }, set: { orientation in
            state.settings.orientation = orientation
            state.settingsChanged()
        })) {
            Text("Portrait").tag(PreviewOrientation.portrait)
            Text("Landscape").tag(PreviewOrientation.landscape)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Button {
            showsDevices.toggle()
        } label: {
            Image(systemName: "ipad.and.iphone")
        }
        .help("Devices")
        .accessibilityLabel("Devices")
        .popover(isPresented: $showsDevices, arrowEdge: .bottom) {
            if let devices {
                DevicesPopover(model: devices, state: state)
            }
        }
    }
}

/// A field of whole points from 50 to 2000: its value is taken on Return or when it loses the
/// focus; a value out of the range takes its nearest bound, a text that is not a number gives the
/// previous value back.
private struct SizeField: View {
    let title: String
    let value: Int
    let commit: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .fixedSize()
            TextField(title, text: $text)
                .labelsHidden()
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { apply() }
                }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { _, newValue in text = String(newValue) }
    }

    private func apply() {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else {
            text = String(value)
            return
        }
        let clamped = min(max(number, PreviewSettings.sizeRange.lowerBound), PreviewSettings.sizeRange.upperBound)
        text = String(clamped)
        if clamped != value { commit(clamped) }
    }
}

/// The previews side by side in one row, grouped by device, the Mac's first, or what takes their
/// place (docs/views.md › Layout, Devices side by side, Build rules).
private struct PreviewsArea: View {
    let session: PreviewSessionModel
    let settings: PreviewSettings
    let viewName: String

    /// The previews of one device, nil for the Mac.
    struct Group: Identifiable {
        var device: String?
        var previews: [PreviewImage]
        var id: String { device ?? "" }
    }

    var groups: [Group] {
        var groups: [Group] = []
        for preview in session.previews {
            if let last = groups.indices.last, groups[last].device == preview.device {
                groups[last].previews.append(preview)
            } else {
                groups.append(Group(device: preview.device, previews: [preview]))
            }
        }
        return groups
    }

    var body: some View {
        if let error = session.startError, session.state == nil {
            Text(error)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.state == .buildFailed || session.state == .stopped {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(session.messages.enumerated()), id: \.offset) { _, line in
                        Self.message(line)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .defaultScrollAnchor(.topLeading)
        } else if session.state == .running, session.previews.isEmpty {
            VStack(spacing: 6) {
                Text("No Device Checked")
                    .font(.headline)
                Text("Check a device with the device button to preview \(viewName).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.previews.allSatisfy({ $0.image == nil }) {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Building the previews…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let groups = self.groups
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 40) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                if groups.count > 1 || group.device != nil {
                                    Text(heading(group.device))
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                HStack(alignment: .top, spacing: 20) {
                                    ForEach(group.previews) { preview in
                                        cell(preview)
                                    }
                                }
                            }
                        }
                    }
                    // The errors of the platform whose build failed (docs/views.md › Build rules).
                    if !session.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(session.messages.enumerated()), id: \.offset) { _, line in
                                Self.message(line)
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            .defaultScrollAnchor(.topLeading)
        }
    }

    /// The device of a group, from the settings.
    func device(_ name: String?) -> HephaestusCore.PreviewDevice? {
        name.flatMap { name in settings.devices.first { $0.name == name } }
    }

    /// `Mac · 400 × 300 pt`, `iPhone 18 Pro · 402 × 874 pt · wC hR`.
    func heading(_ name: String?) -> String {
        guard let name else { return "Mac · \(settings.width) × \(settings.height) pt" }
        guard let device = device(name) else { return name }
        let size = device.size(in: settings.orientation)
        return "\(name) · \(size.width) × \(size.height) pt · \(device.sizeClasses(in: settings.orientation).notation)"
    }

    func size(_ preview: PreviewImage) -> CGSize {
        guard let device = device(preview.device) else { return CGSize(width: settings.width, height: settings.height) }
        let size = device.size(in: settings.orientation)
        return CGSize(width: size.width, height: size.height)
    }

    func cell(_ preview: PreviewImage) -> some View {
        let size = size(preview)
        return VStack(alignment: .leading, spacing: 6) {
            Text(preview.title)
                .font(.subheadline)
                .lineLimit(1)
            PreviewCanvas(image: preview.image) { event in
                session.send(preview: preview.index, device: preview.device, event)
            }
            .frame(width: size.width, height: size.height)
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .overlay {
                if preview.image == nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    /// An error line with its path in the secondary colour.
    static func message(_ line: String) -> Text {
        if let range = line.range(of: ": error: ") {
            return Text("\(Text(line[..<range.lowerBound]).foregroundStyle(.secondary))\(Text(line[range.lowerBound...]))")
        }
        return Text(line)
    }
}
