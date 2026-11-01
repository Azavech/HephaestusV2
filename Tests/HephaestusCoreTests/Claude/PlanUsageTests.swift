import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › Plan usage and docs/data-model.md › Plan usage file: the value of a chat's
/// `rate_limit_event`, `plan-usage.yml`, the expiry at the reset time and the newest-value rule
/// of `claude.reportPlanUsage`.
@Suite("Plan usage")
struct PlanUsageTests {
    /// Three days from now, in whole seconds.
    static var future: Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3 * 86_400).rounded(.down)) }
    static let past = ISODate.date(from: "2026-01-04T13:00:00Z")!
    static let received = ISODate.date(from: "2026-10-31T14:02:41Z")!

    static func usage(utilization: Double = 0.68, resetsAt: Date = future, status: String = "allowed",
                      received: Date = received) -> PlanUsage {
        PlanUsage(utilization: utilization, resetsAt: resetsAt, status: status, overageStatus: "rejected",
                  overageDisabledReason: "out_of_credits", isUsingOverage: false, received: received)
    }

    /// A `rate_limit_event` line of Claude Code 2.1.309 with the weekly window.
    static func rateLimitLine(utilization: Double, resetsAt: Date, status: String = "allowed") -> String {
        let seconds = Int(resetsAt.timeIntervalSince1970)
        return #"{"type":"rate_limit_event","rate_limit_info":{"status":"\#(status)","resetsAt":\#(seconds),"rateLimitType":"seven_day","#
            + #""overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false,"#
            + #""unifiedWindows":{"five_hour":{"utilization":0.1,"resetsAt":\#(seconds)},"#
            + #""seven_day":{"utilization":\#(utilization),"resetsAt":\#(seconds)}}},"uuid":"u","session_id":"s"}"#
    }

    @Test("A chat's rate_limit_event replaces the plan usage, writes plan-usage.yml and emits planUsage.updated")
    func fromChat() async throws {
        try await withChatEngine { bed in
            #expect(try await bed.connection.call(ClaudePlanUsage.self) == PlanUsageState())
            _ = try await bed.createChat(message: "hello")
            let process = try #require(await bed.launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            let resetsAt = Self.future
            process.emit(Self.rateLimitLine(utilization: 0.42, resetsAt: resetsAt, status: "allowed_warning"))
            let event = try #require(await bed.events.wait(for: "planUsage.updated"))
            #expect(event.origin == .system)
            let usage = try event.payload(PlanUsageUpdatedEvent.self)
            #expect(usage.utilization == 0.42)
            #expect(usage.resetsAt == resetsAt)
            #expect(usage.status == "allowed_warning")
            #expect(usage.overageStatus == "rejected")
            #expect(usage.overageDisabledReason == "out_of_credits")
            #expect(usage.isUsingOverage == false)
            #expect(abs(usage.received.timeIntervalSinceNow) < 60)
            // Persisted, returned by claude.planUsage and part of the snapshot.
            #expect(try DeviceFileStore.loadPlanUsage(bed.dataDirectory, log: nil) == usage)
            #expect(try await bed.connection.call(ClaudePlanUsage.self).usage == usage)
            #expect(try await bed.connection.call(SnapshotGet.self).planUsage == usage)
        }
    }

    @Test("plan-usage.yml is read at launch and shown before any chat runs")
    func persisted() async throws {
        let usage = Self.usage()
        try await withTestEngine(prepare: { try DeviceFileStore.write(usage, to: $0) }) { _, connection, _ in
            let state = try await connection.call(ClaudePlanUsage.self)
            #expect(state.usage == usage)
            let snapshot = try await connection.call(SnapshotGet.self)
            #expect(snapshot.planUsage == usage)
        }
    }

    @Test("A value whose reset time has passed is hidden by claude.planUsage and snapshot.get")
    func expired() async throws {
        try await withTestEngine(prepare: { try DeviceFileStore.write(Self.usage(resetsAt: Self.past), to: $0) }) { _, connection, _ in
            let state = try await connection.call(ClaudePlanUsage.self)
            #expect(state.usage == nil)
            #expect(String(decoding: try EngineJSON.encode(state), as: UTF8.self) == "{}")
            let snapshot = try await connection.call(SnapshotGet.self)
            #expect(snapshot.planUsage == nil)
            let json = try jsonValue(String(decoding: try EngineJSON.encode(snapshot), as: UTF8.self))
            #expect(json.objectValue?["planUsage"] == nil)
        }
    }

    @Test("No plan-usage.yml gives no value; an invalid one is set aside")
    func missingAndInvalid() async throws {
        try await withTestEngine { engine, connection, _ in
            let state = try await connection.call(ClaudePlanUsage.self)
            #expect(state.usage == nil)
            #expect(!FileManager.default.fileExists(atPath: engine.dataDirectory.planUsageFile.path))
        }
        try await withTestEngine(prepare: { try Data("schema: 1\nutilization: high\n".utf8).write(to: $0.planUsageFile) }) { engine, connection, _ in
            let state = try await connection.call(ClaudePlanUsage.self)
            #expect(state.usage == nil)
            let directory = engine.dataDirectory
            #expect(FileManager.default.fileExists(atPath: directory.invalidCopy(of: directory.planUsageFile).path))
            #expect(!FileManager.default.fileExists(atPath: directory.planUsageFile.path))
        }
    }

    @Test("claude.reportPlanUsage keeps a value only when its received is later and its reset time has not passed")
    func newestValue() async throws {
        let kept = Self.usage()
        try await withTestEngine(prepare: { try DeviceFileStore.write(kept, to: $0) }) { engine, connection, _ in
            let events = EventRecorder(connection.events)
            func report(_ usage: PlanUsage) async throws -> PlanUsage? {
                try await connection.call(ClaudeReportPlanUsage.self, .init(usage: usage)).usage
            }
            // Older or as old: the engine keeps its value.
            #expect(try await report(Self.usage(utilization: 0.9, received: Self.received.addingTimeInterval(-60))) == kept)
            #expect(try await report(Self.usage(utilization: 0.9, received: Self.received)) == kept)
            // Newer: kept, written and emitted with the caller as origin.
            let newer = Self.usage(utilization: 0.75, received: Self.received.addingTimeInterval(60))
            #expect(try await report(newer) == newer)
            let event = try #require(await events.wait(for: "planUsage.updated"))
            #expect(try event.payload(PlanUsageUpdatedEvent.self) == newer)
            #expect(event.origin == .user(deviceID: engine.deviceID))
            #expect(try DeviceFileStore.loadPlanUsage(engine.dataDirectory, log: nil) == newer)
            // A newer value whose reset time has passed is never kept.
            let expired = Self.usage(utilization: 0.1, resetsAt: Self.past, received: Self.received.addingTimeInterval(120))
            #expect(try await report(expired) == newer)
            #expect(try DeviceFileStore.loadPlanUsage(engine.dataDirectory, log: nil) == newer)
            // A value that breaks a write rule fails.
            let error = await engineError { try await report(Self.usage(utilization: -1, received: Self.received.addingTimeInterval(180))) }
            #expect(error == EngineError(.invalid, "utilization: use a number of 0 or more."))
            let emptyStatus = await engineError { try await report(Self.usage(status: "", received: Self.received.addingTimeInterval(180))) }
            #expect(emptyStatus == EngineError(.invalid, "status: use one line that is not empty."))
            try await Task.sleep(for: .milliseconds(200))
            #expect(await events.named("planUsage.updated").count == 1)
            await events.stop()
        }
    }

    @Test("A chat's value replaces a reported one received later by another device's clock")
    func ownValueIsNewest() async throws {
        try await withChatEngine { bed in
            let ahead = Self.usage(received: Date().addingTimeInterval(3_600).truncatedToSeconds)
            #expect(try await bed.connection.call(ClaudeReportPlanUsage.self, .init(usage: ahead)).usage == ahead)
            _ = try await bed.createChat(message: "hello")
            let process = try #require(await bed.launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(Self.rateLimitLine(utilization: 0.5, resetsAt: Self.future))
            let event = try #require(await bed.events.wait(for: "planUsage.updated") {
                (try? $0.payload(PlanUsageUpdatedEvent.self))?.utilization == 0.5
            })
            let usage = try event.payload(PlanUsageUpdatedEvent.self)
            #expect(usage.received == ahead.received.addingTimeInterval(1))
            #expect(try await bed.connection.call(ClaudePlanUsage.self).usage == usage)
            // A value reported with the previous received is now older.
            #expect(try await bed.connection.call(ClaudeReportPlanUsage.self, .init(usage: ahead)).usage == usage)
        }
    }
}
