// OWNER: release — the About window's content (docs/updater.md › About window).
import AppKit
import SwiftUI
import UpdaterCore

/// The app icon, the name, the version and the update area, centred; 360 points wide, height
/// fitting its content. Each time the window appears, the app posts `check` when the Updater runs.
struct AboutView: View {
    @Environment(AppModel.self) private var app
    /// Not Now hides the two buttons until the window closes.
    @State private var notNowClicked = false

    var body: some View {
        let controller = app.updateController
        let area = controller.aboutArea(notNowClicked: notNowClicked)
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("HephaestusV2")
                .font(.title)
            Text(app.appVersion.aboutLine)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            updateArea(area, controller: controller)
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            notNowClicked = false
            controller.aboutWindowAppeared()
        }
    }

    @ViewBuilder
    private func updateArea(_ area: UpdateArea, controller: UpdateController) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                if area.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(area.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch area.controls {
            case .none:
                EmptyView()
            case .tryAgain:
                Button("Try Again") {
                    controller.tryAgain()
                }
            case .installOrNotNow:
                HStack(spacing: 8) {
                    Button("Not Now") {
                        notNowClicked = true
                    }
                    Button("Install") {
                        controller.install()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
