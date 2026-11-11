import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/views.md › Preview settings, Devices file: the devices checked by name with the first
/// iPhone checked at first, and the model of `devices.json` that writes a missing file.
@Suite("Device previews settings")
@MainActor
struct DevicePreviewsUITests {
    static let devices = PreviewDeviceCatalog.builtIn

    @Test("The first iPhone is checked at first; the settings get the checked devices in the order of the file")
    func defaultDevice() {
        let state = ViewsSectionState(appearance: .light)
        state.syncDevices([])
        #expect(state.settings.devices.isEmpty)
        let iPad = Self.devices.first { $0.family == .iPad }!
        state.syncDevices([iPad] + Self.devices.filter { $0.family == .iPhone })
        #expect(state.settings.devices.map(\.name) == ["iPhone 18 Pro"])
        state.setChecked(iPad, true, available: Self.devices)
        #expect(state.settings.devices.map(\.name) == ["iPhone 18 Pro", iPad.name])
        state.setChecked(Self.devices[0], false, available: Self.devices)
        #expect(state.settings.devices.map(\.name) == [iPad.name])
        // Unchecking every device does not check the first iPhone again.
        state.setChecked(iPad, false, available: Self.devices)
        state.syncDevices(Self.devices)
        #expect(state.settings.devices.isEmpty)
    }

    @Test("A device the file no longer lists is no longer checked; a device whose values change shows them")
    func fileChanges() {
        let state = ViewsSectionState(appearance: .light)
        state.syncDevices(Self.devices)
        var changed = Self.devices
        changed[0].width = 410
        state.syncDevices(changed)
        #expect(state.settings.devices.first?.width == 410)
        state.syncDevices(Array(Self.devices.dropFirst()))
        #expect(state.settings.devices.isEmpty)
        state.syncDevices(Self.devices)
        #expect(state.settings.devices.isEmpty)
    }

    @Test("The model writes a missing file with the built-in devices, reads a device added by hand, and writes a removed file again")
    func model() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("devices-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(PreviewDeviceCatalog.fileName)
        let model = PreviewDevicesModel(file: file)
        defer { model.stop() }
        #expect(model.devices == PreviewDeviceCatalog.builtIn)
        let added = try model.addCustomSize(family: .iPad, width: 500, height: 700, horizontal: .compact, vertical: .regular)
        #expect(added.name == "Custom 500 × 700")
        #expect(model.devices.last == added)
        try Data("not json".utf8).write(to: file)
        model.reload()
        #expect(model.devices.isEmpty)
        #expect(model.readError == "it is not valid JSON")
        try FileManager.default.removeItem(at: file)
        model.reload()
        #expect(model.devices == PreviewDeviceCatalog.builtIn)
        #expect(model.readError == nil)
    }

    @Test("The model reads the file again after a change on disk")
    func watching() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("devices-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(PreviewDeviceCatalog.fileName)
        let model = PreviewDevicesModel(file: file)
        defer { model.stop() }
        try await Task.sleep(for: .milliseconds(300))
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"name\": \"iPhone 18 Pro\",", with: "\"name\": \"Hand Phone\",")
        try text.write(to: file, atomically: false, encoding: .utf8)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.devices.first?.name != "Hand Phone", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.devices.first?.name == "Hand Phone")
    }
}
