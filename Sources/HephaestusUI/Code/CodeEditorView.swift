// OWNER: ui-code-docs — the code editor of one tab with its banner and notices, and the Go to Line
// popover (docs/code-editor.md › Editor, › Large and binary files, › Banners, › Go to line).
import AppKit
import HephaestusCore
import HephaestusText
import SwiftUI

/// The editor of one buffer: the banner, then the text editor or the notice of a file that cannot
/// be edited.
struct CodeEditorView: View {
    let buffer: EditorBuffer
    let workspace: DeviceWorkspace
    /// The text of a missing file: `File <path> was not found.` or `Doc <path> was not found.`.
    var notFoundKind = "File"

    var body: some View {
        VStack(spacing: 0) {
            EditorBannerView(buffer: buffer)
            switch buffer.content {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: EditorTheme.background))
            case .text:
                EditorTextHostView(host: buffer, pendingReveal: buffer.pendingReveal, language: buffer.language,
                                   isEditable: !buffer.isReadOnly)
                    .id(ObjectIdentifier(buffer))
            case .binary(let size):
                BinaryFileNotice(buffer: buffer, size: size)
            case .tooLarge(let size):
                EditorNotice(symbol: nil, title: "\(buffer.name) is too large to open (\(ByteSize.text(size))).")
            case .failed(let message):
                VStack(spacing: 10) {
                    Text("The file could not be opened.")
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button("Try Again") {
                        buffer.retry()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notFound:
                NotFoundView(kind: notFoundKind, id: buffer.path)
            }
        }
    }
}

/// A centered notice of the editor area.
struct EditorNotice: View {
    let symbol: String?
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `<name> is a binary file (<size>).` with `Quick Look`.
private struct BinaryFileNotice: View {
    let buffer: EditorBuffer
    let size: Int

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("\(buffer.name) is a binary file (\(ByteSize.text(size))).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Quick Look") {
                if let data = buffer.binaryData {
                    QuickLookPresenter.shared.show(data: data, name: buffer.name)
                }
            }
            .disabled(buffer.binaryData == nil)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// File-style byte counts (`ByteCountFormatter`, `.file`).
enum ByteSize {
    static func text(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The banner above the editor: changed on disk, deleted on disk, or the large-file banner
/// (docs/code-editor.md › Banners). 32 pt high.
struct EditorBannerView: View {
    let buffer: EditorBuffer
    /// False where the editor is not shown (the Docs section's Preview mode).
    var showsLargeFileBanner = true

    var body: some View {
        if let banner = buffer.banner {
            HStack(spacing: 8) {
                switch banner {
                case .changedOnDisk:
                    Text("This file changed on disk.")
                    Spacer()
                    Button("Reload") { buffer.reload() }
                    Button("Keep Mine") { buffer.keepMine() }
                case .deletedOnDisk:
                    Text("This file was deleted on disk.")
                    Spacer()
                    Button("Save") {
                        Task { try? await buffer.save() }
                    }
                    Button("Close") { buffer.closeWithoutSaving() }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .systemYellow).opacity(0.18))
            Divider()
        } else if showsLargeFileBanner, buffer.isReadOnly, buffer.content == .text {
            HStack {
                Text("This file is larger than 2 MB and is open read-only.")
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(.background.secondary)
            Divider()
        }
    }
}

// MARK: - Text view host

/// Shows a host's text view. The values are read by the parent so that their changes reach
/// `updateNSView`.
struct EditorTextHostView: NSViewRepresentable {
    let host: any EditorTextHost
    var pendingReveal: EditorReveal?
    var language: CodeLanguage
    var isEditable: Bool

    func makeNSView(context: Context) -> EditorContainerView {
        let view = EditorContainerView()
        view.show(host.textController.scrollView)
        return view
    }

    func updateNSView(_ view: EditorContainerView, context: Context) {
        let controller = host.textController
        view.show(controller.scrollView)
        controller.syncWithHost()
    }

    static func dismantleNSView(_ view: EditorContainerView, coordinator: ()) {
        view.removeContent()
    }
}

/// The view that holds a host's scroll view; the scroll view moves between containers when a tab
/// is shown again.
final class EditorContainerView: NSView {
    private weak var content: NSView?

    func show(_ view: NSView) {
        guard content !== view || view.superview !== self else { return }
        content?.removeFromSuperview()
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        content = view
    }

    func removeContent() {
        if let content, content.superview === self {
            content.removeFromSuperview()
        }
        content = nil
    }
}

/// The editor for a text that is not a project file buffer, such as a skill's body or extra file.
struct SourceEditorView: View {
    let model: EditorTextModel

    var body: some View {
        EditorTextHostView(host: model, pendingReveal: model.pendingReveal, language: model.language,
                           isEditable: model.isEditorEditable)
            .id(ObjectIdentifier(model))
    }
}

// MARK: - Go to Line

/// ⌘L: `Go to Line`, a field accepting digits with the placeholder `1–<number of lines>`. Return
/// goes to the line; an empty field beeps; Escape closes (docs/code-editor.md › Go to line).
struct GoToLinePopover: View {
    let lineCount: Int
    let go: (Int) -> Void
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Go to Line")
                .font(.headline)
            TextField("1–\(lineCount)", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($focused)
                .onChange(of: text) { _, newValue in
                    let digits = newValue.filter { ("0"..."9").contains($0) }
                    if digits != newValue {
                        text = digits
                    }
                }
                .onSubmit {
                    guard let number = Int(text) else {
                        NSSound.beep()
                        return
                    }
                    go(number)
                }
                .onExitCommand(perform: close)
        }
        .padding(12)
        .onAppear {
            focused = true
        }
    }
}

/// The anchor of the Go to Line popover at the top of an editor.
struct GoToLineAnchor: View {
    @Binding var isPresented: Bool
    let controller: () -> EditorTextController?

    var body: some View {
        Color.clear
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                GoToLinePopover(lineCount: controller()?.lineCount ?? 1) { number in
                    isPresented = false
                    let target = controller()
                    target?.goToLine(number)
                    // The popover gives the focus back when it closes; the editor keeps it.
                    Task { @MainActor in
                        target?.focus()
                    }
                } close: {
                    isPresented = false
                }
            }
    }
}
