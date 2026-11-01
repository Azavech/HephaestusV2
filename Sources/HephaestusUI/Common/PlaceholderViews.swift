// OWNER: ui-shell — placeholders of the skeleton's stub views and sheets; each owner replaces its
// uses when it implements its views (no document section).
import SwiftUI

/// The body of a stub view: the name of the view it stands for.
struct PlaceholderView: View {
    let name: String

    var body: some View {
        Text(name)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The body of a stub sheet: the name of the sheet and its Cancel button (Escape), which closes it.
struct PlaceholderSheet: View {
    let name: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(name)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
