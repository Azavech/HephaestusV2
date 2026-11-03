import Foundation

/// How the lane of an animation marker plays (docs/documentation-viewer.md › Animation markers).
public struct MarkdownAnimationCurve: Sendable, Equatable {
    /// Seconds the lane plays.
    public var duration: Double
    /// A CSS easing function, `linear(…)`.
    public var easing: String

    public init(duration: Double, easing: String) {
        self.duration = duration
        self.easing = easing
    }
}

/// Animation markers (docs/documentation-viewer.md › Animation markers): images whose source has
/// the scheme `animation` followed by a SwiftUI expression written as is, such as
/// `![](animation:.spring(duration: 0.4, bounce: 0.2))`. `MarkdownSymbolMarkers` finds them.
enum MarkdownAnimationMarkers {
    /// The `data-easing` value: the characters of a `linear()` function only
    /// (docs/documentation-viewer.md › Sanitization).
    static func sanitizedEasing(_ easing: String) -> String {
        easing.filter { $0.isASCII && ($0.isNumber || ".-, ()linear".contains($0)) }
    }
}
