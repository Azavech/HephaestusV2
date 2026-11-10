import AppKit
import Foundation
import HephaestusCore
import Testing
import WebKit
@testable import HephaestusUI

/// docs/chats.md › Tool cards, › Streaming bubbles: a spinner turns without restarting when its
/// `Preparing tool call…` card updates and when its tool card is redrawn.
@MainActor
@Suite("Spinner continuity")
struct SpinnerContinuityTests {
    /// Bounds the waits; only a failing test reaches it (docs/development.md › Test rules).
    static let waitLimit: Duration = .seconds(60)
    /// How far, in milliseconds, the spinners have turned before the update, so that a spinner
    /// that starts over shows as a smaller time.
    static let turned = 200.0

    let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: true, displayedQuestion: nil)

    /// The time of each listed spinner's animation, in milliseconds; nil for a spinner that is
    /// missing or does not turn.
    struct Times: Decodable {
        var before: [Double?]
        var after: [Double?]
        var text: String
    }

    /// The transcript page in a web view of an offscreen window, once `chat.js` has set it up.
    func page() async throws -> (WKWebView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500), configuration: WKWebViewConfiguration())
        // WebKit hides the page of an occluded window, and the timeline of a hidden page stands
        // still: its spinners would never turn.
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        try #require(webView.responds(to: selector))
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, false)
        window.contentView = webView
        window.orderFrontRegardless()
        let url = try #require(TranscriptController.pageURL)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        let ready = try await waitUntil {
            try await run(webView, "return document.readyState === 'complete' && typeof HephaestusChat === 'object' ? 'yes' : 'no';") == "yes"
        }
        try #require(ready, "chat.html did not load")
        return (webView, window)
    }

    func run(_ webView: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> String {
        let result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        return result as? String ?? ""
    }

    /// Polls `condition` until it holds; false once `waitLimit` has passed.
    func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + Self.waitLimit
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// The script that reads the times of the spinners of `selectors`.
    static let spinnerTimes = """
        function times(selectors) {
          return selectors.map(function (selector) {
            var spinner = document.querySelector(selector);
            var animation = spinner && spinner.getAnimations()[0];
            return animation && animation.currentTime !== null ? animation.currentTime : null;
          });
        }
        """

    /// Waits until every spinner of `selectors` has turned for `turned` milliseconds.
    func waitForTurns(_ webView: WKWebView, _ selectors: [String]) async throws {
        let turned = try await waitUntil {
            try await run(webView, Self.spinnerTimes + """
                return times(selectors).every(function (time) { return time !== null && time >= \(Self.turned); }) ? 'yes' : 'no';
                """, ["selectors": selectors]) == "yes"
        }
        try #require(turned, "the spinners did not turn")
    }

    func decode(_ json: String) throws -> Times {
        try JSONDecoder().decode(Times.self, from: Data(json.utf8))
    }

    func expectContinuous(_ times: Times) {
        #expect(times.before.count == times.after.count)
        for (before, after) in zip(times.before, times.after) {
            guard let before, let after else {
                Issue.record("a spinner does not turn: \(times.before) → \(times.after)")
                continue
            }
            #expect(before >= Self.turned)
            #expect(abs(after - before) < 1, "the spinner went from \(before) ms to \(after) ms")
        }
    }

    @Test("The spinner of the Preparing tool call… card goes on turning when a chat.delta updates the card")
    func streamUpdate() async throws {
        let (webView, window) = try await page()
        defer { window.close() }
        let first = TranscriptRenderer.streamHTML(kind: .toolInput, text: "{\"command\": \"cat <<'EOF'", context: context)
        _ = try await run(webView, "HephaestusChat.stream({ itemID: 'tool-1', kind: 'toolInput', html: html }); return '';", ["html": first])
        let spinner = "[data-id='tool-1'] .spinner"
        try await waitForTurns(webView, [spinner])

        let input = "{\"command\": \"cat <<'EOF'\\n" + String(repeating: "line of the heredoc\\n", count: 30)
        let second = TranscriptRenderer.streamHTML(kind: .toolInput, text: input, context: context)
        let times = try decode(try await run(webView, Self.spinnerTimes + """
            var before = times(selectors);
            HephaestusChat.stream({ itemID: 'tool-1', kind: 'toolInput', html: html });
            var text = document.querySelector("[data-id='tool-1'] .partial-json").textContent;
            return JSON.stringify({ before: before, after: times(selectors), text: text });
            """, ["selectors": [spinner], "html": second]))
        expectContinuous(times)
        #expect(times.text == String(input.suffix(TranscriptState.toolInputTail)))
    }

    @Test("The spinners of an Agent card and of its steps go on turning when the card is redrawn")
    func replaceUpdate() async throws {
        let (webView, window) = try await page()
        defer { window.close() }
        let created = Date()
        let agent = ChatItem.toolUse(ToolUseItem(id: "agent-item", created: created, toolUseID: "agent",
                                                 name: "Agent", input: .object(["description": .string("Review the docs")])))
        let step = ChatItem.toolUse(ToolUseItem(id: "step-1-item", created: created, toolUseID: "step-1", name: "Bash",
                                                input: .object(["command": .string("ls docs")]), parentToolUseID: "agent"))
        var state = TranscriptState()
        state.upsert(agent)
        state.upsert(step)
        let fragments = [agent, step].map { TranscriptRenderer.fragment(for: $0, in: state, context: context) }
        // The card is expanded, so the spinner of its step turns too.
        _ = try await run(webView, """
            fragments.forEach(function (fragment) { HephaestusChat.upsert(fragment); });
            document.querySelector("[data-id='agent-item'] > .tool-card > .tool-header").click();
            return '';
            """, ["fragments": try fragments.map(Self.object)])
        let spinners = ["[data-id='agent-item'] > .tool-card > .tool-header .spinner", "[data-id='step-1-item'] .spinner"]
        try await waitForTurns(webView, spinners)

        state.upsert(.toolUse(ToolUseItem(id: "step-2-item", created: created, toolUseID: "step-2", name: "Read",
                                          input: .object(["file_path": .string("docs/chats.md")]), parentToolUseID: "agent")))
        let redrawn = TranscriptRenderer.fragment(for: agent, in: state, context: context)
        let times = try decode(try await run(webView, Self.spinnerTimes + """
            var before = times(selectors);
            HephaestusChat.upsert(fragment);
            var text = document.querySelector("[data-id='agent-item'] .tool-steps-count").textContent;
            return JSON.stringify({ before: before, after: times(selectors), text: text });
            """, ["selectors": spinners, "fragment": try Self.object(redrawn)]))
        expectContinuous(times)
        #expect(times.text == "2 steps")
    }

    /// A fragment as the dictionary the bridge receives.
    static func object(_ fragment: TranscriptFragment) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(fragment))
    }
}
