import Foundation
import Testing
@testable import HephaestusCore

/// docs/virtual-machines.md › Previews: the screenshots of the previews of the Virtual Machines
/// popover, taken by the guest agent, with stand-ins for the virtual machines.
@Suite("Virtual machine previews")
struct VMScreenPreviewTests {
    @Test("A running virtual machine gives a preview only while its agent is connected")
    func machinePreview() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let image = try await addReadyImage(engine, connection, provisioner)
            let created = try await createVM(connection, image: image)
            let session = try #require(await engine.virtualMachineSession(created.id))
            let machine = try #require(await MainActor.run { provisioner.machines.last })

            #expect(await session.capturePreview() == nil)
            await MainActor.run { machine.agentConnects(sip: .disabled) }
            #expect(await session.capturePreview() == FakeGuestMachine.previewPNG)
            await MainActor.run { machine.agentDisconnects() }
            #expect(await session.capturePreview() == nil)
        }
    }

    @Test("A setup virtual machine gives a preview while its agent is connected, and runs from its start")
    func setupPreview() async throws {
        try await withVMEngine { engine, connection, provisioner, _ in
            let image = try await addInstalledImage(connection)
            let before = Date()
            let session = try await engine.beginImageSetup(image.id)
            let machine = try #require(await MainActor.run { provisioner.machines.last })
            #expect(await session.startedAt >= before)

            #expect(await session.capturePreview() == nil)
            await MainActor.run { machine.agentConnects(sip: .enabled) }
            #expect(await session.capturePreview() == FakeGuestMachine.previewPNG)
            await session.stopNow()
        }
    }
}

/// The stand-in answers every screenshot with the same bytes.
extension FakeGuestMachine: GuestPreviewCapturing {
    nonisolated static let previewPNG = Data("png".utf8)

    func capturePreviewPNG() async throws -> Data {
        Self.previewPNG
    }
}
