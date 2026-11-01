import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/ui.md › Weekly usage: the ring, its colour, the percentage, the tooltip, the popover lines
/// and when the item is hidden.
@Suite("Weekly usage")
struct WeeklyUsagePresentationTests {
    /// Sunday 1 November 2026, 14:00 in Paris.
    let resetsAt = ISODate.date(from: "2026-11-01T13:00:00Z")!
    let paris = TimeZone(identifier: "Europe/Paris")!
    var now: Date { resetsAt.addingTimeInterval(-3_600) }

    func usage(_ utilization: Double, status: String = "allowed", overageStatus: String? = nil, reason: String? = nil,
               inUse: Bool? = nil) -> PlanUsage {
        PlanUsage(utilization: utilization, resetsAt: resetsAt, status: status, overageStatus: overageStatus,
                  overageDisabledReason: reason, isUsingOverage: inUse, received: resetsAt.addingTimeInterval(-86_400))
    }

    func presentation(_ usage: PlanUsage?, at date: Date? = nil, locale: String = "fr_FR") -> WeeklyUsagePresentation? {
        WeeklyUsagePresentation(usage: usage, now: date ?? now, locale: Locale(identifier: locale), timeZone: paris)
    }

    @Test("Hidden while no value is known and from the reset time on")
    func hidden() {
        #expect(presentation(nil) == nil)
        #expect(presentation(usage(0.5), at: resetsAt) == nil)
        #expect(presentation(usage(0.5), at: resetsAt.addingTimeInterval(1)) == nil)
        #expect(presentation(usage(0.5), at: resetsAt.addingTimeInterval(-1)) != nil)
    }

    @Test("Green below 80%, orange from 80%, red when rejected or at 100%")
    func levels() throws {
        #expect(try #require(presentation(usage(0.79))).level == .normal)
        #expect(try #require(presentation(usage(0.8))).level == .warning)
        #expect(try #require(presentation(usage(0.99))).level == .warning)
        #expect(try #require(presentation(usage(1))).level == .limited)
        #expect(try #require(presentation(usage(1.04))).level == .limited)
        #expect(try #require(presentation(usage(0.3, status: "rejected"))).level == .limited)
        #expect(try #require(presentation(usage(0.85, status: "allowed_warning"))).level == .warning)
        #expect(WeeklyUsageItem.color(.normal) == .green)
        #expect(WeeklyUsageItem.color(.warning) == .orange)
        #expect(WeeklyUsageItem.color(.limited) == .red)
    }

    @Test("The percentage is rounded to the nearest and capped at 100; the ring is at most full")
    func percentage() throws {
        let rounded = try #require(presentation(usage(0.685)))
        #expect(rounded.percentage == 69)
        #expect(rounded.percentageLine == "69% used")
        #expect(rounded.tooltip == "Weekly usage: 69% used")
        #expect(rounded.fraction == 0.685)
        #expect(try #require(presentation(usage(0.684))).percentage == 68)
        let over = try #require(presentation(usage(1.04)))
        #expect(over.percentage == 100)
        #expect(over.fraction == 1)
        #expect(try #require(presentation(usage(0))).percentageLine == "0% used")
    }

    @Test("The reset line: English weekday, the Mac's time format and time zone")
    func resetLine() throws {
        #expect(try #require(presentation(usage(0.5), locale: "fr_FR")).resetLine == "resets Sun 14:00")
        #expect(try #require(presentation(usage(0.5), locale: "en_GB")).resetLine == "resets Sun 14:00")
        let twelveHour = try #require(presentation(usage(0.5), locale: "en_US")).resetLine
        #expect(twelveHour.hasPrefix("resets Sun 2:00"))
        #expect(twelveHour.hasSuffix("PM"))
    }

    @Test("The overage line: the CLI values with spaces, the reason and in use when present")
    func overageLine() throws {
        #expect(try #require(presentation(usage(0.5))).overageLine == nil)
        #expect(try #require(presentation(usage(0.5, reason: "out_of_credits"))).overageLine == nil)
        #expect(try #require(presentation(usage(0.5, overageStatus: "rejected", reason: "out_of_credits", inUse: false))).overageLine
            == "Overage: rejected · out of credits")
        #expect(try #require(presentation(usage(0.5, overageStatus: "allowed_warning", inUse: true))).overageLine
            == "Overage: allowed warning · in use")
        #expect(try #require(presentation(usage(0.5, overageStatus: "allowed"))).overageLine == "Overage: allowed")
    }
}
