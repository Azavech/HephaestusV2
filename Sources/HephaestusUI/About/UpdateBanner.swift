// OWNER: release — the update-ready banner over the main window's columns (docs/updater.md › Update-ready banner).
import HephaestusCore
import SwiftUI

/// Shown when the Updater's state is `ready` and the user did not choose Install; 36 points high, full width.
/// It has no close button and disappears when the restart sequence starts or the state leaves `ready`.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let controller = app.updateController
        if controller.bannerVisible {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(controller.bannerText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Restart Now") {
                    controller.restartNow()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }
}
