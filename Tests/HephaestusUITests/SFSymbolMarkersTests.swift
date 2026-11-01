import AppKit
import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Links, images and files, › Item rendering: SF Symbol markers in the transcript,
/// drawn from the symbols of this Mac.
@Suite("SF Symbol markers in chats")
struct SFSymbolMarkersTests {
    static let known = "line.3.horizontal.decrease.circle"
    static let unknown = "no.such.symbol.heph"
    static let created = Date(timeIntervalSince1970: 1_800_000_000)

    static func symbolHTML(_ name: String) -> String {
        "<span class=\"md-symbol\"><span class=\"md-symbol-icon\" data-symbol=\"\(name)\"></span>\(name)</span>"
    }

    func html(_ item: ChatItem) -> String {
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)
        return TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
    }

    @Test("This Mac has the known symbol and not the unknown one")
    func availability() {
        #expect(SFSymbols.isAvailable(Self.known))
        #expect(!SFSymbols.isAvailable(Self.unknown))
        #expect(!SFSymbols.isAvailable(""))
    }

    @Test("A marker of a known symbol renders as the symbol image followed by its name in user, assistant and thinking bubbles")
    func knownInBubbles() {
        let text = "Filter ![](sf:\(Self.known)) on"
        let items: [ChatItem] = [
            .user(UserItem(id: "u", created: Self.created, text: text, sender: "MacBook")),
            .assistant(AssistantItem(id: "a", created: Self.created, text: text, messageID: "m")),
            .thinking(ThinkingItem(id: "t", created: Self.created, text: text)),
        ]
        for item in items {
            #expect(html(item).contains("<p>Filter \(Self.symbolHTML(Self.known)) on</p>"), "\(item)")
        }
        #expect(TranscriptRenderer.streamHTML(kind: .text, text: text,
                                              context: TranscriptRenderContext(projectRootPath: nil, chatIsRunning: true, displayedQuestion: nil))
            .contains(Self.symbolHTML(Self.known)))
    }

    @Test("A marker of an unknown name shows its text unchanged")
    func unknownInBubbles() {
        let text = "Filter ![](sf:\(Self.unknown)) on"
        let rendered = html(.assistant(AssistantItem(id: "a", created: Self.created, text: text, messageID: "m")))
        #expect(rendered.contains("<p>Filter ![](sf:\(Self.unknown)) on</p>"))
        #expect(!rendered.contains("md-symbol"))
    }

    @Test("The Questions card draws markers in question texts, option lines and answers")
    func questionsCard() {
        let setID = UUID()
        let question = Question(label: "A", question: "Which icon? ![](sf:\(Self.known))",
                                options: [QuestionOption(label: "Filter ![](sf:\(Self.known))", description: "Like ![](sf:\(Self.unknown))"),
                                          QuestionOption(label: "None")],
                                recommended: "None")
        let item = QuestionsItem(id: setID.uuidString, created: Self.created, questionSetID: setID, questions: [question],
                                 answers: ["A": "![](sf:\(Self.known))"], completed: true)
        let rendered = html(.questions(item))
        #expect(rendered.contains("<p>A. Which icon? \(Self.symbolHTML(Self.known))</p>"))
        #expect(rendered.contains("<li>Filter \(Self.symbolHTML(Self.known)) — Like ![](sf:\(Self.unknown))</li>"))
        #expect(rendered.contains("<div class=\"answer\">Answer: \(Self.symbolHTML(Self.known))</div>"))
    }

    @Test("hephaestus-symbol answers a PNG of a known symbol and fails for an unknown name")
    @MainActor
    func schemeHandler() throws {
        let url = try #require(URL(string: "hephaestus-symbol://symbol/\(Self.known)"))
        #expect(SymbolSchemeHandler.name(of: URLRequest(url: url)) == Self.known)
        #expect(SymbolSchemeHandler.name(of: URLRequest(url: try #require(URL(string: "hephaestus-symbol://other/star")))) == nil)
        #expect(SymbolSchemeHandler.name(of: URLRequest(url: try #require(URL(string: "hephaestus-symbol://symbol/")))) == nil)
        let png = try #require(SFSymbols.png(Self.known))
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide > 48 && image.pixelsHigh > 48)
        // The circle of the symbol reaches every quarter of the image.
        func drawn(_ xs: Range<Int>, _ ys: Range<Int>) -> Bool {
            xs.contains { x in ys.contains { y in (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 } }
        }
        let (w, h) = (image.pixelsWide, image.pixelsHigh)
        #expect(drawn(0..<w / 2, 0..<h / 2) && drawn(w / 2..<w, 0..<h / 2) && drawn(0..<w / 2, h / 2..<h) && drawn(w / 2..<w, h / 2..<h))
        #expect(SFSymbols.png(Self.unknown) == nil)
        let response = try #require(SymbolSchemeHandler.response(url: url, byteCount: png.count))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
    }
}
