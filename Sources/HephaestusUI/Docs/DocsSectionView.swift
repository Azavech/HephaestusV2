// OWNER: ui-code-docs — the Docs section: docs tree and viewer in Preview, Edit or Split mode (docs/documentation-viewer.md › Layout, › Modes).
import AppKit
import HephaestusCore
import SwiftUI

/// The Docs section of the active project (`ProjectViewState.selectedDocPath`, `docMode`, `docBuffer`); a selected doc that does not exist shows `NotFoundView(kind: "Doc", id:)`.
struct DocsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        let commands = DocsSectionCommands.of(window: window, workspace: workspace, projectID: projectID)
        let state = FileActions.viewState(window, projectID)
        @Bindable var layout = CodeDocsStore.shared.entry(window: window, projectID: projectID).layout
        SplitPanes(leadingWidth: $layout.docsTreeWidth, leadingRange: 180...400, minimumTrailingWidth: 360) {
            DocsTreeView(window: window, workspace: workspace, projectID: projectID)
        } trailing: {
            DocsViewer(window: window, workspace: workspace, projectID: projectID, commands: commands, layout: layout)
        }
        .onAppear {
            window.sectionCommands = commands
            syncBuffer()
        }
        .onDisappear {
            if window.sectionCommands === commands {
                window.sectionCommands = nil
            }
        }
        .onChange(of: state.selectedDocPath) {
            syncBuffer()
        }
    }

    /// The Docs section holds one buffer: the selected doc's (docs/documentation-viewer.md ›
    /// Opening a doc). A new selection gets a new buffer, read with `files.read`.
    private func syncBuffer() {
        let state = FileActions.viewState(window, projectID)
        guard let path = state.selectedDocPath else {
            if let buffer = state.docBuffer {
                buffer.detach()
                window.updateViewState(of: projectID) { $0.docBuffer = nil }
            }
            return
        }
        if let buffer = state.docBuffer, buffer.path == path {
            buffer.load(workspace: workspace, projectID: projectID, window: window)
            return
        }
        state.docBuffer?.detach()
        let buffer = EditorBuffer(path: path, role: .doc)
        window.updateViewState(of: projectID) { $0.docBuffer = buffer }
        buffer.load(workspace: workspace, projectID: projectID, window: window)
    }
}

