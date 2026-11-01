import Foundation

extension Engine {
    /// docs/engine-api.md › Attachments.
    func registerAttachmentHandlers() {
        register(AttachmentsRead.self, actors: [.user]) { [unowned self] params, actor in
            try await self.attachmentsRead(params, actor)
        }
    }

    // STUB: core-domain — docs/engine-api.md › attachments.read.
    func attachmentsRead(_ params: AttachmentsRead.Params, _ actor: Actor) async throws -> BinaryContent {
        throw EngineError.notImplemented(AttachmentsRead.name)
    }
}
