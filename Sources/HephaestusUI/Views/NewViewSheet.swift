// OWNER: ui-views — the New View sheet of the Views section and the file it writes
// (docs/views.md › New View sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// New View: a name and a folder of the project; Create writes `<name>.swift` with a SwiftUI view
/// and its `#Preview`, then selects the view in the list.
struct NewViewSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folderText: String
    @State private var nameEdited = false
    @State private var message: String?
    @State private var isCreating = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    init(window: WindowState, workspace: DeviceWorkspace, projectID: String, folder: String) {
        self.window = window
        self.workspace = workspace
        self.projectID = projectID
        _folderText = State(initialValue: NewViewFile.folderText(folder))
    }

    private var typeName: String? { NewViewFile.typeName(name) }
    private var folder: String? { NewViewFile.folder(folderText) }

    /// `/`, then every folder of the list of views in the order of the list.
    private var folderItems: [String] {
        ["/"] + (window.viewsState(of: projectID)?.folders ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New View")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .accessibilityLabel("Name")
                            .onChange(of: name) {
                                nameEdited = true
                                message = nil
                            }
                        if let text = message ?? (nameEdited && typeName == nil ? "Use a name such as ProfileView." : nil) {
                            ValidationMessage(text: text)
                        }
                    }
                }
                GridRow {
                    Text("Folder")
                    VStack(alignment: .leading, spacing: 4) {
                        FolderComboBox(text: $folderText, items: folderItems)
                            .accessibilityLabel("Folder")
                            // The box gives SwiftUI no baseline: its text is centred in it.
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + FolderComboBox.baselineBelowCenter }
                        if folder == nil {
                            ValidationMessage(text: "Use a folder such as Sources/App, or / for the project root.")
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(typeName == nil || folder == nil || isCreating || !workspace.isConnected)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { nameFocused = true }
        // docs/views.md › New View sheet, step 4.
        .alert("Create failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// Writes the file, then has the list select the new view.
    private func create() async {
        guard let typeName, let folder, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        let path: String
        do {
            path = try await NewViewFile.create(name: typeName, folder: folder, projectID: projectID, workspace: workspace)
        } catch let error as EngineError where error.code == .conflict {
            message = "\(NewViewFile.path(name: typeName, folder: folder)) already exists."
            return
        } catch {
            failure = errorMessage(error)
            return
        }
        dismiss()
        window.ensureViewsState(of: projectID).reveal(path: path, name: typeName)
    }
}

/// The rules of the New View sheet and the file it writes (docs/views.md › New View sheet, › New
/// view's file).
enum NewViewFile {
    /// The name of the view typed: trimmed, without a `.swift` at its end in any case; nil when it
    /// is not a Swift type name of `A`–`Z`, `a`–`z`, digits and `_`, not starting with a digit,
    /// other than `_` alone.
    static func typeName(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".swift") {
            name.removeLast(".swift".count)
        }
        guard let first = name.unicodeScalars.first, name != "_" else { return nil }
        func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || scalar == "_"
        }
        guard isLetter(first) else { return nil }
        return name.unicodeScalars.allSatisfy { isLetter($0) || ("0"..."9").contains($0) } ? name : nil
    }

    /// The project path of the folder typed: trimmed, without the `/` at its start and its end,
    /// `""` for the root; nil when a component is empty, `.` or `..`.
    static func folder(_ text: String) -> String? {
        var folder = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while folder.hasPrefix("/") { folder.removeFirst() }
        while folder.hasSuffix("/") { folder.removeLast() }
        guard !folder.isEmpty else { return "" }
        let valid = folder.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
        return valid ? String(folder) : nil
    }

    /// The folder as the field shows it: `/` for the root.
    static func folderText(_ folder: String) -> String {
        folder.isEmpty ? "/" : folder
    }

    /// The project path of the new file.
    static func path(name: String, folder: String) -> String {
        ProjectPaths.join(folder, name + ".swift")
    }

    /// The text of the file of a view named `name`.
    static func text(name: String) -> String {
        """
        import SwiftUI

        struct \(name): View {
            var body: some View {
                Text("Hello, World!")
            }
        }

        #Preview {
            \(name)()
        }

        """
    }

    /// `files.create` of the file, with its missing folders, then `files.write` of its text;
    /// returns its project path. A file that exists fails with `conflict`.
    static func create(name: String, folder: String, projectID: String, workspace: DeviceWorkspace) async throws -> String {
        let path = path(name: name, folder: folder)
        _ = try await workspace.call(FilesCreate.self, FilesCreate.Params(projectID: projectID, path: path, isDirectory: false))
        _ = try await workspace.call(FilesWrite.self, FilesWrite.Params(projectID: projectID, path: path, text: text(name: name)))
        return path
    }
}

/// The Folder field: a combo box whose list holds the folders of the list of views; the user
/// picks one or types any project path.
private struct FolderComboBox: NSViewRepresentable {
    @Binding var text: String
    let items: [String]

    /// The distance from the centre of the box to the baseline of its text.
    static var baselineBelowCenter: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return (font.ascender + font.descender) / 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = false
        box.completes = true
        box.numberOfVisibleItems = 12
        box.delegate = context.coordinator
        box.setAccessibilityLabel("Folder")
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        box.addItems(withObjectValues: items)
        context.coordinator.items = items
        box.stringValue = text
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if context.coordinator.items != items {
            context.coordinator.items = items
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if box.stringValue != text, box.currentEditor() == nil {
            box.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        var items: [String] = []

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            text.wrappedValue = box.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let item = box.itemObjectValue(at: box.indexOfSelectedItem) as? String else { return }
            text.wrappedValue = item
        }
    }
}
