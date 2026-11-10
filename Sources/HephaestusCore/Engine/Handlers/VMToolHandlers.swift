import Foundation

extension Engine {
    /// docs/engine-api.md › VM tools, served by the engine's `VMToolService`: the methods of the
    /// VM tools of the MCP server, for the chat's own Claude only.
    func registerVMToolHandlers() {
        register(VMToolsImages.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolImages(params, actor)
        }
        register(VMToolsList.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolList(params, actor)
        }
        register(VMToolsStart.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolStart(params, actor)
        }
        register(VMToolsStop.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolStop(params, actor)
        }
        register(VMToolsScreenshot.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolScreenshot(params, actor)
        }
        register(VMToolsClick.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolClick(params, actor)
        }
        register(VMToolsDrag.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolDrag(params, actor)
        }
        register(VMToolsScroll.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolScroll(params, actor)
        }
        register(VMToolsType.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolType(params, actor)
        }
        register(VMToolsKey.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolKey(params, actor)
        }
        register(VMToolsUITree.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolUITree(params, actor)
        }
        register(VMToolsShell.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolShell(params, actor)
        }
        register(VMToolsCopyIn.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolCopyIn(params, actor)
        }
        register(VMToolsCopyOut.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.vmToolCopyOut(params, actor)
        }
    }
}
