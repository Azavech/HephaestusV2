import Foundation
import HephaestusCore
import HephaestusText
import Testing
@testable import HephaestusUI

/// docs/chats.md › Pinned animation card, › Item rendering and › Links, images and files: the
/// transcript's `Animation` card and markers, the card's selection, its Custom row and lanes, and
/// the answers it sends.
@MainActor
@Suite("Animation card")
struct AnimationCardTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)
    static let spring = ".spring(duration: 0.4, bounce: 0.2)"

    static func request(answer: String? = nil) -> AnimationItem {
        let requestID = UUID(uuidString: "8E1F2A3B-4C5D-4E6F-9A0B-1C2D3E4F5A6B")!
        return AnimationItem(id: requestID.uuidString, created: created, requestID: requestID, question: "How should it slide in?",
                             suggestions: [spring, ".easeInOut(duration: 0.25)"], recommended: spring, answer: answer)
    }

    static func html(_ item: ChatItem) -> String {
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)
        return TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
    }

    /// The marker HTML of an expression, with the curve the transcript computes for it.
    static func markerHTML(_ expression: String) throws -> String {
        let curve = try #require(AnimationExpression.markdownCurve(for: expression))
        return "<span class=\"md-animation\" data-duration=\"\(String(format: "%.3f", curve.duration))\" data-easing=\"\(curve.easing)\">"
            + "<button type=\"button\" class=\"md-animation-play\"><span class=\"md-symbol-icon\" data-symbol=\"play.fill\"></span></button>"
            + "<span class=\"md-animation-lane\"><span class=\"md-animation-dot\"></span></span>\(expression)</span>"
    }

    /// A connection that records the params of `chats.answerAnimation`.
    final class RecordingConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ChatsAnswerAnimation.Params] = []

        var answers: [ChatsAnswerAnimation.Params] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? ChatsAnswerAnimation.Params, let result = Empty() as? M.Result {
                lock.withLock { recorded.append(params) }
                return result
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    @Test("The transcript's Animation card: the question, a marker line per suggestion, (recommended), then the answer")
    func transcriptCard() throws {
        let waiting = Self.html(.animation(Self.request()))
        #expect(waiting.contains("<div class=\"questions-title\">Animation</div>"))
        #expect(waiting.contains("<p>How should it slide in?</p>"))
        #expect(waiting.contains("<li>\(try Self.markerHTML(Self.spring)) (recommended)</li>"))
        #expect(waiting.contains("<li>\(try Self.markerHTML(".easeInOut(duration: 0.25)"))</li>"))
        #expect(waiting.contains("<div class=\"answer pending\">Not answered yet</div>"))
        let answered = Self.html(.animation(Self.request(answer: "![](animation:.snappy(duration: 0.3, extraBounce: 0.1))")))
        #expect(answered.contains("<div class=\"answer\">Answer: \(try Self.markerHTML(".snappy(duration: 0.3, extraBounce: 0.1)"))</div>"))
        let typed = Self.html(.animation(Self.request(answer: "Faster")))
        #expect(typed.contains("<div class=\"answer\">Answer: Faster</div>"))
    }

    @Test("A user message draws its animation marker; an expression that is not an animation stays text")
    func userMessage() throws {
        let user = ChatItem.user(UserItem(id: "u", created: Self.created, text: "Animation: ![](animation:\(Self.spring))", sender: "MacBook"))
        #expect(Self.html(user).contains("Animation: \(try Self.markerHTML(Self.spring))"))
        let other = ChatItem.user(UserItem(id: "v", created: Self.created, text: "![](animation:.wobbly)", sender: "MacBook"))
        #expect(Self.html(other).contains("![](animation:.wobbly)"))
    }

    @Test("The lane's curve: a spring plays for its settling duration, a timing curve for its duration, 61 values from 0")
    func curves() throws {
        let ease = try #require(AnimationExpression.markdownCurve(for: ".easeInOut(duration: 0.25)"))
        #expect(ease.duration == 0.25)
        #expect(ease.easing.hasPrefix("linear(0.0000, ") && ease.easing.hasSuffix(", 1.0000)"))
        #expect(ease.easing.components(separatedBy: ", ").count == 61)
        let linear = try #require(AnimationExpression.markdownCurve(for: ".linear"))
        #expect(linear.duration == 0.35 && linear.easing.contains(", 0.5000, "))
        let bouncy = try #require(AnimationExpression.markdownCurve(for: ".bouncy(duration: 0.5, extraBounce: 0.3)"))
        #expect(bouncy.duration > 0.5 && bouncy.duration <= 10)
        let values = bouncy.easing.dropFirst("linear(".count).dropLast().components(separatedBy: ", ").compactMap(Double.init)
        #expect(values.count == 61 && values.first == 0 && (values.max() ?? 0) > 1)
        // An undamped spring never settles: it plays for 10 s.
        #expect(AnimationExpression.markdownCurve(for: ".spring(bounce: 1)")?.duration == 10)
        #expect(AnimationExpression.markdownCurve(for: ".wobbly") == nil)
    }

    @Test("The card preselects the recommended suggestion and fills the Custom row from it; Submit and Skip send the answers")
    func selectionAndAnswers() async throws {
        let request = Self.request()
        let meta = ChatMeta(id: UUID(), kind: .project, created: Self.created, sessionStarted: true, projectID: "DEMO")
        let connection = RecordingConnection()
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.chats[meta.id.uuidString] = meta
        workspace.transcripts[meta.id.uuidString] = TranscriptState(items: [.animation(request)])
        let model = ChatViewModel(workspace: workspace, chatID: meta.id.uuidString, draft: nil)
        #expect(model.transcriptState?.waitingAnimationRequest == request)

        model.animationRequestShown(request)
        #expect(model.animationChoice == .suggestion(Self.spring))
        #expect(model.animationAnswer == "![](animation:\(Self.spring))")
        #expect(model.animationCustomPreset == .spring)
        #expect(model.animationCustom.fullExpression == ".spring(duration: 0.4, bounce: 0.2)")
        #expect(model.animationPlays.isEmpty)

        // Selecting a row plays its lane; Play All plays every lane, the Custom lane included.
        model.selectAnimationSuggestion(".easeInOut(duration: 0.25)")
        #expect(model.animationChoice == .suggestion(".easeInOut(duration: 0.25)"))
        #expect(model.animationPlays == [.suggestion(".easeInOut(duration: 0.25)"): 1])
        model.playAllAnimationLanes(request)
        #expect(model.animationPlays == [.suggestion(".easeInOut(duration: 0.25)"): 2, .suggestion(Self.spring): 1, .custom: 1])

        // The Custom row: a preset keeps the slider values; moving a slider selects the row.
        model.setAnimationCustomPreset(.bouncy)
        #expect(model.animationChoice == .custom && model.animationPlays[.custom] == 2)
        #expect(model.animationCustom.fullExpression == ".bouncy(duration: 0.4, extraBounce: 0)")
        model.animationChoice = .other
        model.setAnimationCustomValue(0.1549, for: .extraBounce)
        #expect(model.animationChoice == .custom)
        #expect(model.animationAnswer == "![](animation:.bouncy(duration: 0.4, extraBounce: 0.15))")
        model.setAnimationCustomPreset(.spring)
        #expect(model.animationCustom.fullExpression == ".spring(duration: 0.4, bounce: 0.2)")
        model.setAnimationCustomPreset(.linear)
        #expect(model.animationCustom.fullExpression == ".linear(duration: 0.4)")
        #expect(AnimationCard.valueText(0.4, .duration) == "0.40 s" && AnimationCard.valueText(-0.5, .bounce) == "-0.50")
        #expect(AnimationPreset.allCases.flatMap(\.parameters).map(AnimationCard.title).contains("Extra Bounce"))

        // The same request keeps its state.
        model.animationRequestShown(request)
        #expect(model.animationChoice == .custom && model.animationCustomPreset == .linear)
        model.animationChoice = .other
        #expect(!model.canSubmitAnimation)
        model.animationOther = "  Faster\n"
        #expect(model.animationAnswer == "Faster")

        func sent(_ count: Int) async throws -> [String] {
            let deadline = ContinuousClock.now + .seconds(10)
            while connection.answers.count < count || model.isSubmittingAnimation, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return connection.answers.map(\.answer)
        }
        model.submitAnimation()
        #expect(try await sent(1) == ["Faster"])
        model.selectAnimationCustom()
        model.submitAnimation()
        #expect(try await sent(2) == ["Faster", "![](animation:.linear(duration: 0.4))"])
        model.skipAnimation()
        #expect(try await sent(3) == ["Faster", "![](animation:.linear(duration: 0.4))", "Skipped"])
        #expect(connection.answers.allSatisfy { $0.chatID == meta.id && $0.requestID == request.requestID })
    }

    @Test("Without parameters, the Custom row takes SwiftUI's defaults of the recommended preset")
    func defaults() {
        let requestID = UUID()
        let request = AnimationItem(id: requestID.uuidString, created: Self.created, requestID: requestID, question: "How?",
                                    suggestions: [".snappy", ".easeIn"], recommended: ".snappy")
        let workspace = DeviceWorkspace(deviceID: "device", connection: RecordingConnection(), isLocal: true)
        let model = ChatViewModel(workspace: workspace, chatID: nil, draft: nil)
        model.animationRequestShown(request)
        #expect(model.animationCustom.fullExpression == ".snappy(duration: 0.5, extraBounce: 0)")
        model.setAnimationCustomPreset(.easeIn)
        #expect(model.animationCustom.fullExpression == ".easeIn(duration: 0.5)")
    }
}
