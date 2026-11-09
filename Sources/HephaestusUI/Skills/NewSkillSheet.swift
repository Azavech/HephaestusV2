// OWNER: ui-skills-feedback — the New Skill sheet (docs/skills.md › New Skill sheet).
import HephaestusCore
import SwiftUI

/// New Skill: Name, Description and `Enable in <project name>`; Create calls `skills.create`, then
/// `skills.setEnabled` when the checkbox is checked, then selects the new skill and focuses its
/// body in Edit mode (docs/skills.md › New Skill sheet).
struct NewSkillSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    /// The Description field was edited, so its messages show.
    @State private var descriptionEdited = false
    @State private var enable = true
    @State private var isCreating = false
    /// The engine's error, in red under the fields.
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    private var projectName: String {
        workspace.project(projectID)?.name ?? projectID
    }

    private var nameMessage: String? {
        SkillValidation.nameMessage(name, library: workspace.skills)
    }

    private var descriptionMessage: String? {
        SkillValidation.descriptionMessage(description)
    }

    private var canCreate: Bool {
        nameMessage == nil && descriptionMessage == nil && !isCreating && workspace.isConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Skill")
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
                        HStack(alignment: .firstTextBaseline) {
                            if descriptionEdited, let descriptionMessage {
                                ValidationMessage(text: descriptionMessage)
                            }
                            Spacer()
                            Text(SkillValidation.counter(description))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(description.count > SkillValidation.descriptionLimit ? Color.red : Color.secondary)
                        }
                    }
                }
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Enable in \(projectName)", isOn: $enable)
                        .toggleStyle(.checkbox)
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
            // ⌘Return anywhere in the sheet, the Description field included (docs/skills.md ›
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
        guard canCreate else { return }
        isCreating = true
        failure = nil
        let name = name
        let description = description
        let enable = enable
        Task {
            do {
                _ = try await workspace.call(SkillsCreate.self, .init(name: name, description: description))
            } catch {
                failure = errorMessage(error)
                isCreating = false
                return
            }
            var enableError: Error?
            if enable {
                do {
                    _ = try await workspace.call(SkillsSetEnabled.self, .init(projectID: projectID, name: name, enabled: true))
                } catch {
                    enableError = error
                }
            }
            dismiss()
            await SkillActions.select(name, window: window, workspace: workspace, scope: .project(projectID), startEditing: true)
            // A created skill whose enabling failed is still selected, then the failure shows
            // (docs/skills.md › New Skill sheet).
            if let enableError {
                window.alert = .failure("Enable in \(projectName)", enableError)
            }
        }
    }
}
