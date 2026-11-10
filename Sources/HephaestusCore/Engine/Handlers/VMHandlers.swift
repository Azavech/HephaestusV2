import Foundation

extension Engine {
    /// docs/engine-api.md › Virtual machines, served by the engine's `VirtualMachineService`. Only
    /// the user actor calls these methods; `vms.create` starts a virtual machine of the user.
    func registerVMHandlers() {
        register(VMsList.self, actors: [.user]) { [unowned self] _, _ in
            await self.virtualMachineList()
        }
        register(VMsCreate.self, actors: [.user]) { [unowned self] params, actor in
            try await self.createVirtualMachine(params, startedBy: .user, actor)
        }
        register(VMsStart.self, actors: [.user]) { [unowned self] params, actor in
            try await self.startVirtualMachine(params.vmID, actor)
        }
        register(VMsStop.self, actors: [.user]) { [unowned self] params, actor in
            try await self.stopVirtualMachine(params.vmID, actor)
        }
        register(VMsUpdate.self, actors: [.user]) { [unowned self] params, actor in
            try await self.updateVirtualMachine(params, actor)
        }
        register(VMsDelete.self, actors: [.user]) { [unowned self] params, actor in
            try await self.deleteVirtualMachine(params.vmID, actor)
        }
    }
}
