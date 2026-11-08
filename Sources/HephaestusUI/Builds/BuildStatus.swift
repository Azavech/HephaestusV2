// OWNER: ui-builds — status icons and texts, durations and dates of runs, jobs and steps
// (docs/builds.md › Status, › Durations).
import Foundation
import HephaestusCore
import SwiftUI

/// The look of a run, job or step, from its `status` and, once it is `completed`, its
/// `conclusion` (docs/builds.md › Status).
enum BuildStatusKind: Equatable {
    /// `queued`, `requested`, `waiting` or `pending`: `clock.fill` in orange.
    case queued
    /// `in_progress`: a small spinner.
    case running
    /// `success`: `checkmark.circle.fill` in green.
    case success
    /// `failure`, `timed_out` or `startup_failure`: `xmark.octagon.fill` in red.
    case failure
    /// `cancelled`, `skipped`, `neutral`, `stale`, `action_required` or any other conclusion:
    /// `slash.circle.fill` in the secondary colour.
    case other

    init(status: String, conclusion: String?) {
        if status == "completed" {
            switch conclusion {
            case "success": self = .success
            case "failure", "timed_out", "startup_failure": self = .failure
            default: self = .other
            }
        } else if status == "in_progress" {
            self = .running
        } else if ["queued", "requested", "waiting", "pending"].contains(status) {
            self = .queued
        } else {
            self = .other
        }
    }

    /// The SF Symbol and its colour; nil for the spinner.
    var symbol: (name: String, color: Color)? {
        switch self {
        case .queued: return ("clock.fill", .orange)
        case .running: return nil
        case .success: return ("checkmark.circle.fill", .green)
        case .failure: return ("xmark.octagon.fill", .red)
        case .other: return ("slash.circle.fill", .secondary)
        }
    }
}

/// Texts and durations of the Builds section.
enum BuildFormat {
    /// The status text: the conclusion of a completed item, otherwise its status, with `_`
    /// replaced by a space and its first letter in uppercase; `Completed` for a completed item
    /// without conclusion.
    static func statusText(status: String, conclusion: String?) -> String {
        let value = status == "completed" ? (conclusion ?? "completed") : status
        let words = value.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A run, job or step failed: its conclusion is `failure`, `timed_out` or `startup_failure`.
    static func failed(_ conclusion: String?) -> Bool {
        ["failure", "timed_out", "startup_failure"].contains(conclusion ?? "")
    }

    /// Hours, minutes and seconds, a unit at 0 left out, for example `42s`, `14m 17s` or `1h 5s`;
    /// a negative duration counts as 0.
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds)s") }
        return parts.joined(separator: " ")
    }

    /// The start of a run: its `startedAt`, else its creation.
    static func start(of run: WorkflowRun) -> Date {
        run.startedAt ?? run.createdAt
    }

    /// The duration of a run: from its start to its last update once completed, until `now`
    /// before (docs/builds.md › Durations).
    static func runDuration(_ run: WorkflowRun, now: Date) -> TimeInterval {
        let end = run.status == "completed" ? run.updatedAt : now
        return end.timeIntervalSince(start(of: run))
    }

    /// The duration of a job or a step: from its start to its end, or until `now` while it has
    /// started and not completed; nil before it starts.
    static func itemDuration(status: String, startedAt: Date?, completedAt: Date?, now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        if let completedAt {
            return completedAt.timeIntervalSince(startedAt)
        }
        return status == "completed" ? nil : now.timeIntervalSince(startedAt)
    }

    /// The date of a run or a release in the format of the ticket list's Created column.
    static func date(_ date: Date) -> String {
        TicketFormat.created(date)
    }
}

/// The status icon of a run, a job or a step, 16 points wide (docs/builds.md › Status).
struct BuildStatusIcon: View {
    let kind: BuildStatusKind

    var body: some View {
        Group {
            if let symbol = kind.symbol {
                Image(systemName: symbol.name)
                    .foregroundStyle(symbol.color)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// A duration that counts up every second while its item is not completed
/// (docs/builds.md › Durations).
struct BuildDurationText: View {
    let isCounting: Bool
    let duration: (Date) -> TimeInterval?

    var body: some View {
        if isCounting {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                text(at: context.date)
            }
        } else {
            text(at: Date())
        }
    }

    @ViewBuilder
    private func text(at date: Date) -> some View {
        if let interval = duration(date) {
            Text(BuildFormat.duration(interval))
                .monospacedDigit()
        }
    }
}
