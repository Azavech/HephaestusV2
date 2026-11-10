import AppKit
import Foundation
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/feedback.md › Added files: the files the user adds to a feedback, read as the composer
/// reads its attachments, and the comment field that takes them from ⌘V.
@MainActor
@Suite("Feedback attachments")
struct FeedbackAttachmentsTests {
    @Test("Added files keep the order in which they were added, also when an earlier file takes longer to read")
    func order() async throws {
        try await withTemporaryFolder { folder in
            let big = try write(Data(count: 4_000_000), named: "trace.bin", in: folder)
            let log = try write(Data("build failed".utf8), named: "build.txt", in: folder)
            let image = try write(Data([0x89, 0x50, 0x4E, 0x47]), named: "window.png", in: folder)
            let files = FeedbackAttachments()
            #expect(!files.isReading)
            files.add([big])
            files.add([log, image])
            files.add([])
            #expect(files.isReading)
            #expect(files.uploads.isEmpty)
            await files.settle()
            #expect(!files.isReading)
            #expect(files.uploads.map(\.name) == ["trace.bin", "build.txt", "window.png"])
            #expect(files.uploads.suffix(2).map(\.contentType) == ["text/plain", "image/png"])
            #expect(files.uploads.map { ChatAttachmentFiles.size(of: $0) } == [4_000_000, 12, 4])
            #expect(files.uploads[1].dataBase64 == Data("build failed".utf8).base64EncodedString())
            #expect(files.uploads.allSatisfy { $0.sourcePath == nil })
            #expect(files.alert == nil)
            // The remove button of a chip.
            files.remove(at: 1)
            files.remove(at: 7)
            #expect(files.uploads.map(\.name) == ["trace.bin", "window.png"])
        }
    }

    @Test("A folder shows `Folders cannot be attached.` and adds nothing from that drop")
    func folder() async throws {
        try await withTemporaryFolder { folder in
            let first = try write(Data("one".utf8), named: "first.txt", in: folder)
            let second = try write(Data("two".utf8), named: "second.txt", in: folder)
            let subfolder = folder.appendingPathComponent("Logs", isDirectory: true)
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
            let files = FeedbackAttachments()
            files.add([first])
            files.add([second, subfolder])
            await files.settle()
            #expect(files.uploads.map(\.name) == ["first.txt"])
            #expect(files.alert?.title == "Folders cannot be attached.")
            #expect(files.alert?.message == "")
        }
    }

