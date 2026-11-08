// OWNER: ui-shell — the Weekly usage item of the status bar and its popover (docs/ui.md › Weekly
// usage).
import AppKit
import HephaestusCore
import SwiftUI

/// What the Weekly usage item and its popover show for a plan usage (docs/ui.md › Weekly usage).
struct WeeklyUsagePresentation: Equatable {
    enum Level: Equatable {
        /// Below 80%: green.
        case normal
        /// From 80%: orange.
        case warning
        /// `status` `rejected` or `utilization` 1 or more: red.
        case limited
    }

    /// How much of the ring is filled, 0 to 1.
    let fraction: Double
    /// `utilization` × 100 rounded to the nearest integer, capped at 100.
    let percentage: Int
    let level: Level
    /// `resets <weekday> <time>`.
    let resetLine: String
    /// `Overage: <status>[ · <reason>][ · in use]`; nil when the CLI sent no overage status.
    let overageLine: String?

    /// nil when no value is known or its reset time has passed at `now`: the item is hidden.
    init?(usage: PlanUsage?, now: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        guard let usage, !usage.hasExpired(at: now) else { return nil }
        fraction = min(max(usage.utilization, 0), 1)
        percentage = Int((fraction * 100).rounded())
        if usage.status == "rejected" || usage.utilization >= 1 {
            level = .limited
        } else if usage.utilization >= 0.8 {
            level = .warning
        } else {
            level = .normal
        }
        resetLine = "resets \(Self.weekday(usage.resetsAt, timeZone: timeZone)) \(Self.time(usage.resetsAt, locale: locale, timeZone: timeZone))"
        if let status = usage.overageStatus {
            var line = "Overage: \(Self.spaced(status))"
            if let reason = usage.overageDisabledReason { line += " · \(Self.spaced(reason))" }
            if usage.isUsingOverage == true { line += " · in use" }
            overageLine = line
        } else {
            overageLine = nil
        }
    }

    /// `<percentage>% used`.
    var percentageLine: String { "\(percentage)% used" }

    /// The tooltip and accessibility label.
    var tooltip: String { "Weekly usage: \(percentageLine)" }

    /// The weekday abbreviated in English, `Mon` to `Sun`.
    static func weekday(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    /// The time in the Mac's short time format: `14:00`, or `2:00 PM` with a 12-hour clock.
    static func time(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// A CLI value with spaces in place of underscores: `out_of_credits` → `out of credits`.
    static func spaced(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
    }
}

/// The Weekly usage item: a ring filled to the weekly usage, hidden while no value is known and
/// from the reset time on; a click opens the popover.
struct WeeklyUsageItem: View {
    let usage: PlanUsage?
    /// The time the item is drawn for; the status bar sets it again at the reset time.
    let now: Date
    @State private var popoverShown = false

    var body: some View {
        if let presentation = WeeklyUsagePresentation(usage: usage, now: now) {
            Button {
                popoverShown = true
            } label: {
                WeeklyUsageRing(fraction: presentation.fraction, color: Self.color(presentation.level))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(presentation.tooltip)
            .accessibilityLabel(presentation.tooltip)
            .popover(isPresented: $popoverShown, arrowEdge: .top) {
                WeeklyUsagePopover(presentation: presentation)
            }
        }
    }

    static func color(_ level: WeeklyUsagePresentation.Level) -> Color {
        switch level {
        case .normal: return .green
        case .warning: return .orange
        case .limited: return .red
        }
    }
}

/// A ring 12 points wide, filled clockwise from the top; the unfilled part in the separator
/// colour.
private struct WeeklyUsageRing: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }
}

/// The weekly usage popover: the title, the percentage, the reset time and the overage status.
private struct WeeklyUsagePopover: View {
    let presentation: WeeklyUsagePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Weekly usage")
                .bold()
            Text(presentation.percentageLine)
                .monospacedDigit()
            Text(presentation.resetLine)
            if let overage = presentation.overageLine {
                Text(overage)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .fixedSize()
    }
}
