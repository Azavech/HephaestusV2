// OWNER: ui-shell — the Guest Account section of Settings ▸ Virtual Machines (docs/ui.md › Virtual
// Machines; docs/virtual-machines.md › Guest account).
import HephaestusCore
import SwiftUI

/// The texts of the Guest Account section.
enum GuestAccountPresentation {
    static let sectionLabel = "Guest Account"
    static let userNameLabel = "User name"
    static let passwordLabel = "Password"

    /// The params of `vmImages.setAccount` for the fields' values: only the values that differ from
    /// the stored ones; nil when none does. The user name is compared trimmed, as it is stored.
    static func changes(of image: VMImage, userName: String, password: String) -> VMImagesSetAccount.Params? {
        let storedUserName = image.userName ?? ""
        let storedPassword = image.password ?? ""
        let newUserName = userName.trimmingCharacters(in: .whitespacesAndNewlines) == storedUserName ? nil : userName
        let newPassword = password == storedPassword ? nil : password
        guard newUserName != nil || newPassword != nil else { return nil }
        return VMImagesSetAccount.Params(imageID: image.id, userName: newUserName, password: newPassword)
    }
}

/// The user name and the password of the guest account of the image selected in the Images
/// table, stored with `vmImages.setAccount` on Return or the loss of the focus. Without an image,
/// both fields are empty and disabled.
struct GuestAccountSection: View {
    let image: VMImage?
    @Environment(AppModel.self) private var app
    @State private var userName = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var message: String?
    @FocusState private var focused: Field?

    enum Field: Hashable {
        case userName
        case password
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text(GuestAccountPresentation.userNameLabel)
                    .gridColumnAlignment(.trailing)
                TextField(GuestAccountPresentation.userNameLabel, text: $userName)
                    .labelsHidden()
                    .focused($focused, equals: .userName)
                    .onSubmit { commit(image) }
            }
            GridRow {
                Text(GuestAccountPresentation.passwordLabel)
                Group {
                    if showsPassword {
                        TextField(GuestAccountPresentation.passwordLabel, text: $password)
                    } else {
                        SecureField(GuestAccountPresentation.passwordLabel, text: $password)
                    }
                }
                .labelsHidden()
                .focused($focused, equals: .password)
                .onSubmit { commit(image) }
                Button {
                    showsPassword.toggle()
                } label: {
                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
        }
        .disabled(image == nil)
        .onAppear(perform: load)
        .onChange(of: image?.id) { old, _ in
            // A value being typed is stored for the image it was typed for first.
            if let old, let previous = app.localWorkspace.vmImages?.first(where: { $0.id == old }) {
                commit(previous)
            }
            message = nil
            load()
        }
        .onChange(of: image?.userName) { _, stored in
            if focused != .userName {
                userName = stored ?? ""
            }
        }
        .onChange(of: image?.password) { _, stored in
            if focused != .password {
                password = stored ?? ""
            }
        }
        .onChange(of: focused) { old, _ in
            if old != nil {
                commit(image)
            }
        }
        FieldMessage(text: message)
    }

    /// Shows the stored account of the selected image; empty without one.
    private func load() {
        userName = image?.userName ?? ""
        password = image?.password ?? ""
    }

    /// Stores the values that changed for `image`; a refused value shows its message in red and
    /// stays in its field.
    private func commit(_ image: VMImage?) {
        guard let image, let params = GuestAccountPresentation.changes(of: image, userName: userName, password: password) else {
            return
        }
        Task {
            do {
                let stored = try await app.localWorkspace.call(VMImagesSetAccount.self, params)
                message = nil
                if stored.id == self.image?.id, focused == nil {
                    userName = stored.userName ?? ""
                    password = stored.password ?? ""
                }
            } catch {
                message = errorMessage(error)
            }
        }
    }
}
