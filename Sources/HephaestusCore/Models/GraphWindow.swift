import Foundation

/// The time windows of the Graph (docs/graph.md › Time window, docs/engine-api.md › GraphWindow):
/// the window of the Graph section, of `graph.read` and of the Dashboard's graph widgets.
public enum GraphWindow: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case fiveMinutes
    case hour
    case day
    case week

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }

    public var id: String { rawValue }

    /// The item of the `Window` pop-ups and menus.
    public var label: String {
        switch self {
        case .fiveMinutes: return "Last 5 minutes"
        case .hour: return "Last hour"
        case .day: return "Last 24 hours"
        case .week: return "Last 7 days"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        }
    }

    /// The window ending at `end`.
    public func interval(endingAt end: Date) -> DateInterval {
        DateInterval(start: end.addingTimeInterval(-seconds), end: end)
    }
}
