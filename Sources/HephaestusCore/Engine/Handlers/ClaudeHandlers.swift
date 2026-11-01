import Foundation

extension Engine {
    /// docs/engine-api.md › Claude. `claude.models` returns the cached model list
    /// (Claude/ClaudeCLI.swift); `claude.status` locates the CLI again; `claude.planUsage` and
    /// `claude.reportPlanUsage` read and share the plan usage (Claude/PlanUsageUpdates.swift).
    func registerClaudeHandlers() {
        register(ClaudeModels.self, actors: [.user]) { [unowned self] params, actor in
            try await self.claudeModels(params, actor)
        }
        register(ClaudeStatusMethod.self, actors: [.user]) { [unowned self] _, _ in
            await self.claudeStatusForCall()
        }
        register(ClaudePlanUsage.self, actors: [.user]) { [unowned self] _, _ in
            await PlanUsageState(usage: self.visiblePlanUsage())
        }
        register(ClaudeReportPlanUsage.self, actors: [.user]) { [unowned self] params, actor in
            try await self.reportPlanUsage(params.usage, actor: actor)
        }
    }
}
