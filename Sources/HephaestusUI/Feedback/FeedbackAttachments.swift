// OWNER: ui-skills-feedback — the files the user adds to a feedback: the open panel, drops, ⌘V and
// the chips of the Feedback sheet (docs/feedback.md › Added files).
import AppKit
import HephaestusCore
import Observation

/// The files added to a feedback, in the order they were added. They are read as the composer
/// reads its attachments (`ChatAttachmentFiles`), on the device that shows the sheet, so that
/// Send sends them inside its request (docs/feedback.md › Added files, › Remote windows).
@MainActor @Observable
final class FeedbackAttachments {
    /// The added files, in chip order.
    private(set) var uploads: [AttachmentUpload] = []
    /// The alert of files that were not added: a folder, a file larger than 20 MB or a file that
    /// cannot be read.
    var alert: WindowAlert?
    /// The number of additions whose files are still being read.
    private var pendingReads = 0
    /// The last addition: each one waits for the one before it, so the chips keep the order in
    /// which the files were added.
    @ObservationIgnored private var lastRead: Task<Void, Never>?

    /// True while added files are being read: Send waits for their chips.
    var isReading: Bool {
        pendingReads > 0
    }

    /// Files from the open panel, a drop or ⌘V. A folder, or a file larger than 20 MB, shows its
    /// alert and adds nothing from that drop.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        enqueue { await ChatAttachmentFiles.uploads(from: urls) }
    }

    /// Pasted image data without a file: a PNG named `Pasted Image <yyyy-MM-dd> at <HH.mm.ss>.png`.
    func addPastedImage(_ png: Data, date: Date = Date()) {
        enqueue { ChatAttachmentFiles.pastedImage(png, date: date).map { [$0] } }
    }

    /// ⌘V in the comment field: the files or the image data of the pasteboard are added, and the
    /// result is true; false leaves the pasteboard to be pasted as text.
    func paste(_ pasteboard: NSPasteboard) -> Bool {
        switch ChatAttachmentFiles.pasted(from: pasteboard) {
        case .files(let urls)?:
            add(urls)
            return true
        case .image(let png)?:
            addPastedImage(png)
            return true
        case nil:
            return false
        }
    }

    /// The remove button (×) of a chip.
    func remove(at index: Int) {
        guard uploads.indices.contains(index) else { return }
        uploads.remove(at: index)
    }

    /// Returns once every file added so far is read.
    func settle() async {
        await lastRead?.value
    }

    /// Adds the files that `read` gives, after those of the additions made before, or shows the
    /// alert of its failure.
    private func enqueue(_ read: @escaping () async -> Result<[AttachmentUpload], ChatAttachmentFiles.Problem>) {
        pendingReads += 1
        let previous = lastRead
        lastRead = Task {
            await previous?.value
            switch await read() {
            case .success(let added):
                uploads += added
            case .failure(let problem):
                alert = WindowAlert(title: problem.title, message: problem.message)
            }
            pendingReads -= 1
        }
    }
}
