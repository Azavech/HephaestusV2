// OWNER: ui-memories — the New Memory sheet (docs/memories.md › New Memory sheet).
import HephaestusCore
import SwiftUI

/// New Memory: Name, Description and Type; Create calls `memories.create`, then selects the new
/// memory and focuses its body in Edit mode (docs/memories.md › New Memory sheet).
struct NewMemorySheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    /// The Description field was edited, so its message shows.
    @State private var descriptionEdited = false
    /// No type is selected when the sheet opens.
    @State private var type: MemoryType?
    @State private var isCreating = false
    /// The engine's error, in red under the fields.
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    private var nameMessage: String? {
        MemoryValidation.nameMessage(name, folder: workspace.memoryFolders[projectID])
    }

    private var descriptionMessage: String? {
        MemoryValidation.descriptionMessage(description)
    }

    private var canCreate: Bool {
        nameMessage == nil && descriptionMessage == nil && type != nil && !isCreating && workspace.isConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Memory")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .focused($nameFocused)
                            .accessibilityLabel("Name")
                        // Validated while typing.
                        if !name.isEmpty, let nameMessage {
                            ValidationMessage(text: nameMessage)
                        }
                    }
                }
                GridRow(alignment: .top) {
                    Text("Description")
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        MultilineField(text: $description)
                            .frame(height: 88)
                            .accessibilityLabel("Description")
                        if descriptionEdited, let descriptionMessage {
                            ValidationMessage(text: descriptionMessage)
                        }
                    }
                }
                GridRow {
                    Text("Type")
                    MemoryTypePicker(selection: $type)
                }
            }
            if let failure {
                ValidationMessage(text: failure)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 480)
        .disabled(isCreating)
        .background {
            // ⌘Return anywhere in the sheet, the Description field included (docs/memories.md ›
            // Keyboard).
            Button("Create") {
                create()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCreate)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onChange(of: description) {
            descriptionEdited = true
        }
        .onAppear {
            nameFocused = true
        }
    }

    private func create() {
        guard canCreate, let type else { return }
        isCreating = true
        failure = nil
        let name = name
        let description = description
        Task {
            let memory: Memory
            do {
                memory = try await workspace.call(MemoriesCreate.self, .init(projectID: projectID, name: name, description: description,
                                                                             type: type))
            } catch {
                failure = errorMessage(error)
                isCreating = false
                return
            }
            dismiss()
            await MemoryActions.select(memory.file, window: window, workspace: workspace, projectID: projectID, startEditing: true)
        }
    }
}
