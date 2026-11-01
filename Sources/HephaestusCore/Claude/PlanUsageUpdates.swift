import Foundation

/// The engine's plan usage: the newest weekly usage of the Claude account it knows, from the
/// `rate_limit_event` lines of its chats and from the values other devices report
/// (docs/engine-api.md › Plan usage, docs/remote.md › Plan usage sharing).
extension Engine {
    /// The plan usage the API shows: nil when none is known or its reset time has passed.
    func visiblePlanUsage(now: Date = Date()) -> PlanUsage? {
        guard let planUsage, !planUsage.hasExpired(at: now) else { return nil }
        return planUsage
    }

    /// A value read from a `rate_limit_event` of one of the engine's chats: it always replaces
    /// the kept value, with a `received` later than the kept one's, so it is the newest known
    /// whatever the clocks of the other devices.
    func receivePlanUsage(_ usage: PlanUsage) {
        var usage = usage
        if let kept = planUsage, usage.received <= kept.received {
            usage.received = kept.received.addingTimeInterval(1)
        }
        keepPlanUsage(usage, origin: .system)
    }

    /// `claude.reportPlanUsage`: the value is kept when the engine has none or when its
    /// `received` is later than the kept one's, and its reset time has not passed.
    func reportPlanUsage(_ usage: PlanUsage, actor: Actor) throws -> PlanUsageState {
        try validated { try usage.validate() }
        let now = Date()
        if !usage.hasExpired(at: now), planUsage.map({ usage.received > $0.received }) ?? true {
            keepPlanUsage(usage, origin: actor)
        }
        return PlanUsageState(usage: visiblePlanUsage(now: now))
    }

    /// Writes `plan-usage.yml`, then emits `planUsage.updated`. A failed write is logged; the
    /// value is kept in memory and the event emitted all the same.
    private func keepPlanUsage(_ usage: PlanUsage, origin: Actor) {
        planUsage = usage
        do {
            try DeviceFileStore.write(usage, to: dataDirectory)
        } catch {
            log.error(.storage, "the plan usage cannot be written: \(error)")
        }
        emit(PlanUsageUpdatedEvent.self, usage, origin: origin)
    }
}
