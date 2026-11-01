import Foundation

/// The cost of a chat from the `costUSD` of its `result` items, in transcript order
/// (docs/costs.md › Chat cost). The values form runs in which each value is at least the one
/// before it; a lower value starts a new run, a new CLI session. The cost is the sum of the last
/// value of each run.
struct ChatCost: Sendable, Hashable {
    /// The sum of the last values of the runs before the current one.
    private(set) var finishedRuns: Double = 0
    /// The last value of the current run; nil before the first value.
    private(set) var last: Double?

    init() {}

    /// The cost of a transcript's items.
    init(items: [ChatItem]) {
        for case .result(let result) in items {
            add(result.costUSD)
        }
    }

    /// Adds the `costUSD` of a `result` item; a null value is skipped.
    mutating func add(_ value: Double?) {
        guard let value else { return }
        if let last, value < last {
            finishedRuns += last
        }
        last = value
    }

    /// The chat's cost; nil when no `result` item reported one.
    var costUSD: Double? {
        last.map { finishedRuns + $0 }
    }
}
