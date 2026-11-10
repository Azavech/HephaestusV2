import Foundation

extension Engine {
    /// docs/engine-api.md › Virtual machine images, served by the engine's `VMImageService` and
    /// the configuration's `VMImageProvisioning`. Only the user actor calls these methods.
    func registerVMImageHandlers() {
        register(VMImagesList.self, actors: [.user]) { [unowned self] _, _ in
            await self.vmImageList()
        }
        register(VMImagesVersions.self, actors: [.user]) { [unowned self] _, _ in
            try await self.vmImageVersions()
        }
        register(VMImagesAdd.self, actors: [.user]) { [unowned self] params, actor in
            try await self.addVMImage(params, actor)
        }
        register(VMImagesDelete.self, actors: [.user]) { [unowned self] params, actor in
            try await self.deleteVMImage(params, actor)
        }
        register(VMImagesSetAccount.self, actors: [.user]) { [unowned self] params, actor in
            try await self.setVMImageAccount(params, actor)
        }
    }
}
