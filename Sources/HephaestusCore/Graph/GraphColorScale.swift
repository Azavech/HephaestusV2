/// The colour of an arrow: grey without any call, otherwise a hue between green and red
/// (docs/graph.md › Colour of an arrow).
public enum GraphArrowColor: Equatable, Sendable {
    case grey
    /// In degrees: 120 is green, 0 is red.
    case hue(Double)
}

public enum GraphColorScale {
    public static let green = 120.0
    public static let red = 0.0
    /// The saturation and the brightness of every hue.
    public static let saturation = 0.9
    public static let brightness = 0.85

    /// The busiest arrow is red, the others lie between green and red in proportion of their count
    /// to the busiest one.
    public static func color(count: Int, busiest: Int) -> GraphArrowColor {
        guard count > 0, busiest > 0 else { return .grey }
        let ratio = min(Double(count) / Double(busiest), 1)
        return .hue(green + (red - green) * ratio)
    }
}