    @Test("A file larger than 20 MB shows `<name> is larger than 20 MB.` and is not added")
    func tooLarge() async throws {
        try await withTemporaryFolder { folder in
            let big = folder.appendingPathComponent("capture.mov")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: UInt64(ChatAttachmentFiles.maximumSize + 1))
            try handle.close()
            let files = FeedbackAttachments()
            files.add([big])
            await files.settle()
            #expect(files.uploads.isEmpty)
            #expect(files.alert?.title == "capture.mov is larger than 20 MB.")
            #expect(files.alert?.message == "")
        }
    }

    @Test("Pasted image data without a file becomes `Pasted Image <yyyy-MM-dd> at <HH.mm.ss>.png`, in local time, after the files added before")
    func pastedImage() async throws {
        try await withTemporaryFolder { folder in
            let log = try write(Data(count: 2_000_000), named: "build.txt", in: folder)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 14, minute: 5, second: 7)))
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            let files = FeedbackAttachments()
            files.add([log])
            files.addPastedImage(png, date: date)
            await files.settle()
            #expect(files.uploads.map(\.name) == ["build.txt", "Pasted Image 2026-11-09 at 14.05.07.png"])
            #expect(files.uploads[1].contentType == "image/png")
            #expect(files.uploads[1].dataBase64 == png.base64EncodedString())
        }
    }

    @Test("⌘V adds the files of the pasteboard, else its image data when it holds no text; text is pasted as text")
    func paste() async throws {
        try await withTemporaryFolder { folder in
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("HephaestusUITests-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let tiff = try Self.tiff()
            let files = FeedbackAttachments()

            // Text is left to the field.
            pasteboard.clearContents()
            pasteboard.setString("The lock icon disappears.", forType: .string)
            #expect(!files.paste(pasteboard))

            // Image data next to text, as a copied part of a page, is pasted as text too.
            pasteboard.declareTypes([.string, .tiff], owner: nil)
            pasteboard.setString("The lock icon disappears.", forType: .string)
            pasteboard.setData(tiff, forType: .tiff)
            #expect(!files.paste(pasteboard))

            // Files.
            let log = try write(Data("build failed".utf8), named: "build.txt", in: folder)
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([log as NSURL]))
            #expect(files.paste(pasteboard))

            // Image data without a file.
            pasteboard.declareTypes([.tiff], owner: nil)
            pasteboard.setData(tiff, forType: .tiff)
            #expect(files.paste(pasteboard))

            await files.settle()
            #expect(files.uploads.count == 2)
            #expect(files.uploads.first?.name == "build.txt")
            let pasted = try #require(files.uploads.last)
            #expect(pasted.name.hasPrefix("Pasted Image ") && pasted.name.hasSuffix(".png"))
            #expect(pasted.contentType == "image/png")
            let png = try #require(Data(base64Encoded: pasted.dataBase64 ?? ""))
            #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
            #expect(files.alert == nil)
        }
    }

    @Test("The comment field's editor takes the focus on request, passes ⌘Return, Escape and ⌘V on, and is neither edited nor selected while Send runs")
    func commentEditor() async throws {
        final class Keys {
            var commandReturn = 0
            var escape = 0
            var pastes: [NSPasteboard] = []
        }
        let keys = Keys()
        func editor(focusRequest: Int, isEditable: Bool) -> TicketTextEditor {
            TicketTextEditor(text: .constant("The lock icon disappears."), minLines: 5, maxLines: 5, focusRequest: focusRequest,
                             isEditable: isEditable, textInset: NSSize(width: 4, height: 4),
                             onCommandReturn: { keys.commandReturn += 1 }, onEscape: { keys.escape += 1 },
                             onPaste: { pasteboard in
                                 keys.pastes.append(pasteboard)
                                 return true
                             })
        }
        let host = NSHostingView(rootView: editor(focusRequest: 0, isEditable: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        /// Waits until the hosted editor, laid out again, satisfies `condition`.
        func settles(_ condition: () -> Bool) async -> Bool {
            await eventually {
                host.layoutSubtreeIfNeeded()
                return condition()
            }
        }
        #expect(await settles { Self.textView(in: host) != nil })
        let textView = try #require(Self.textView(in: host))
        #expect(textView.isEditable && textView.isSelectable)
        #expect(textView.textColor == .textColor)
        #expect(window.firstResponder !== textView)

        #expect(textView.textContainerInset == NSSize(width: 4, height: 4))

        host.rootView = editor(focusRequest: 1, isEditable: true)
        #expect(await settles { window.firstResponder === textView })
        // ⌘Return and Escape in the field: Send and Cancel of the sheet.
        let commandReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(textView.performKeyEquivalent(with: commandReturn))
        textView.cancelOperation(nil)
        #expect(keys.commandReturn == 1 && keys.escape == 1)
        // ⌘V with image data alone on the pasteboard: Paste stays enabled, and the owner takes the content.
        let pasteboard = try Self.imagePasteboard()
        defer { pasteboard.releaseGlobally() }
        textView.pasteSource = pasteboard
        #expect(textView.validateUserInterfaceItem(PasteItem()))
        textView.paste(nil)
        #expect(keys.pastes.count == 1 && keys.pastes.first === pasteboard)

        host.rootView = editor(focusRequest: 1, isEditable: false)
        #expect(await settles { !textView.isEditable })
        #expect(!textView.isSelectable)
        #expect(textView.textColor == .disabledControlTextColor)
        #expect(!textView.validateUserInterfaceItem(PasteItem()))

        host.rootView = editor(focusRequest: 1, isEditable: true)
        #expect(await settles { textView.isEditable })
        #expect(textView.isSelectable)
        #expect(textView.textColor == .textColor)
    }

    @Test("The composer's text field keeps Paste enabled for image data alone and makes it an attachment")
    func composerPaste() throws {
        let pasteboard = try Self.imagePasteboard()
        defer { pasteboard.releaseGlobally() }
        let textView = ChatNSTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.pasteSource = pasteboard
        var images: [Data] = []
        var files: [[URL]] = []
        textView.onPasteFiles = { files.append($0) }
        textView.onPasteImage = { images.append($0) }
        #expect(textView.validateUserInterfaceItem(PasteItem()))
        textView.paste(nil)
        #expect(files.isEmpty && images.count == 1)
        #expect(images.first?.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        // A file of the pasteboard is pasted as a file.
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HephaestusUITests-\(UUID().uuidString).txt")
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([file as NSURL]))
        textView.paste(nil)
        #expect(files == [[file]] && images.count == 1)
    }

    @Test("The sheet is as wide as its screenshot area, and as wide as its chat settings row when the row needs more")
    func sheetWidth() {
        /// The size of a column whose chat settings row is `row` points wide.
        func size(row: CGFloat) -> CGSize {
            NSHostingView(rootView: FeedbackSheetColumn(minimumWidth: 480, spacing: 12) {
                Color.clear.frame(height: 20)
                Color.clear.frame(width: row, height: 10)
                    .layoutValue(key: FeedbackSheetColumn.SetsWidth.self, value: true)
                // A wide subview that does not set the width, as the context line.
                Color.clear.frame(width: 700, height: 30)
            }).fittingSize
        }
        #expect(size(row: 430) == CGSize(width: 480, height: 20 + 12 + 10 + 12 + 30))
        #expect(size(row: 480) == CGSize(width: 480, height: 84))
        #expect(size(row: 526) == CGSize(width: 526, height: 84))
    }

    // MARK: Support

    /// The TIFF data of a small image.
    private static func tiff() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.tiffRepresentation)
    }

    /// A pasteboard of its own, never the general one, that holds image data alone; the caller releases it.
    private static func imagePasteboard() throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HephaestusUITests-\(UUID().uuidString)"))
        pasteboard.declareTypes([.tiff], owner: nil)
        pasteboard.setData(try tiff(), forType: .tiff)
        return pasteboard
    }

    private static func textView(in view: NSView) -> TicketNSTextView? {
        if let textView = view as? TicketNSTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    private func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Runs `body` with a new temporary folder and removes it.
    private func withTemporaryFolder(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }
}

/// The Paste command, as a menu item gives it to the validation of its target.
private final class PasteItem: NSObject, NSValidatedUserInterfaceItem {
    var action: Selector? = #selector(NSText.paste(_:))
    var tag = 0
}

/// Waits until a condition holds, at most 60 seconds: the bound only ends a test that fails.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<6000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
