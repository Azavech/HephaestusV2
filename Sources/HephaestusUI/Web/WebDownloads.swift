// OWNER: ui-web-search — the downloads of a window and the downloads bar (docs/web-tabs.md ›
// Downloads).
import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One download of a window.
@MainActor @Observable
final class WebDownload: NSObject, Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    var fileName = ""
    var destination: URL?
    var received: Int64 = 0
    /// Nil while the total size is unknown.
    var total: Int64?
    var state = State.running

    @ObservationIgnored let download: WKDownload
    @ObservationIgnored weak var owner: WebDownloads?
    @ObservationIgnored private let sourceURL: URL?
    @ObservationIgnored private let pageURL: URL?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var cancelRequested = false

    init(download: WKDownload, pageURL: URL?, owner: WebDownloads) {
        self.download = download
        self.owner = owner
        sourceURL = download.originalRequest?.url
        self.pageURL = pageURL
        fileName = download.originalRequest?.url?.lastPathComponent ?? ""
        super.init()
        download.delegate = self
        let progress = download.progress
        observations = [
            progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
                let received = progress.completedUnitCount
                let total = progress.totalUnitCount
                DispatchQueue.main.async { self?.progressChanged(received: received, total: total) }
            },
            progress.observe(\.totalUnitCount, options: [.new]) { [weak self] progress, _ in
                let received = progress.completedUnitCount
                let total = progress.totalUnitCount
                DispatchQueue.main.async { self?.progressChanged(received: received, total: total) }
            },
        ]
    }

    private func progressChanged(received: Int64, total: Int64) {
        guard state == .running else { return }
        self.received = max(0, received)
        self.total = total > 0 ? total : nil
    }

    /// `Cancel` of the downloads bar, and the window closing.
    func cancel() {
        guard state == .running else { return }
        cancelRequested = true
        state = .cancelled
        download.cancel { _ in }
        owner?.release(self)
    }

    /// `Show in Finder` of a finished download.
    func showInFinder() {
        guard let destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    /// The quarantine attributes of a web download, so that Gatekeeper checks the file when it is
    /// opened.
    private func quarantine(_ file: URL) {
        var properties: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        if let sourceURL {
            properties[kLSQuarantineDataURLKey as String] = sourceURL
        }
        if let pageURL {
            properties[kLSQuarantineOriginURLKey as String] = pageURL
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var url = file
        try? url.setResourceValues(values)
    }
}

extension WebDownload: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let owner, state == .running else {
            completionHandler(nil)
            return
        }
        let name = suggestedFilename.isEmpty ? (response.suggestedFilename ?? fileName) : suggestedFilename
        // Without a Downloads folder WebKit fails the download, and its error shows.
        guard let url = owner.reserveDestination(for: name) else {
            completionHandler(nil)
            return
        }
        destination = url
        fileName = url.lastPathComponent
        if response.expectedContentLength > 0 {
            total = response.expectedContentLength
        }
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let destination {
            quarantine(destination)
        }
        if let total {
            received = total
        }
        state = .finished
        owner?.release(self)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let nsError = error as NSError
        if cancelRequested || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            state = .cancelled
        } else {
            state = .failed(nsError.localizedDescription)
        }
        owner?.release(self)
    }
}

/// The downloads of one window, newest first. They are not stored or synced; they continue while
/// the window shows other sections or projects and are cancelled when it closes.
@MainActor @Observable
final class WebDownloads {
    private(set) var items: [WebDownload] = []
    /// Destination names chosen for downloads that have not finished.
    @ObservationIgnored private var reserved: Set<String> = []

    func start(_ download: WKDownload, pageURL: URL?) {
        items.insert(WebDownload(download: download, pageURL: pageURL, owner: self), at: 0)
    }

    /// `Clear`: removes the finished, failed and cancelled entries.
    func clear() {
        items.removeAll { $0.state != .running }
    }

    var hasFinishedItems: Bool {
        items.contains { $0.state != .running }
    }

    func cancelAll() {
        for item in items {
            item.cancel()
        }
    }

    /// A file in the Downloads folder of this Mac with the suggested name; when that name is taken,
    /// ` (1)`, ` (2)`, … is inserted before the extension.
    func reserveDestination(for suggestedName: String) -> URL? {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let name = Self.safeName(suggestedName)
        let url = Self.uniqueURL(in: folder, name: name) { candidate in
            reserved.contains(candidate.path) || FileManager.default.fileExists(atPath: candidate.path)
        }
        reserved.insert(url.path)
        return url
    }

    func release(_ item: WebDownload) {
        if let destination = item.destination {
            reserved.remove(destination.path)
        }
    }

    /// The name without path separators; WebKit suggests a name already, this keeps it inside the
    /// folder.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // DOC-GAP: docs/web-tabs.md › Downloads does not name a file without a suggested name;
        // WebKit always suggests one, and an empty one becomes `download`.
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "download" : trimmed
    }

    /// `name`, else `base (n).ext` with the first n from 1 that `isTaken` refuses.
    static func uniqueURL(in folder: URL, name: String, isTaken: (URL) -> Bool) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard isTaken(candidate) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 1
        while true {
            let numbered = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            let url = folder.appendingPathComponent(numbered)
            if !isTaken(url) { return url }
            number += 1
        }
    }
}

/// The downloads bar: one row per download, newest first, and `Clear`
/// (docs/web-tabs.md › Downloads).
struct WebDownloadsBar: View {
    let downloads: WebDownloads

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(downloads.items) { item in
                    WebDownloadRow(item: item)
                }
            }
            Spacer(minLength: 8)
            Button("Clear") {
                downloads.clear()
            }
            .disabled(!downloads.hasFinishedItems)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxHeight: 120, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WebDownloadRow: View {
    let item: WebDownload

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(item.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            switch item.state {
            case .running:
                Text(sizeText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel") {
                    item.cancel()
                }
                .buttonStyle(.link)
            case .finished:
                Button("Show in Finder") {
                    item.showInFinder()
                }
                .buttonStyle(.link)
            case .failed(let message):
                Text("Failed: \(message)")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            case .cancelled:
                Text("Cancelled")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    /// `<received> of <total>`, or `<received>` while the total is unknown.
    private var sizeText: String {
        let received = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        guard let total = item.total else { return received }
        return "\(received) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    private var icon: NSImage {
        if item.state == .finished, let destination = item.destination {
            return NSWorkspace.shared.icon(forFile: destination.path)
        }
        let ext = (item.fileName as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}
