// OWNER: ui-code-docs — Quick Look of a binary file's temporary copy (docs/code-editor.md › Large
// and binary files).
import AppKit
import Quartz

/// Writes a file's bytes to `<temporary folder>/HephaestusV2/Files/<UUID>/<name>` on the Mac that
/// shows the window and opens the copy in Quick Look. It controls the panel from the responder
/// chain of the window it was opened from.
@MainActor
final class QuickLookPresenter: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPresenter()

    private var url: URL?
    private weak var hostWindow: NSWindow?

    func show(data: Data, name: String) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephaestusV2", isDirectory: true)
            .appendingPathComponent("Files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(name.isEmpty ? "file" : name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            NSSound.beep()
            return
        }
        url = file
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, hostWindow !== window {
            removeFromChain()
            nextResponder = window.nextResponder
            window.nextResponder = self
            hostWindow = window
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func removeFromChain() {
        if let hostWindow, hostWindow.nextResponder === self {
            hostWindow.nextResponder = nextResponder
        }
        hostWindow = nil
        nextResponder = nil
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        url != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        removeFromChain()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            url.map { $0 as NSURL }
        }
    }
}
