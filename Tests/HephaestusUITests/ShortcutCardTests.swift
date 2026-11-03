import AppKit
import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Pinned shortcut card, › Shortcut recorder, › Shortcut warnings, › Item
/// rendering and › Links, images and files: the transcript's `Shortcut` card, the shortcut
/// markers, the card's selection, recorder, warnings and the answers it sends.
@MainActor
@Suite("Shortcut card")
struct ShortcutCardTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)

    static func request(answer: String? = nil) -> ShortcutItem {
        let requestID = UUID(uuidString: "7D0E2F3A-4B5C-4D6E-9F7A-8B9C0D1E2F3A")!
        return ShortcutItem(id: requestID.uuidString, created: created, requestID: requestID, question: "Which shortcut?",
                            suggestions: ["⇧⌘F", "⌘Space", "⌘N"], recommended: "⇧⌘F",
                            inUse: [ShortcutInUse(shortcut: "⌘N", command: "New Ticket"), ShortcutInUse(shortcut: "⌘W", command: "Close Tab")],
                            answer: answer)
    }

    static func caps(_ caps: String...) -> String {
        "<span class=\"md-shortcut\">" + caps.map { "<kbd>\($0)</kbd>" }.joined() + "</span>"
    }

    static func html(_ item: ChatItem) -> String {
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)
        return TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
    }

    /// A connection that records the params of `chats.answerShortcut`.
    final class RecordingConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ChatsAnswerShortcut.Params] = []

        var answers: [ChatsAnswerShortcut.Params] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? ChatsAnswerShortcut.Params, let result = Empty() as? M.Result {
                lock.withLock { recorded.append(params) }
                return result
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    static func model(_ request: ShortcutItem, connection: RecordingConnection = RecordingConnection()) -> (ChatViewModel, ChatMeta) {
        let meta = ChatMeta(id: UUID(), kind: .project, created: created, sessionStarted: true, projectID: "DEMO")
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.chats[meta.id.uuidString] = meta
        workspace.transcripts[meta.id.uuidString] = TranscriptState(items: [.shortcut(request)])
        return (ChatViewModel(workspace: workspace, chatID: meta.id.uuidString, draft: nil), meta)
    }

    @Test("The transcript's Shortcut card: the question, a line per suggestion as key caps, (recommended), then the answer")
    func transcriptCard() {
        let waiting = Self.html(.shortcut(Self.request()))
        #expect(waiting.contains("<div class=\"questions-title\">Shortcut</div>"))
        #expect(waiting.contains("<p>Which shortcut?</p>"))
        #expect(waiting.contains("<li>\(Self.caps("⇧", "⌘", "F")) (recommended)</li>"))
        #expect(waiting.contains("<li>\(Self.caps("⌘", "Space"))</li>"))
        #expect(waiting.contains("<div class=\"answer pending\">Not answered yet</div>"))
        let answered = Self.html(.shortcut(Self.request(answer: "![](shortcut:⌃⌥K)")))
        #expect(answered.contains("<div class=\"answer\">Answer: \(Self.caps("⌃", "⌥", "K"))</div>"))
        let typed = Self.html(.shortcut(Self.request(answer: "Skipped")))
        #expect(typed.contains("<div class=\"answer\">Answer: Skipped</div>"))
    }

    @Test("A shortcut marker in a message is drawn as key caps; any other marker shows its text")
    func markers() {
        let user = UserItem(id: "u", created: Self.created, text: "Shortcut: ![](shortcut:⇧⌘K)", sender: "MacBook")
        #expect(Self.html(.user(user)).contains("<p>Shortcut: \(Self.caps("⇧", "⌘", "K"))</p>"))
        let escaped = UserItem(id: "e", created: Self.created, text: "Shortcut: ![](shortcut:⌘\\()", sender: "MacBook")
        #expect(Self.html(.user(escaped)).contains("<p>Shortcut: \(Self.caps("⌘", "("))</p>"))
        let wrong = UserItem(id: "w", created: Self.created, text: "Shortcut: ![](shortcut:⌘⇧K)", sender: "MacBook")
        #expect(Self.html(.user(wrong)).contains("<p>Shortcut: ![](shortcut:⌘⇧K)</p>"))
    }

    @Test("The card preselects the recommended suggestion and warns about macOS and app shortcuts without blocking Submit")
    func selectionAndWarnings() {
        let request = Self.request()
        let (model, _) = Self.model(request)
        #expect(model.transcriptState?.waitingShortcutRequest == request)
        model.shortcutRequestShown(request)
        #expect(model.shortcutChoice == .suggestion("⇧⌘F") && model.recordedShortcut == nil && !model.isRecordingShortcut)
        #expect(model.shortcutAnswer == "![](shortcut:⇧⌘F)")
        #expect(model.shortcutWarnings(request).isEmpty)
        model.shortcutChoice = .suggestion("⌘Space")
        #expect(model.shortcutWarnings(request) == ["Used by macOS: Spotlight"])
        #expect(model.canSubmitShortcut)
        model.shortcutChoice = .suggestion("⌘N")
        #expect(model.shortcutWarnings(request) == ["Used by the app: New Ticket"])
        #expect(model.canSubmitShortcut)
        // The same request keeps its selection.
        model.shortcutRequestShown(request)
        #expect(model.shortcutChoice == .suggestion("⌘N"))
        model.shortcutChoice = .other
        #expect(model.shortcutWarnings(request).isEmpty && !model.canSubmitShortcut)
        model.shortcutOther = "  Like Xcode\n"
        #expect(model.shortcutAnswer == "Like Xcode")
    }

    @Test("The recorder: a click starts recording, the next combination is recorded, with or without modifiers")
    func recorder() {
        let request = Self.request()
        let (model, _) = Self.model(request)
        model.shortcutRequestShown(request)
        model.startRecordingShortcut()
        #expect(model.shortcutChoice == .recorder && model.isRecordingShortcut)
        #expect(!model.canSubmitShortcut && model.shortcutWarnings(request).isEmpty)
        // A key the notation cannot write records nothing and recording goes on.
        model.recordShortcutKey(keyCode: 0x72, modifierFlags: [], unmodifiedCharacters: "\u{F746}")
        #expect(model.isRecordingShortcut && model.recordedShortcut == nil)
        model.recordShortcutKey(keyCode: 0x28, modifierFlags: [.control, .option, .capsLock], unmodifiedCharacters: "k")
        #expect(model.recordedShortcut?.notation == "⌃⌥K" && !model.isRecordingShortcut)
        #expect(model.selectedShortcut == "⌃⌥K" && model.shortcutAnswer == "![](shortcut:⌃⌥K)")
        // Not recording: key presses record nothing.
        model.recordShortcutKey(keyCode: 0x35, modifierFlags: [], unmodifiedCharacters: "\u{1B}")
        #expect(model.recordedShortcut?.notation == "⌃⌥K")
        // A new recording keeps the shortcut until the next combination.
        model.startRecordingShortcut()
        #expect(model.recordedShortcut?.notation == "⌃⌥K")
        model.recordShortcutKey(keyCode: 0x35, modifierFlags: [], unmodifiedCharacters: "\u{1B}")
        #expect(model.recordedShortcut?.notation == "⎋" && model.shortcutAnswer == "![](shortcut:⎋)")
        // ⌘Return is recorded like any other combination, and ⇧ is written for punctuation.
        model.startRecordingShortcut()
        model.recordShortcutKey(keyCode: 0x24, modifierFlags: [.command], unmodifiedCharacters: "\r")
        #expect(model.recordedShortcut?.notation == "⌘↩")
        model.startRecordingShortcut()
        model.recordShortcutKey(keyCode: 0x2C, modifierFlags: [.command, .shift], unmodifiedCharacters: "/")
        #expect(model.recordedShortcut?.notation == "⇧⌘/")
        model.startRecordingShortcut()
        model.recordShortcutKey(keyCode: 0x31, modifierFlags: [.command], unmodifiedCharacters: " ")
        #expect(model.shortcutWarnings(request) == ["Used by macOS: Spotlight"])
        // Stopping keeps the shortcut.
        model.startRecordingShortcut()
        model.stopRecordingShortcut()
        #expect(!model.isRecordingShortcut && model.recordedShortcut?.notation == "⌘Space")
        // A new request empties the recorder.
        var other = Self.request()
        other.requestID = UUID()
        model.shortcutRequestShown(other)
        #expect(model.recordedShortcut == nil && model.shortcutChoice == .suggestion("⇧⌘F"))
    }

    @Test("Submit sends ![](shortcut:<shortcut>) or the field's text, Skip sends Skipped")
    func answers() async throws {
        let request = Self.request()
        let connection = RecordingConnection()
        let (model, meta) = Self.model(request, connection: connection)
        model.shortcutRequestShown(request)
        func sent(_ count: Int) async throws -> [String] {
            let deadline = ContinuousClock.now + .seconds(10)
            while connection.answers.count < count || model.isSubmittingShortcut, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return connection.answers.map(\.answer)
        }
        model.submitShortcut()
        #expect(try await sent(1) == ["![](shortcut:⇧⌘F)"])
        model.startRecordingShortcut()
        model.recordShortcutKey(keyCode: 0x19, modifierFlags: [.command, .shift], unmodifiedCharacters: "(")
        model.submitShortcut()
        #expect(try await sent(2) == ["![](shortcut:⇧⌘F)", "![](shortcut:⇧⌘\\()"])
        model.shortcutChoice = .other
        model.shortcutOther = "Like Xcode"
        model.submitShortcut()
        #expect(try await sent(3).last == "Like Xcode")
        model.skipShortcut()
        #expect(try await sent(4) == ["![](shortcut:⇧⌘F)", "![](shortcut:⇧⌘\\()", "Like Xcode", "Skipped"])
        #expect(connection.answers.allSatisfy { $0.chatID == meta.id && $0.requestID == request.requestID })
    }
}
