// OWNER: ui-shell — the `Device ▸ Project ▸ Sub project` selector (docs/ui.md › Breadcrumb selector;
// docs/projects.md › Project selector).
import AppKit
import HephaestusCore
import SwiftUI

/// The principal toolbar item: up to three segments separated by `chevron.right`.
struct BreadcrumbSelector: View {
    let window: WindowState
    let workspace: DeviceWorkspace?
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 4) {
            deviceSegment
            chevron
            projectSegment
            if let topLevel, !(workspace?.descendants(of: topLevel.id).isEmpty ?? true) {
                chevron
                subProjectSegment(topLevel)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var connected: Bool {
        workspace?.isConnected ?? false
    }

    /// The active project's top-level project.
    private var topLevel: ProjectSummary? {
        guard let projectID = window.projectID else { return nil }
        return workspace?.topLevelProject(of: projectID)
    }

    // MARK: Device

    private var deviceSegment: some View {
        let isLocal = window.deviceID == app.localDeviceID
        let title = isLocal ? "This Mac" : app.deviceName(window.deviceID)
        let dot = isLocal ? nil : NSColor(DeviceStatePresentation(workspace: workspace).color)
        return MenuSegmentButton(symbol: "laptopcomputer", title: title, titleDot: dot) {
            var entries: [SegmentMenuEntry] = []
            for device in app.devices {
                if device.isLocal {
                    entries.append(.item("This Mac", checked: window.deviceID == device.id) {
                        window.switchDevice(to: device.id)
                    })
                    entries.append(.separator)
                } else {
                    entries.append(.item(device.name, dot: device.online ? .systemGreen : .systemGray,
                                         checked: window.deviceID == device.id) {
                        window.switchDevice(to: device.id)
                    })
                }
            }
            if app.devices.count > 1 {
                entries.append(.separator)
            }
            entries.append(.item("Add Device…") {
                window.sheet = .addDevice(deviceID: nil)
            })
            entries.append(.item("Manage Devices…") {
                app.openSettings(tab: .devices)
            })
            return entries
        }
    }

    // MARK: Project

    private var projectSegment: some View {
        let title = topLevel?.name ?? "No Project"
        return MenuSegmentButton(symbol: "folder", title: title, enabled: connected) {
            guard let workspace else { return [] }
            var entries: [SegmentMenuEntry] = workspace.projects.filter { $0.parentID == nil }.map { project in
                .item(project.name, checked: project.id == topLevel?.id) {
                    window.activate(projectID: project.id)
                }
            }
            if !entries.isEmpty {
                entries.append(.separator)
            }
            entries.append(.item("New Project…") {
                window.sheet = .newProject
            })
            entries.append(.item("Open Project…") {
                ProjectFlows.openProject(window: window, workspace: workspace)
            })
            return entries
        }
    }

    // MARK: Sub project

    private func subProjectSegment(_ topLevel: ProjectSummary) -> some View {
        let activeID = window.projectID
        let title = activeID == topLevel.id ? "\(topLevel.name) (root)" : (workspace?.project(activeID ?? "")?.name ?? "")
        return MenuSegmentButton(symbol: "folder", title: title, enabled: connected) {
            guard let workspace else { return [] }
            var entries: [SegmentMenuEntry] = [
                .item("\(topLevel.name) (root)", checked: activeID == topLevel.id) {
                    window.activate(projectID: topLevel.id)
                },
            ]
            for (project, depth) in workspace.descendants(of: topLevel.id) {
                entries.append(.item(project.name, checked: activeID == project.id, indentation: depth) {
                    window.activate(projectID: project.id)
                })
            }
            entries.append(.separator)
            entries.append(.item("New Sub Project…") {
                if let projectID = window.projectID {
                    window.sheet = .newSubProject(parentID: projectID)
                }
            })
            return entries
        }
    }
}