/// The viewer: header, banner and the doc in its mode, or an empty state
/// (docs/documentation-viewer.md › Layout, › Empty states).
private struct DocsViewer: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Bindable var commands: DocsSectionCommands
    @Bindable var layout: SectionLayout

    var body: some View {
        let state = FileActions.viewState(window, projectID)
        let tree = CodeDocsStore.shared.docsTree(window: window, workspace: workspace, projectID: projectID)
        Group {
            if let path = state.selectedDocPath {
                if let buffer = state.docBuffer, buffer.path == path {
                    VStack(spacing: 0) {
                        header(buffer, tree: tree, mode: state.docMode)
                        Divider()
                        EditorBannerView(buffer: buffer, showsLargeFileBanner: state.docMode != .preview)
                        content(buffer, mode: state.docMode)
                    }
                } else {
                    spinner
                }
            } else if let error = tree.error {
                VStack(spacing: 8) {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { tree.reload() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let docs = tree.docs {
                if !tree.folderExists {
                    noDocsFolder(tree)
                } else if docs.isEmpty {
                    noDocs(tree)
                } else {
                    Text("Select a doc")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                spinner
            }
        }
        .background(Color(nsColor: EditorTheme.background))
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The doc's path relative to the docs folder, `●` while the buffer has unsaved changes, and
    /// the mode control. 36 pt high.
    private func header(_ buffer: EditorBuffer, tree: DocsTreeModel, mode: DocMode) -> some View {
        HStack(spacing: 6) {
            Text(tree.relativePath(buffer.path))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(buffer.path)
            if buffer.isDirty {
                Text("●")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { mode }, set: { newMode in
                window.updateViewState(of: projectID) { $0.docMode = newMode }
            })) {
                ForEach(DocMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(buffer.content != .text)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func content(_ buffer: EditorBuffer, mode: DocMode) -> some View {
        switch buffer.content {
        case .loading:
            spinner
        case .notFound:
            NotFoundView(kind: "Doc", id: buffer.path)
        case .binary, .tooLarge:
            EditorNotice(symbol: nil, title: "\(buffer.name) is not a UTF-8 text file.")
        case .failed(let message):
            // DOC-GAP: docs/documentation-viewer.md › Empty states gives no text for a doc whose
            // read fails; the code editor's failure notice is shown.
            VStack(spacing: 10) {
                Text("The file could not be opened.")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { buffer.retry() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text:
            switch mode {
            case .preview:
                preview(buffer)
            case .edit:
                editor(buffer)
            case .split:
                FractionSplitPanes(fraction: $layout.docSplitFraction, minimumWidth: 180) {
                    editor(buffer)
                } trailing: {
                    preview(buffer)
                }
            }
        }
    }

    private func preview(_ buffer: EditorBuffer) -> some View {
        DocPreviewView(buffer: buffer, workspace: workspace, projectID: projectID, window: window)
    }

    private func editor(_ buffer: EditorBuffer) -> some View {
        EditorTextHostView(host: buffer, pendingReveal: buffer.pendingReveal, language: buffer.language,
                           isEditable: !buffer.isReadOnly)
            .id(ObjectIdentifier(buffer))
            .overlay(alignment: .top) {
                GoToLineAnchor(isPresented: $commands.goToLineShown) {
                    buffer.loadedTextController
                }
            }
    }

    private func noDocsFolder(_ tree: DocsTreeModel) -> some View {
        let projectName = workspace.project(projectID)?.name ?? projectID
        return VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Docs Folder")
                .font(.title3)
            Text("\(projectName) has no folder “\(tree.docsPath)”.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Create Folder") {
                    Task {
                        do {
                            _ = try await workspace.call(FilesCreate.self, FilesCreate.Params(projectID: projectID, path: tree.docsPath,
                                                                                              isDirectory: true))
                            tree.reload()
                        } catch {
                            window.alert = .failure("Create Folder", error)
                        }
                    }
                }
                Button("Project Settings…") {
                    window.sheet = .projectSettings(projectID: projectID)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noDocs(_ tree: DocsTreeModel) -> some View {
        VStack(spacing: 10) {
            Text("No Docs")
                .font(.title3)
            Text("Markdown files in “\(tree.docsPath)” appear here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Doc") {
                DocActions.newDoc(in: tree.docsPath, window: window, projectID: projectID)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Menu commands

/// The menu commands of the Docs section: Save and Go to Line (docs/ui.md › Menus and keyboard
/// shortcuts). Markdown has no line comments, so Toggle Comment stays disabled.
@MainActor @Observable
final class DocsSectionCommands: SectionCommandHandler {
    let projectID: String
    @ObservationIgnored private weak var window: WindowState?
    @ObservationIgnored private weak var workspace: DeviceWorkspace?
    /// The Go to Line popover is shown.
    var goToLineShown = false

    private init(window: WindowState, workspace: DeviceWorkspace, projectID: String) {
        self.window = window
        self.workspace = workspace
        self.projectID = projectID
    }

    static func of(window: WindowState, workspace: DeviceWorkspace, projectID: String) -> DocsSectionCommands {
        let entry = CodeDocsStore.shared.entry(window: window, projectID: projectID)
        if let commands = entry.docsCommands, commands.workspace === workspace { return commands }
        let commands = DocsSectionCommands(window: window, workspace: workspace, projectID: projectID)
        entry.docsCommands = commands
        return commands
    }

    private var buffer: EditorBuffer? {
        guard let window else { return nil }
        let state = FileActions.viewState(window, projectID)
        guard let buffer = state.docBuffer, buffer.path == state.selectedDocPath else { return nil }
        return buffer
    }

    /// The doc buffer when its editor has the focus.
    private var focusedBuffer: EditorBuffer? {
        guard let window, let buffer, buffer.content == .text, buffer.hasEditorFocus,
              FileActions.viewState(window, projectID).docMode != .preview else { return nil }
        return buffer
    }

    var canSave: Bool { buffer?.canSave ?? false }

    func save() {
        guard let buffer, buffer.canSave else { return }
        Task { try? await buffer.save() }
    }

    var canGoToLine: Bool { focusedBuffer != nil }

    func goToLine() {
        guard focusedBuffer != nil else { return }
        goToLineShown = true
    }

    var canToggleComment: Bool {
        guard let buffer = focusedBuffer, !buffer.isReadOnly else { return false }
        return EditorTextOps.commentPrefix(language: buffer.language) != nil
    }

    func toggleComment() {
        guard canToggleComment, let buffer = focusedBuffer else { return }
        buffer.textController.toggleComment()
    }
}
