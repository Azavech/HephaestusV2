import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Pinned sound card, › Sound search and › Item rendering: the transcript's
/// `Sound` card, the list of the pinned card, its selection, its search and the answers it sends.
@MainActor
@Suite("Sound card")
struct SoundCardTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)
    static let sms = "iOS 26.1/sms-received1.caf"
    static let glass = "macOS/Glass.aiff"

    static func request(answer: String? = nil) -> SoundItem {
        let requestID = UUID(uuidString: "8E1F2A3B-4C5D-4E6F-9A7B-8C9D0E1F2A3B")!
        return SoundItem(id: requestID.uuidString, created: created, requestID: requestID, question: "Which sound?",
                         suggestions: [sms, glass], recommended: sms, answer: answer)
    }

    static func soundHTML(_ name: String) -> String {
        "<span class=\"md-sound\"><button type=\"button\" class=\"md-sound-play\" data-sound=\"\(name)\">"
            + "<span class=\"md-symbol-icon\" data-symbol=\"play.circle.fill\"></span></button>\(name)</span>"
    }

    static func html(_ item: ChatItem) -> String {
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)
        return TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
    }

    /// A connection that answers `sounds.list` and records the params of `chats.answerSound`.
    final class RecordingConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ChatsAnswerSound.Params] = []
        let names: [String]

        init(names: [String]) {
            self.names = names
        }

        var answers: [ChatsAnswerSound.Params] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? ChatsAnswerSound.Params, let result = Empty() as? M.Result {
                lock.withLock { recorded.append(params) }
                return result
            }
            if params is SoundsList.Params, let result = names as? M.Result {
                return result
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    @Test("The transcript's Sound card: the question, a line per suggestion with its play button, (recommended), then the answer")
    func transcriptCard() {
        let waiting = Self.html(.sound(Self.request()))
        #expect(waiting.contains("<div class=\"questions-title\">Sound</div>"))
        #expect(waiting.contains("<p>Which sound?</p>"))
        #expect(waiting.contains("<li>\(Self.soundHTML(Self.sms)) (recommended)</li>"))
        #expect(waiting.contains("<li>\(Self.soundHTML(Self.glass))</li>"))
        #expect(waiting.contains("<div class=\"answer pending\">Not answered yet</div>"))
        let answered = Self.html(.sound(Self.request(answer: "![](sound:\(Self.glass))")))
        #expect(answered.contains("<div class=\"answer\">Answer: \(Self.soundHTML(Self.glass))</div>"))
        let typed = Self.html(.sound(Self.request(answer: "A chime")))
        #expect(typed.contains("<div class=\"answer\">Answer: A chime</div>"))
    }

    @Test("A sound marker in a bubble is the play button followed by the name")
    func bubbleMarker() {
        let user = UserItem(id: "u", created: Self.created, text: "Sound: ![](sound:\(Self.sms))", sender: "MacBook")
        #expect(Self.html(.user(user)).contains("<p>Sound: \(Self.soundHTML(Self.sms))</p>"))
    }

    @Test("The list: the suggestions first, then the results; rows read <file> · <source>; at most 8 rows visible")
    func list() {
        let request = Self.request()
        #expect(SoundList.names(request, results: ["Project/Sounds/alert.caf", Self.glass]) == [Self.sms, Self.glass, "Project/Sounds/alert.caf"])
        #expect(SoundList.rowText(Self.sms) == ("sms-received1.caf", " · iOS 26.1"))
        #expect(SoundList.rowText(Self.glass) == ("Glass.aiff", " · macOS"))
        #expect(SoundList.rowText("Project/Sounds/alert.caf") == ("Sounds/alert.caf", " · Project"))
        #expect(SoundList.height(count: 2) == 46)
        #expect(SoundList.height(count: 500) == 190)
    }

    @Test("The card preselects the recommended sound, searches the catalogue of sounds.list, and sends ![](sound:<name>), the text or Skipped")
    func selectionSearchAndAnswers() async throws {
        let request = Self.request()
        let meta = ChatMeta(id: UUID(), kind: .project, created: Self.created, sessionStarted: true, projectID: "DEMO")
        let connection = RecordingConnection(names: [Self.glass, Self.sms, "iOS 26.1/new-mail.caf", "Project/Sounds/mail.caf"])
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.chats[meta.id.uuidString] = meta
        workspace.transcripts[meta.id.uuidString] = TranscriptState(items: [.sound(request)])
        let model = ChatViewModel(workspace: workspace, chatID: meta.id.uuidString, draft: nil)
        #expect(model.transcriptState?.waitingSoundRequest == request)

        model.soundRequestShown(request)
        #expect(model.soundChoice == .sound(Self.sms))
        #expect(model.soundAnswer == "![](sound:\(Self.sms))")
        let deadline = ContinuousClock.now + .seconds(10)
        while model.soundNames.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.soundSearch = "mail"
        model.searchSounds(excluding: request.suggestions)
        #expect(model.soundResults == ["iOS 26.1/new-mail.caf", "Project/Sounds/mail.caf"])
        model.soundSearch = "glass"
        model.searchSounds(excluding: request.suggestions)
        #expect(model.soundResults.isEmpty)
        model.soundChoice = .sound(Self.glass)
        // The same request keeps its selection and search.
        model.soundRequestShown(request)
        #expect(model.soundChoice == .sound(Self.glass) && model.soundSearch == "glass")
        model.soundChoice = .other
        #expect(!model.canSubmitSound)
        model.soundOther = "  A soft chime\n"
        #expect(model.soundAnswer == "A soft chime")

        func sent(_ count: Int) async throws -> [String] {
            let deadline = ContinuousClock.now + .seconds(10)
            while connection.answers.count < count || model.isSubmittingSound, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return connection.answers.map(\.answer)
        }
        model.submitSound()
        #expect(try await sent(1) == ["A soft chime"])
        model.soundChoice = .sound(Self.glass)
        model.submitSound()
        #expect(try await sent(2) == ["A soft chime", "![](sound:\(Self.glass))"])
        model.skipSound()
        #expect(try await sent(3) == ["A soft chime", "![](sound:\(Self.glass))", "Skipped"])
        #expect(connection.answers.allSatisfy { $0.chatID == meta.id && $0.requestID == request.requestID })
    }
}
