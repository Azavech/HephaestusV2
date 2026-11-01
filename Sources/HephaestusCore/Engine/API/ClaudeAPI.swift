import Foundation

// docs/engine-api.md › Claude.

/// `claude.models`: the cached model list. Actors: user.
public enum ClaudeModels: EngineMethod {
    public static let name = "claude.models"
    public typealias Params = Empty
    public typealias Result = [ClaudeModel]
}

/// `claude.status`: locates the CLI again, runs `--version` and returns the new status.
/// Actors: user.
public enum ClaudeStatusMethod: EngineMethod {
    public static let name = "claude.status"
    public typealias Params = Empty
    public typealias Result = ClaudeStatus
}

/// `claude.planUsage`: the engine's plan usage, without a value when none is known or its reset
/// time has passed (docs/engine-api.md › Plan usage). Actors: user.
public enum ClaudePlanUsage: EngineMethod {
    public static let name = "claude.planUsage"
    public typealias Params = Empty
    public typealias Result = PlanUsageState
}

/// `claude.reportPlanUsage`: a plan usage received from another device's engine, kept when it is
/// newer than the engine's own (docs/remote.md › Plan usage sharing). Actors: user.
public enum ClaudeReportPlanUsage: EngineMethod {
    public static let name = "claude.reportPlanUsage"
    public struct Params: Codable, Sendable, Hashable {
        /// The value as the other engine returned or emitted it.
        public var usage: PlanUsage

        public init(usage: PlanUsage) {
            self.usage = usage
        }
    }
    public typealias Result = PlanUsageState
}
