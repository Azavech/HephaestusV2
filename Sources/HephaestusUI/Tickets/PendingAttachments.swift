// OWNER: ui-tickets — files chosen, dropped or pasted before they are sent: folder refusal, pasted
// image names, the 20 MiB limits and the uploads (docs/tickets.md › Adding attachments, › Storage
// and limits).
import AppKit
import Foundation
import HephaestusCore
import UniformTypeIdentifiers

/// A file waiting to be sent with a comment, a ticket or a chat message.
struct PendingAttachment: Identifiable, Hashable {
    enum Source: Hashable {
        /// A file of this Mac, read when it is sent.
        case file(URL)
        /// Pasted image data.
        case data(Data)
    }

    let id = UUID()
    var name: String
    /// The MIME type of the name's extension, or "" to let the engine derive it.
    var contentType: String
    var source: Source

    /// The size in bytes, when known.
    var size: Int? {
        switch source {
        case .data(let data):
            return data.count
        case .file(let url):
            return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
    }

    /// True for the image content types of docs/tickets.md › Showing attachments.
    var isImage: Bool {
        AttachmentKinds.isImage(contentType: contentType)
    }
}

/// Reading files, drops and the pasteboard into pending attachments.
enum PendingAttachments {
    /// The limit of one file and of the files of one request (docs/engine-api.md › Limits).
    static let maxBytes = 20_971_520

    /// The alert of a dropped or pasted folder.
    static let folderAlert = WindowAlert(title: "Folders cannot be attached.", message: "")

    /// The pending attachments of file URLs; nil when one of them is a folder, in which case
    /// nothing of that drop is added and the caller shows `folderAlert`.
    static func fromFiles(_ urls: [URL]) -> [PendingAttachment]? {
        var result: [PendingAttachment] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true {
                return nil
            }
            let name = url.lastPathComponent
            result.append(PendingAttachment(name: name, contentType: mimeType(forName: name), source: .file(url)))
        }
        return result
    }

    /// The files or the image of a pasteboard. `.files` holds nil when a folder was pasted;
    /// `.none` means the pasteboard holds neither files nor image data (text is pasted as text).
    enum PasteContent {
        case files([PendingAttachment]?)
        case none
    }

    static func fromPasteboard(_ pasteboard: NSPasteboard, now: Date = Date()) -> PasteContent {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            return .files(fromFiles(urls))
        }
        if let png = pastedImagePNG(pasteboard) {
            let name = pastedImageName(at: now)
            return .files([PendingAttachment(name: name, contentType: "image/png", source: .data(png))])
        }
        return .none
    }

    /// Image data on the pasteboard that is not a file, as PNG.
    private static func pastedImagePNG(_ pasteboard: NSPasteboard) -> Data? {
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard pasteboard.availableType(from: types) != nil else { return nil }
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// `Pasted Image <yyyy-MM-dd> at <HH.mm.ss>.png`, in local time.
    static func pastedImageName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pasted Image \(formatter.string(from: date)).png"
    }

    /// The MIME type of a file name's extension, or "" when unknown (the engine then uses
    /// `application/octet-stream`).
    static func mimeType(forName name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "" }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? ""
    }

    /// The uploads of pending attachments, read on this Mac and sent as base64 content
    /// (docs/tickets.md › Adding attachments: files added from a remote device travel inside the
    /// request). The 20 MiB limits fail with the engine's messages before any file is read.
    static func uploads(_ items: [PendingAttachment]) async throws -> [AttachmentUpload] {
        var total = 0
        for item in items {
            let size = item.size ?? 0
            if size > maxBytes {
                throw EngineError(.invalid, "\(item.name) is larger than 20 MB.")
            }
            total += size
        }
        if total > maxBytes {
            throw EngineError(.invalid, "The attachments of one request exceed 20 MB.")
        }
        var uploads: [AttachmentUpload] = []
        for item in items {
            let data: Data
            switch item.source {
            case .data(let bytes):
                data = bytes
            case .file(let url):
                do {
                    data = try await Task.detached { try Data(contentsOf: url) }.value
                } catch {
                    throw EngineError(.invalid, "\(url.path) is not a readable file.")
                }
            }
            if data.count > maxBytes {
                throw EngineError(.invalid, "\(item.name) is larger than 20 MB.")
            }
            uploads.append(AttachmentUpload(name: item.name, contentType: item.contentType, dataBase64: data.base64EncodedString()))
        }
        return uploads
    }

    /// An open panel for several files, as a sheet of `window` when there is one.
    @MainActor
    static func chooseFiles(in window: NSWindow?) async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : []
    }
}
