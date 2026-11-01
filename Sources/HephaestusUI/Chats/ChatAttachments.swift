// OWNER: ui-chats — the attachments of the composer: files from the open panel, drops and ⌘V,
// pasted images, the size limit and the chips (docs/chats.md › Composer).
import AppKit
import HephaestusCore
import SwiftUI
import UniformTypeIdentifiers

/// Reading files into `AttachmentUpload` {name, contentType, dataBase64}: on a remote device too,
/// the files are read on the device that shows the window.
enum ChatAttachmentFiles {
    /// 20 MiB per file (docs/engine-api.md › Limits).
    static let maximumSize = 20_971_520

    /// Why files cannot be attached; `message` is the alert's title.
    enum Problem: Error {
        case folder
        case tooLarge(name: String)
        case unreadable(name: String, message: String)

        var title: String {
            switch self {
            case .folder: return "Folders cannot be attached."
            case .tooLarge(let name): return "\(name) is larger than 20 MB."
            case .unreadable: return "Attach failed"
            }
        }

        var message: String {
            switch self {
            case .folder, .tooLarge: return ""
            case .unreadable(_, let message): return message
            }
        }
    }

    /// The MIME type of a file name's extension, `application/octet-stream` when unknown.
    static func contentType(forName name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? Attachment.defaultContentType
    }

    /// Reads files; a folder refuses the whole drop or paste (docs/tickets.md › Adding
    /// attachments), and a file larger than 20 MB is refused with its own alert.
    static func uploads(from urls: [URL]) async -> Result<[AttachmentUpload], Problem> {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                return .failure(.folder)
            }
        }
        var uploads: [AttachmentUpload] = []
        for url in urls {
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > maximumSize {
                return .failure(.tooLarge(name: name))
            }
            let read = await Task.detached(priority: .userInitiated) { () -> Result<String, Problem> in
                do {
                    let data = try Data(contentsOf: url)
                    if data.count > maximumSize {
                        return .failure(.tooLarge(name: name))
                    }
                    return .success(data.base64EncodedString())
                } catch {
                    return .failure(.unreadable(name: name, message: error.localizedDescription))
                }
            }.value
            switch read {
            case .success(let base64):
                uploads.append(AttachmentUpload(name: name, contentType: contentType(forName: name), dataBase64: base64))
            case .failure(let problem):
                return .failure(problem)
            }
        }
        return .success(uploads)
    }

    /// Pasted image data without a file: a PNG named `Pasted Image <yyyy-MM-dd> at <HH.mm.ss>.png`
    /// in local time (docs/tickets.md › Adding attachments).
    static func pastedImage(_ png: Data, date: Date = Date()) -> Result<AttachmentUpload, Problem> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Pasted Image \(formatter.string(from: date)).png"
        guard png.count <= maximumSize else { return .failure(.tooLarge(name: name)) }
        return .success(AttachmentUpload(name: name, contentType: "image/png", dataBase64: png.base64EncodedString()))
    }

    /// The decoded size of an upload.
    static func size(of upload: AttachmentUpload) -> Int {
        guard let base64 = upload.dataBase64 else { return 0 }
        let padding = base64.hasSuffix("==") ? 2 : (base64.hasSuffix("=") ? 1 : 0)
        return max(0, base64.utf8.count / 4 * 3 - padding)
    }

    static func isImage(_ upload: AttachmentUpload) -> Bool {
        let type = upload.contentType.isEmpty ? contentType(forName: upload.name) : upload.contentType
        return ChatAttachmentKind.isImage(type)
    }
}

/// One chip of the composer: a thumbnail for images or a file icon, the name and the size, and a
/// remove button (×).
struct ComposerAttachmentChip: View {
    let upload: AttachmentUpload
    let remove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: fileType))
                        .resizable()
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 0) {
                Text(upload.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ChatFormat.byteCount(ChatAttachmentFiles.size(of: upload)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 160, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(upload.name)")
        }
        .font(.caption)
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        .task(id: upload.name + String(upload.dataBase64?.count ?? 0)) {
            guard ChatAttachmentFiles.isImage(upload), let base64 = upload.dataBase64 else { return }
            let image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let data = Data(base64Encoded: base64) else { return nil }
                return NSImage(data: data)
            }.value
            thumbnail = image
        }
    }

    private var fileType: UTType {
        UTType(filenameExtension: (upload.name as NSString).pathExtension) ?? .data
    }
}
