import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/feedback.md › Screenshot preview, › Feedback sheet: the icon that leaves the screenshot
/// out of the feedback, the `screenshot` param of Send and the required comment.
@MainActor
@Suite("Feedback sheet")
struct FeedbackSheetTests {
    @Test("Included: eye with Exclude Screenshot, shown only while the pointer is over the preview")
    func includedIcon() {
        let away = FeedbackScreenshotIcon(captured: true, included: true, hovered: false)
        #expect(away.symbol == "eye")
        #expect(away.label == "Exclude Screenshot")
        #expect(!away.isShown)
        #expect(away.isEnabled)
        let hovered = FeedbackScreenshotIcon(captured: true, included: true, hovered: true)
        #expect(hovered.symbol == "eye")
        #expect(hovered.label == "Exclude Screenshot")
        #expect(hovered.isShown)
        #expect(hovered.isEnabled)
    }

    @Test("Excluded: eye.slash with Include Screenshot, shown wherever the pointer is", arguments: [true, false])
    func excludedIcon(_ hovered: Bool) {
        let icon = FeedbackScreenshotIcon(captured: true, included: false, hovered: hovered)
        #expect(icon.symbol == "eye.slash")
        #expect(icon.label == "Include Screenshot")
        #expect(icon.isShown)
        #expect(icon.isEnabled)
    }

    @Test("A window that could not be captured: eye.slash shown disabled", arguments: [true, false])
    func failedCaptureIcon(_ included: Bool) {
        let icon = FeedbackScreenshotIcon(captured: false, included: included, hovered: false)
        #expect(icon.symbol == "eye.slash")
        #expect(icon.label == "Include Screenshot")
        #expect(icon.isShown)
        #expect(!icon.isEnabled)
    }

    @Test("Send sends the screenshot only while it is included and the window was captured")
    func screenshotUpload() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(FeedbackSheet.screenshotUpload(png: png, included: true)
            == AttachmentUpload(name: "screenshot.png", contentType: "image/png", dataBase64: png.base64EncodedString()))
        #expect(FeedbackSheet.screenshotUpload(png: png, included: false) == nil)
        #expect(FeedbackSheet.screenshotUpload(png: nil, included: true) == nil)
        #expect(FeedbackSheet.screenshotUpload(png: nil, included: false) == nil)
    }

    @Test("A comment of white space and line breaks alone is blank")
    func blankComment() {
        for blank in ["", " ", "   ", "\n", "\t", " \n\t \r\n ", "\u{00A0}"] {
            #expect(FeedbackSheet.isBlank(blank), "\(blank.debugDescription)")
        }
        for comment in ["a", " a ", "\n.\n", "The lock icon disappears."] {
            #expect(!FeedbackSheet.isBlank(comment), "\(comment.debugDescription)")
        }
    }
}
