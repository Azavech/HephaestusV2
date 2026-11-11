// OWNER: ui-views — the Views section of a Swift application (docs/views.md).
import AppKit
import HephaestusCore
import SwiftUI

/// The views of the active project in a tree of folders, and the previews of the selected view
/// (docs/views.md › Layout).
struct ViewsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        if let state = window.viewsState(of: projectID) {
            ViewsSectionContent(workspace: workspace, projectID: projectID, state: state)
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
    let workspace: DeviceWorkspace
    let projectID: String
    @Bindable var state: ViewsSectionState

    var body: some View {
        SplitPanes(leadingWidth: $state.listWidth, leadingRange: 180...480, minimumTrailingWidth: 300) {
            ViewsList(state: state)
        } trailing: {
            ViewsDetail(state: state)
        }
        .onAppear { state.appear(workspace: workspace, projectID: projectID) }
        .onDisappear { state.disappear() }
    }
}

// MARK: List

private struct ViewsList: View {
    @Bindable var state: ViewsSectionState

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(ViewTree.rows(state.tree, collapsed: state.collapsed)) { row in
                            ViewsListRow(row: row, state: state)
                        }
                    }
                    .padding(.vertical, 6)
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

private struct ViewsDetail: View {
    @Bindable var state: ViewsSectionState

    var body: some View {
        if let view = state.selectedView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(view.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(view.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    if let session = state.session {
                        PreviewStatusLine(session: session)
                    }
                }
                .padding(.horizontal, 12)
                .paneHeaderBar()
                Divider()
                PreviewControls(state: state)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
                if view.previews.isEmpty {
                    VStack(spacing: 6) {
                        Text("No Preview")
                            .font(.headline)
                        Text("\(view.name) has no #Preview.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let session = state.session {
                    PreviewsArea(session: session, settings: state.settings)
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

/// The Width and Height fields, Light / Dark and the Dynamic Type pop-up (docs/views.md ›
/// Preview settings).
private struct PreviewControls: View {
    @Bindable var state: ViewsSectionState

    var body: some View {
        HStack(spacing: 16) {
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
            Spacer(minLength: 0)
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

/// The previews side by side, or what takes their place (docs/views.md › Layout, Build rules).
private struct PreviewsArea: View {
    let session: PreviewSessionModel
    let settings: PreviewSettings

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
        } else if session.previews.allSatisfy({ $0.image == nil }) {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Building the previews…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(session.previews) { preview in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preview.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            PreviewCanvas(image: preview.image) { event in
                                session.send(preview: preview.index, event)
                            }
                            .frame(width: CGFloat(settings.width), height: CGFloat(settings.height))
                            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                        }
                    }
                }
                .padding(20)
            }
            .defaultScrollAnchor(.topLeading)
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
