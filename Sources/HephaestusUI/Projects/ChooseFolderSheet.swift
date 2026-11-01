// OWNER: ui-shell — the Choose Folder sheet over `fs.browse` (docs/projects.md › Picking a folder on a remote device).
import HephaestusCore
import SwiftUI

/// The folder browser of a window showing a remote device: Open Project… and the folder fields of the New Project sheet.
struct ChooseFolderSheet: View {
    /// What the chosen folder is for.
    enum Purpose {
        /// Open Project… on a remote device: the folder is opened with `projects.open`.
        case openProject
        /// A folder field of the New Project or New Sub Project sheet.
        case projectFolder
    }

    let window: WindowState
    let workspace: DeviceWorkspace
    let purpose: Purpose
    /// The value of the field that opened the sheet: the first folder shown when it is set.
    var initialPath: String?
    /// Receives the chosen folder of a `projectFolder` sheet.
    var onChoose: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    private enum Focus: Hashable {
        case goTo, list
    }

    @State private var current: BrowseResult?
    @State private var selection: String?
    @State private var goTo = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var started = false
    @FocusState private var focus: Focus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            pathBar
            HStack(spacing: 8) {
                Button {
                    if let parent = current?.parent {
                        browse(parent)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Up")
                .disabled(current?.parent == nil)
                Button {
                    browse(nil)
                } label: {
                    Image(systemName: "house")
                }
                .help("Home")
                TextField("Go to", text: $goTo, prompt: Text("/Users/example/Developer"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .focused($focus, equals: .goTo)
                    .onSubmit(goToTypedPath)
            }
            folderList
            FieldMessage(text: failure)
            SheetButtonRow(defaultTitle: purpose == .openProject ? "Open" : "Choose", defaultEnabled: current != nil,
                           returnPressesDefault: focus == nil, cancel: { dismiss() }, confirm: choose)
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .task {
            guard !started else { return }
            started = true
            if let initialPath, !initialPath.isEmpty {
                browse(initialPath)
            } else {
                browse(nil)
            }
        }
    }

    /// `Choose a Folder on <device name>`, or `Open a Project on <device name>` for Open Project….
    private var title: String {
        switch purpose {
        case .openProject: return "Open a Project on \(workspace.deviceName)"
        case .projectFolder: return "Choose a Folder on \(workspace.deviceName)"
        }
    }

    // MARK: Path bar

    /// The components of the current folder's path as buttons, from `/`, with a spinner while a
    /// call is in flight.
    private var pathBar: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        if index > 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button(component.name) {
                            browse(component.path)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(.body, design: .monospaced))
                    }
                }
            }
            if loading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(height: 22)
    }

    /// `/` then each component with the path up to it.
    private var components: [(name: String, path: String)] {
        guard let path = current?.path else { return [] }
        var result: [(name: String, path: String)] = [("/", "/")]
        var partial = ""
        for part in path.split(separator: "/") {
            partial += "/" + part
            result.append((String(part), partial))
        }
        return result
    }

    // MARK: Folder list

    private var folderList: some View {
        List(selection: $selection) {
            ForEach(current?.entries ?? [], id: \.path) { entry in
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.accentColor)
                    Text(entry.name)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if entry.hasProject {
                        Text("Project")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
                .tag(entry.path)
            }
        }
        .focused($focus, equals: .list)
        .contextMenu(forSelectionType: String.self) { _ in
            EmptyView()
        } primaryAction: { paths in
            if let path = paths.first {
                browse(path)
            }
        }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            browse(selection)
            return .handled
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Actions

    /// Return in the Go to field browses the typed absolute path.
    private func goToTypedPath() {
        let path = goTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        browse(path)
    }

    /// Calls `fs.browse`; the previous list stays visible while the call is in flight, and a
    /// failed call shows its message under the list without changing the current folder.
    private func browse(_ path: String?) {
        loading = true
        Task {
            defer { loading = false }
            do {
                let result = try await workspace.call(FSBrowse.self, FSBrowse.Params(path: path))
                current = result
                selection = nil
                failure = nil
            } catch {
                failure = errorMessage(error)
            }
        }
    }

    /// Choose or Open: the selected row's path, or the current folder when no row is selected.
    private func choose() {
        guard let folder = selection ?? current?.path else { return }
        switch purpose {
        case .projectFolder:
            onChoose?(folder)
            dismiss()
        case .openProject:
            dismiss()
            Task {
                await ProjectFlows.open(folder: folder, window: window, workspace: workspace)
            }
        }
    }
}
