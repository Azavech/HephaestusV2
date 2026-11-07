// OWNER: ui-skills-feedback — the project that receives feedback and the visibility of the feedback
// entry points (docs/feedback.md › Feedback project, › Starting feedback).
import AppKit
import HephaestusCore

/// Feedback always goes to the HephaestusV2 project of the receiving device: its project `HEPH`,
/// which the engine loads only for a clone of the app's repository (docs/feedback.md › Feedback
/// project).
@MainActor
enum FeedbackProject {
    /// The identifier of the HephaestusV2 project.
    static let projectID = HephaestusRepository.identifier

    /// The receiving device's HephaestusV2 project; nil while it is not loaded, being cloned,
    /// failed or hidden.
    static func project(in workspace: DeviceWorkspace?) -> ProjectSummary? {
        workspace?.project(projectID)
    }

    /// True while the device hides its HephaestusV2 project: its feedback entry points are hidden.
    /// False before the device's settings are known (docs/feedback.md › Starting feedback).
    static func hidesFeedback(_ workspace: DeviceWorkspace?) -> Bool {
        workspace?.settings?.showHephaestusProject == false
    }

    /// The receiving device of a window: the window's device for a main window, the chat's device
    /// for a chat window, This Mac for any other window (docs/feedback.md › Starting feedback).
    static func receivingDeviceID(of window: NSWindow?, app: AppModel) -> String {
        guard let window else { return app.localDeviceID }
        switch app.windowRegistry.role(of: window) {
        case .main(let id):
            return app.windows[id]?.deviceID ?? app.localDeviceID
        case .chat(let value):
            return value.deviceID
        default:
            return app.localDeviceID
        }
    }

    /// The receiving device of a feedback source.
    static func receivingDeviceID(of source: FeedbackSource, app: AppModel) -> String {
        switch source {
        case .main(let state): return state.deviceID
        case .chat(let value): return value.deviceID
        case .other: return app.localDeviceID
        }
    }
}
