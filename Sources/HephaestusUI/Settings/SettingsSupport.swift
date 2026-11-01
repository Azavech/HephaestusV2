// OWNER: ui-shell — the controls shared by the Settings panes: rows, fields applied on Return or
// focus loss, port fields and `settings.update` calls (docs/ui.md › Settings window).
import HephaestusCore
import SwiftUI

/// `settings.update` on This Mac's engine with the changed key only; returns the error's message,
/// or nil on success. Every client then receives `settings.updated`.
@MainActor
func updateLocalSettings(_ app: AppModel, _ params: SettingsUpdate.Params) async -> String? {
    do {
        _ = try await app.localWorkspace.call(SettingsUpdate.self, params)
        return nil
    } catch {
        return errorMessage(error)
    }
}

/// The layout of a Settings pane: labels on the left, controls on the right.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
            content()
        }
        .padding(20)
        .frame(width: 600, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row of a Settings pane.
struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A text field applied on Return or when it loses the focus. It shows `value` again whenever
/// the stored value changes while it is not focused.
struct CommitTextField: View {
    let title: String
    var prompt: String?
    var monospaced = false
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .labelsHidden()
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .focused($focused)
            .onSubmit {
                commit(text)
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    commit(text)
                }
            }
            .onAppear {
                text = value
            }
            .onChange(of: value) { _, newValue in
                if !focused {
                    text = newValue
                }
            }
    }
}

/// A port number field: 1024 to 65535 and different from the other server's port, checked by
/// the engine. While the port's environment variable is set, the field shows the effective port,
/// is disabled and notes `Set by <variable>`.
struct PortField: View {
    /// `mcpPort` or `syncPort`.
    let key: String
    /// The stored port.
    let stored: Int
    /// The port of the environment variable, when it is set.
    let override: Int?
    let variable: String
    let apply: (Int) async -> String?
    @State private var message: String?

    var body: some View {
        if let override {
            Text(String(override))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Set by \(variable)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            CommitTextField(title: "Port", value: String(stored)) { text in
                commit(text)
            }
            .frame(width: 90)
            FieldMessage(text: message)
        }
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed) else {
            // A value that is not a number gets the engine's message of an out-of-range port
            // (docs/ui.md › Devices, › MCP).
            message = ValidationError.invalid(key, "use a port from 1024 to 65535").message
            return
        }
        guard port != stored else {
            message = nil
            return
        }
        Task {
            message = await apply(port)
        }
    }
}

/// A green, red or grey dot before a line of text.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}
