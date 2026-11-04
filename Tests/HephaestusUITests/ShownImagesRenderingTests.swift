import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Item rendering, › Links, images and files: the `images` item of `show_image`,
/// drawn as Claude's item with its caption bubble and its thumbnails.
@Suite("Shown images rendering")
struct ShownImagesRenderingTests {
    static let created = ISO8601DateFormatter().date(from: "2026-11-03T22:10:04Z")!
    static let chatID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"

    static func image(_ name: String, contentType: String = "image/png") -> HephaestusCore.Attachment {
        let id = UUID()
        return HephaestusCore.Attachment(id: id, name: name, path: "chats/\(chatID)/\(id.uuidString)-\(name)", contentType: contentType, size: 10)
    }

    static func html(_ item: ChatItem, in state: TranscriptState = TranscriptState()) -> String {
        let context = TranscriptRenderContext(projectRootPath: "/Users/example/Developer/Demo", chatIsRunning: false,
                                              displayedQuestion: nil, projectIdentifiers: ["DEMO"],
                                              today: Calendar.autoupdatingCurrent.startOfDay(for: created))
        return TranscriptRenderer.fragment(for: item, in: state, context: context).html
    }

    @Test("With a caption: Claude's caption line, the caption as Markdown in an assistant bubble, then the thumbnails in order")
    func withCaption() throws {
        let icon = Self.image("icon-1024.png")
        let sizes = Self.image("sizes.gif", contentType: "image/gif")
        let item = ChatItem.images(ImagesItem(id: "I1", created: Self.created, caption: "**Preview** of DEMO-1", images: [icon, sizes]))
        let html = Self.html(item)
        let time = ChatFormat.captionTime(Self.created, today: Calendar.autoupdatingCurrent.startOfDay(for: Self.created))
        #expect(html.hasPrefix("<div class=\"msg assistant\"><div class=\"caption\"><span class=\"caption-sender\">Claude</span> "
            + "<span class=\"caption-time\">\(time)</span></div><div class=\"bubble assistant-bubble\""))
        #expect(html.contains("<strong>Preview</strong>"))
        #expect(html.contains("md-id"), "the ticket id of the caption is a link")
        let bubbleEnd = try #require(html.range(of: "<button type=\"button\" class=\"bubble-copy\">Copy</button></div>"))
        let thumbs = String(html[bubbleEnd.upperBound...])
        #expect(thumbs.hasPrefix("<div class=\"attachments\"><img class=\"thumb\""))
        let first = try #require(thumbs.range(of: "data-path=\"\(icon.path)\""))
        let second = try #require(thumbs.range(of: "data-path=\"\(sizes.path)\""))
        #expect(first.lowerBound < second.lowerBound)
        #expect(thumbs.contains("src=\"hephaestus-attachment://attachment/chats/\(Self.chatID)/"))
        #expect(thumbs.contains("title=\"\(ChatFormat.created(Self.created))\""))
        #expect(thumbs.hasSuffix("</div></div>"))
        #expect(TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: TranscriptRenderContext(
            projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)).type == "images")
    }

    @Test("Without a caption: no bubble, the thumbnails follow Claude's caption line")
    func withoutCaption() {
        let icon = Self.image("icon.png")
        let html = Self.html(.images(ImagesItem(id: "I2", created: Self.created, images: [icon])))
        #expect(!html.contains("bubble"))
        #expect(html.contains("</div><div class=\"attachments\"><img class=\"thumb\""))
        #expect(html.contains("alt=\"icon.png\""))
    }

    @Test("The image viewer and the attachment lookup see the shown images among the chat's images, in transcript order")
    func chatImages() {
        let pasted = HephaestusCore.Attachment(id: UUID(), name: "paste.png", path: "chats/\(Self.chatID)/a-paste.png", contentType: "image/png", size: 1)
        let shown = Self.image("icon.png")
        let state = TranscriptState(items: [
            .user(UserItem(id: "U", created: Self.created, text: "Look", attachments: [pasted], sender: "MacBook")),
            .images(ImagesItem(id: "I", created: Self.created, caption: "Icon", images: [shown])),
        ])
        #expect(state.images == [pasted, shown])
        #expect(state.attachment(atPath: shown.path) == shown)
    }
}
