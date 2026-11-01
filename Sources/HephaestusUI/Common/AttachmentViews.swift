// OWNER: ui-tickets — attachment thumbnails and chips (docs/tickets.md › Showing attachments).
import AppKit
import HephaestusCore
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// The thumbnail of an image attachment, or the chip of another file; a click and Space open the
/// image viewer or Quick Look. `onRemove` adds Remove… to the context menu (ticket attachments
/// only); its owner asks for confirmation.
struct AttachmentThumbnail: View {
    let attachment: Attachment
    let workspace: DeviceWorkspace
    let projectID: String
    var onRemove: (() -> Void)?

    @Environment(AppModel.self) private var app
    @State private var image: NSImage?
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isImage {
                thumbnail
            } else {
                chip
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: focused ? 2 : 0)
        }
        .onTapGesture {
            focused = true
            open()
        }
        .onKeyPress(.space) {
            open()
            return .handled
        }
        .contextMenu {
            Button("Open") { open() }
            Button("Open With Default App") { openWithDefaultApp() }
            Button("Save As…") { saveAs() }
            if workspace.isLocal {
                Button("Show in Finder") { showInFinder() }
            }
            if let onRemove {
                Divider()
                Button("Remove…", action: onRemove)
            }
        }
        .help(attachment.name)
    }

    private var isImage: Bool {
        AttachmentKinds.isImage(contentType: attachment.contentType)
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: thumbnailWidth(image), height: 96)
                } else if failed {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, height: 96)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 96, height: 96)
                }
            }
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(attachment.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 192)
        }
        .padding(3)
        .task(id: attachment.path) {
            await loadImage()
        }
    }

    /// 96 pt high, at most 192 pt wide, with the aspect ratio kept.
    private func thumbnailWidth(_ image: NSImage) -> CGFloat {
        guard image.size.height > 0 else { return 96 }
        return min(192, max(1, 96 * image.size.width / image.size.height))
    }

    private func loadImage() async {
        do {
            let data = try await AttachmentStore.shared.data(path: attachment.path, projectID: projectID, workspace: workspace)
            if let decoded = NSImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }

    // MARK: Chip

    private var chip: some View {
        HStack(spacing: 6) {
            Image(nsImage: AttachmentKinds.icon(forName: attachment.name))
                .resizable()
                .frame(width: 20, height: 20)
            Text(attachment.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(AttachmentKinds.sizeText(attachment.size))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    // MARK: Actions

    /// A click or Space: the image viewer for images, Quick Look on a temporary copy otherwise.
    private func open() {
        if isImage {
            app.openImageViewer(.stored(deviceID: workspace.deviceID, projectID: projectID, path: attachment.path))
        } else {
            let window = NSApp.keyWindow
            withTemporaryCopy { url in
                QuickLookResponder.show(url, in: window)
            }
        }
    }

    private func openWithDefaultApp() {
        withTemporaryCopy { url in
            NSWorkspace.shared.open(url)
        }
    }

    private func saveAs() {
        let window = NSApp.keyWindow
        Task {
            guard let data = try? await AttachmentStore.shared.data(path: attachment.path, projectID: projectID, workspace: workspace) else {
                NSSound.beep()
                return
            }
            await AttachmentFiles.saveAs(name: attachment.name, data: data, window: window)
        }
    }

    private func showInFinder() {
        guard let rootPath = workspace.project(projectID)?.rootPath else { return }
        AttachmentFiles.showInFinder(rootPath: rootPath, dataPath: attachment.path)
    }

    private func withTemporaryCopy(_ action: @escaping @MainActor (URL) -> Void) {
        let attachment = attachment
        Task {
            do {
                let data = try await AttachmentStore.shared.data(path: attachment.path, projectID: projectID, workspace: workspace)
                let url = try AttachmentFiles.temporaryCopy(id: attachment.id.uuidString, name: attachment.name, data: data)
                action(url)
            } catch {
                NSSound.beep()
            }
        }
    }
}

// MARK: - Kinds

/// Content types, icons and sizes of attachments.
enum AttachmentKinds {
    /// The image content types of docs/tickets.md › Showing attachments.
    static let imageContentTypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/heic", "image/heif", "image/tiff", "image/bmp", "image/webp",
    ]

    static func isImage(contentType: String) -> Bool {
        imageContentTypes.contains(contentType.lowercased())
    }

    /// The icon of the file type of a name.
    @MainActor
    static func icon(forName name: String) -> NSImage {
        let ext = (name as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }

    /// A file-style byte count, for example `1.2 MB`.
    static func sizeText(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Content

/// The content of stored attachments read with `attachments.read`, cached in memory: attachments
/// never change. At most 64 MB stay cached, the least recently used first out.
@MainActor
final class AttachmentStore {
    static let shared = AttachmentStore()

    private struct Key: Hashable {
        var deviceID: String
        var projectID: String
        var path: String
    }

    private var entries: [Key: Data] = [:]
    private var order: [Key] = []
    private var total = 0
    private var inFlight: [Key: Task<Data, Error>] = [:]
    private let limit = 64 * 1024 * 1024

    /// The bytes of a stored file of a project (`attachments/…` or `chats/…`).
    func data(path: String, projectID: String, workspace: DeviceWorkspace) async throws -> Data {
        let key = Key(deviceID: workspace.deviceID, projectID: projectID, path: path)
        if let data = entries[key] {
            touch(key)
            return data
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { @MainActor () throws -> Data in
            let content = try await workspace.call(AttachmentsRead.self, AttachmentsRead.Params(projectID: projectID, path: path))
            guard let data = Data(base64Encoded: content.dataBase64) else {
                throw EngineError(.internal, "The attachment content cannot be decoded.")
            }
            return data
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        store(data, for: key)
        return data
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func store(_ data: Data, for key: Key) {
        guard data.count <= limit else { return }
        if let old = entries[key] {
            total -= old.count
        }
        entries[key] = data
        total += data.count
        touch(key)
        while total > limit, let oldest = order.first {
            order.removeFirst()
            total -= entries.removeValue(forKey: oldest)?.count ?? 0
        }
    }
}

// MARK: - Files

/// Temporary copies, Save As…, Show in Finder.
@MainActor
enum AttachmentFiles {
    /// `<temporary folder>/HephaestusV2/Attachments/<attachment id>/<name>`.
    static func temporaryCopy(id: String, name: String, data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephaestusV2", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        let url = folder.appendingPathComponent(safeName.isEmpty ? "file" : safeName)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A save panel with the attachment's name.
    static func saveAs(name: String, data: Data, window: NSWindow?) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            _ = await AlertPresenter.present(alert, on: window)
        }
    }

    /// Shows a stored file of a project of This Mac in Finder.
    static func showInFinder(rootPath: String, dataPath: String) {
        let url = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(".hephaestus", isDirectory: true)
            .appendingPathComponent(dataPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// The Quick Look controller of a window: inserted after the window in its responder chain, so
/// the shared preview panel finds it (docs/tickets.md › Showing attachments: Quick Look on a
/// temporary copy).
final class QuickLookResponder: NSResponder, QLPreviewPanelDataSource {
    private var items: [URL] = []

    /// Shows `url` in the Quick Look panel for `window`.
    @MainActor
    static func show(_ url: URL, in window: NSWindow?) {
        let responder: QuickLookResponder
        if let window {
            var next = window.nextResponder
            var found: QuickLookResponder?
            while let current = next {
                if let match = current as? QuickLookResponder {
                    found = match
                    break
                }
                next = current.nextResponder
            }
            if let found {
                responder = found
            } else {
                responder = QuickLookResponder()
                responder.nextResponder = window.nextResponder
                window.nextResponder = responder
            }
        } else {
            responder = QuickLookResponder()
        }
        responder.items = [url]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.reloadData()
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !items.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self {
            panel.dataSource = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}
