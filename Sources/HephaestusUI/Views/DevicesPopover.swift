// OWNER: ui-views — the devices popover of the Views section: the devices of `devices.json` by
// family, checked to show their previews, and the custom size (docs/views.md › Devices popover,
// Custom size).
import HephaestusCore
import SwiftUI

/// The devices of `devices.json`, iPhone then iPad, each a checkbox with its size classes and its
/// resolution in the orientation chosen, then the custom size form.
struct DevicesPopover: View {
    let model: PreviewDevicesModel
    @Bindable var state: ViewsSectionState

    /// The width of the popover, the most height of its list, and the height of a row of the list.
    static let width: CGFloat = 520
    static let listHeight: CGFloat = 360
    static let rowHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Devices")
                .font(.headline)
            if let error = model.readError {
                Text("devices.json cannot be read: \(error)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.devices.isEmpty {
                Text("No Devices")
                    .foregroundStyle(.secondary)
            } else {
                let groups = PreviewDeviceCatalog.grouped(model.devices)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.family) { group in
                            Text(group.family.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(height: Self.rowHeight, alignment: .bottom)
                            ForEach(group.devices) { device in
                                DeviceRow(device: device, orientation: state.settings.orientation,
                                          checked: Binding(get: { state.isChecked(device) },
                                                           set: { state.setChecked(device, $0, available: model.devices) }))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(Self.listHeight, CGFloat(model.devices.count + groups.count) * Self.rowHeight))
            }
            Divider()
            CustomSizeForm(model: model, state: state)
        }
        .padding(14)
        .frame(width: Self.width)
    }
}

/// A device of the list: its checkbox and name, then its size classes and its resolution.
private struct DeviceRow: View {
    let device: HephaestusCore.PreviewDevice
    let orientation: PreviewOrientation
    @Binding var checked: Bool

    var body: some View {
        Toggle(isOn: $checked) {
            HStack(spacing: 8) {
                Text(device.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(device.sizeClasses(in: orientation).notation)   \(device.resolution(in: orientation))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .toggleStyle(.checkbox)
        .frame(height: DevicesPopover.rowHeight)
    }
}

/// The custom size: the family, the width and the height, the size classes and Add, which writes
/// the device into `devices.json` and checks it (docs/views.md › Custom size).
private struct CustomSizeForm: View {
    let model: PreviewDevicesModel
    let state: ViewsSectionState
    @State private var family: PreviewDeviceFamily = .iPhone
    @State private var width = ""
    @State private var height = ""
    @State private var horizontal: PreviewSizeClass = .compact
    @State private var vertical: PreviewSizeClass = .regular
    @State private var error: String?

    /// A field's whole number from 50 to 2000; nil otherwise.
    static func points(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), HephaestusCore.PreviewDevice.sizeRange.contains(value) else {
            return nil
        }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Size")
                .font(.subheadline)
            HStack(spacing: 10) {
                Picker("Family", selection: $family) {
                    Text("iPhone").tag(PreviewDeviceFamily.iPhone)
                    Text("iPad").tag(PreviewDeviceFamily.iPad)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("Width")
                TextField("Width", text: $width)
                    .labelsHidden()
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Text("Height")
                TextField("Height", text: $height)
                    .labelsHidden()
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
            }
            HStack(spacing: 10) {
                Picker("Width Class", selection: $horizontal) {
                    ForEach(PreviewSizeClass.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Picker("Height Class", selection: $vertical) {
                    ForEach(PreviewSizeClass.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let error {
                    Text("devices.json cannot be written: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Add", action: add)
                    .disabled(Self.points(width) == nil || Self.points(height) == nil)
            }
        }
    }

    private func add() {
        guard let widthPoints = Self.points(width), let heightPoints = Self.points(height) else { return }
        do {
            let device = try model.addCustomSize(family: family, width: widthPoints, height: heightPoints, horizontal: horizontal,
                                                 vertical: vertical)
            error = nil
            width = ""
            height = ""
            state.setChecked(device, true, available: model.devices)
        } catch {
            self.error = String(describing: error)
        }
    }
}
