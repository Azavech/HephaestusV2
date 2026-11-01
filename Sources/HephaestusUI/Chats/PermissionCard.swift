// OWNER: ui-chats — the pinned permission card (docs/chats.md › Pinned permission card).
import HephaestusCore
import SwiftUI

/// The oldest pending permission request of a chat, with `1 of <n>` when several wait.
struct PermissionCard: View {
    @Bindable var model: ChatViewModel
    let request: PermissionRequestItem
    /// The number of pending requests.
    let count: Int

    /// The input preview shows at most 20 lines until Show All.
    static let previewLineLimit = 20

    var body: some View {
        let (server, name) = ToolUseItem.splitToolName(request.toolName)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Claude wants to use \(name)")
                    .font(.headline)
                if let server {
                    ChatMCPBadge(server: server)
                }
                Spacer(minLength: 8)
                if count > 1 {
                    Text("1 of \(count)")
                        .foregroundStyle(.secondary)
                }
            }
            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .foregroundStyle(.secondary)
            }
            preview
            TextField("Message for Claude (optional)", text: $model.denyMessage)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Spacer()
                Button(PermissionDecision.deny.label) {
                    model.answerPermission(request, .deny)
                }
                Button(PermissionDecision.allowAlways.label) {
                    model.answerPermission(request, .allowAlways)
                }
                Button(PermissionDecision.allow.label) {
                    model.answerPermission(request, .allow)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.6)))
        .task(id: request.id) {
            model.permissionShown(request.id)
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled {
                model.permissionArmedID = request.id
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        let segments = PermissionPreview.segments(for: request)
        let shown = model.permissionShowsAll ? (segments, false) : PermissionPreview.truncated(segments, to: Self.previewLineLimit)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown.0.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
            if shown.1 {
                Button("Show All") {
                    model.permissionShowsAll = true
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: PermissionPreview.Segment) -> some View {
        switch segment {
        case .text(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .removed(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
                .background(Color.red.opacity(0.15))
        case .added(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
                .background(Color.green.opacity(0.15))
        case .markdown(let text):
            MarkdownView(markdown: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The badge `MCP · <server>` of an MCP tool.
struct ChatMCPBadge: View {
    let server: String

    var body: some View {
        Text("MCP · \(server)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
    }
}

/// The input preview of a permission request (docs/chats.md › Pinned permission card).
enum PermissionPreview {
    enum Segment: Hashable {
        case text(String)
        case code(String)
        /// `old_string` of an Edit, on a red background.
        case removed(String)
        /// `new_string` of an Edit, on a green background.
        case added(String)
        case markdown(String)

        var text: String {
            switch self {
            case .text(let text), .code(let text), .removed(let text), .added(let text), .markdown(let text): return text
            }
        }

        func with(_ text: String) -> Segment {
            switch self {
            case .text: return .text(text)
            case .code: return .code(text)
            case .removed: return .removed(text)
            case .added: return .added(text)
            case .markdown: return .markdown(text)
            }
        }
    }

    /// `Bash`: `command` in monospace, then `description`; `Write`: `file_path`, then `content` in
    /// monospace; `Edit`: `file_path`, then `old_string` on red and `new_string` on green, in
    /// monospace; `ExitPlanMode`: `plan` as Markdown; `WebFetch`: `url`, then `prompt`; any other
    /// tool: the input as JSON with 2-space indentation, in monospace.
    // DOC-GAP: the table does not give the font of `file_path` and `url`; paths and URLs use SF Mono
    // (docs/ui.md › Principles, Appearance). A tool whose fields are missing shows its JSON.
    static func segments(for request: PermissionRequestItem) -> [Segment] {
        let input = request.input
        var segments: [Segment] = []
        switch request.toolName {
        case "Bash":
            if let command = input.chatString("command") {
                segments.append(.code(command))
                if let description = input.chatString("description"), !description.isEmpty {
                    segments.append(.text(description))
                }
            }
        case "Write":
            if let path = input.chatString("file_path"), let content = input.chatString("content") {
                segments = [.code(path), .code(content)]
            }
        case "Edit":
            if let path = input.chatString("file_path"), let old = input.chatString("old_string"), let new = input.chatString("new_string") {
                segments = [.code(path), .removed(old), .added(new)]
            }
        case "ExitPlanMode":
            if let plan = input.chatString("plan") {
                segments = [.markdown(plan)]
            }
        case "WebFetch":
            if let url = input.chatString("url") {
                segments.append(.code(url))
                if let prompt = input.chatString("prompt"), !prompt.isEmpty {
                    segments.append(.text(prompt))
                }
            }
        default:
            break
        }
        return segments.isEmpty ? [.code(input.chatPrettyJSON)] : segments
    }

    /// The segments cut to `limit` lines in all; true when lines were left out.
    static func truncated(_ segments: [Segment], to limit: Int) -> ([Segment], Bool) {
        var remaining = limit
        var result: [Segment] = []
        for segment in segments {
            guard remaining > 0 else { return (result, true) }
            let lines = segment.text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count <= remaining {
                result.append(segment)
                remaining -= lines.count
            } else {
                result.append(segment.with(lines.prefix(remaining).joined(separator: "\n")))
                return (result, true)
            }
        }
        return (result, false)
    }
}
