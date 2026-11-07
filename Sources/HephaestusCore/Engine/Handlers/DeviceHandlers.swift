import Foundation

extension Engine {
    /// docs/engine-api.md › Device and snapshot.
    func registerDeviceHandlers() {
        register(DeviceInfoMethod.self, actors: [.user]) { [unowned self] _, _ in
            await self.deviceInfo
        }
        register(SnapshotGet.self, actors: [.user]) { [unowned self] _, _ in
            await self.snapshot()
        }
    }

    /// `snapshot.get`, built in one step on the actor, so no event falls between its parts:
    /// the device, the `projects.list` result, the `skills.list` result (empty when the library
    /// cannot be read), the host settings, the running runs, the Claude CLI status and the plan
    /// usage.
    func snapshot() -> Snapshot {
        let hidden = hiddenProjectIDs
        return Snapshot(device: deviceInfo, projects: projectSummaries(), skills: skillSummaries(), settings: settings,
                        runs: runs.runningRuns().filter { !hidden.contains($0.projectID) }, claude: claudeCLI.status,
                        planUsage: visiblePlanUsage())
    }
}
