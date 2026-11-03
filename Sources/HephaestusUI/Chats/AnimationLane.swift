// OWNER: ui-chats — the SwiftUI animation of an expression and the lanes that play it
// (docs/chats.md › Lanes, › Links, images and files).
import HephaestusCore
import HephaestusText
import SwiftUI

extension AnimationExpression {
    /// The SwiftUI preset of the same name with the expression's parameters, the ones left out
    /// taking SwiftUI's defaults.
    var swiftUIAnimation: Animation {
        let duration = value(.duration)
        switch preset {
        case .smooth: return .smooth(duration: duration, extraBounce: value(.extraBounce))
        case .snappy: return .snappy(duration: duration, extraBounce: value(.extraBounce))
        case .bouncy: return .bouncy(duration: duration, extraBounce: value(.extraBounce))
        case .spring: return .spring(duration: duration, bounce: value(.bounce))
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        case .easeInOut: return .easeInOut(duration: duration)
        case .linear: return .linear(duration: duration)
        }
    }

    /// The `Spring` of a spring preset; nil for the timing curves.
    private var spring: Spring? {
        let duration = value(.duration)
        switch preset {
        case .smooth: return .smooth(duration: duration, extraBounce: value(.extraBounce))
        case .snappy: return .snappy(duration: duration, extraBounce: value(.extraBounce))
        case .bouncy: return .bouncy(duration: duration, extraBounce: value(.extraBounce))
        case .spring: return Spring(duration: duration, bounce: value(.bounce))
        case .easeIn, .easeOut, .easeInOut, .linear: return nil
        }
    }

    private var unitCurve: UnitCurve {
        switch preset {
        case .easeIn: return .easeIn
        case .easeOut: return .easeOut
        case .easeInOut: return .easeInOut
        default: return .linear
        }
    }

    /// The curve of the transcript's lane: 61 values of the move from 0 to 1 evenly spaced over its
    /// duration, as a CSS `linear()` easing (docs/chats.md › Links, images and files). A spring
    /// plays for its settling duration, at most 10 s; a value SwiftUI cannot compute counts as the
    /// end of the move.
    var markdownCurve: MarkdownAnimationCurve {
        let duration: Double
        let value: (Double) -> Double
        if let spring {
            let settling = spring.settlingDuration
            duration = settling.isFinite ? min(max(settling, 0), Self.maximumLaneDuration) : Self.maximumLaneDuration
            value = { spring.value(target: 1.0, time: $0) }
        } else {
            duration = self.value(.duration)
            let curve = unitCurve
            value = { curve.value(at: $0 / duration) }
        }
        let values = (0...Self.laneSamples).map { step -> String in
            let sample = value(duration * Double(step) / Double(Self.laneSamples))
            return String(format: "%.4f", sample.isFinite ? sample : 1)
        }
        return MarkdownAnimationCurve(duration: duration, easing: "linear(" + values.joined(separator: ", ") + ")")
    }

    static let laneSamples = 60
    static let maximumLaneDuration = 10.0

    /// The curve of a marker's expression; nil when it is not an animation of `ask_animation`.
    @Sendable static func markdownCurve(for expression: String) -> MarkdownAnimationCurve? {
        (try? AnimationExpression(parsing: expression))?.markdownCurve
    }
}

/// A lane of the pinned animation card: a capsule track and a circle that slides from its left end
/// to its right end with `animation` each time `plays` changes (docs/chats.md › Lanes).
struct AnimationLane: View {
    let animation: Animation
    /// Incremented to play the lane.
    let plays: Int
    @State private var atEnd = false

    static let width: CGFloat = 160
    static let height: CGFloat = 14

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.quaternary)
            Circle()
                .fill(Color.accentColor)
                .frame(width: Self.height, height: Self.height)
                .offset(x: atEnd ? Self.width - Self.height : 0)
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityHidden(true)
        .onChange(of: plays) {
            play()
        }
    }

    /// Moves the circle at once to the left end, then, once that frame is drawn, animates it to
    /// the right end.
    private func play() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            atEnd = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            withAnimation(animation) {
                atEnd = true
            }
        }
    }
}
