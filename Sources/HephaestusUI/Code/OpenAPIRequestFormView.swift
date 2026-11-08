// OWNER: ui-code-docs — the request form of an operation and its response (docs/openapi.md ›
// Request form, › Response).
import AppKit
import HephaestusCore
import SwiftUI

/// Environment, Parameters, Credentials, Body, Headers and Send.
struct OpenAPIRequestFormView: View {
    let model: OpenAPIContractModel
    let contract: OpenAPIContract
    let operation: OpenAPIOperation
    let form: OpenAPIOperationForm

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            environmentPart
            parametersPart
            credentialsPart
            bodyPart
            headersPart
            HStack(spacing: 8) {
                if form.isSending {
                    Button("Cancel") { form.cancel() }
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Send") { model.send(operation) }
                        .disabled(!model.canSend)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    // MARK: Environment (docs/openapi.md › Environment)

    /// The pop-up of the project's environments, `<name> · <base URL>` each, or `<name>` alone
    /// for an environment without a URL; empty and disabled, with the note and `Project
    /// Settings…`, when the project has none. While an environment without a URL is selected, the
    /// note asks for its API Access, with `Project Settings…` too.
    private var environmentPart: some View {
        let items = Array(model.environments.enumerated())
        return part("Environment") {
            Picker("Environment", selection: Binding(get: { model.environment?.name },
                                                     set: { name in if let name { model.selectEnvironment(name) } })) {
                ForEach(items, id: \.offset) { _, environment in
                    Text(Self.itemTitle(environment)).tag(Optional(environment.name))
                }
                if items.isEmpty {
                    // The empty pop-up's selection, so that it has a tag.
                    Text("").tag(String?.none)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
            .disabled(items.isEmpty)
            if let note = items.isEmpty ? Self.noEnvironmentNote : model.environment?.url == nil ? Self.noURLNote : nil {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Project Settings…") {
                    model.showProjectSettings()
                }
            }
        }
    }

    static let noEnvironmentNote = "Add an environment in Project Settings."
    static let noURLNote = "Set the API Access of this environment in Project Settings."

    /// The pop-up item of an environment: `<name> · <base URL>`, or the name alone without a URL.
    static func itemTitle(_ environment: ProjectEnvironment) -> String {
        environment.baseURL.map { "\(environment.name) · \($0)" } ?? environment.name
    }

    // MARK: Parameters (docs/openapi.md › Parameters)

    @ViewBuilder
    private var parametersPart: some View {
        if !operation.parameters.isEmpty {
            part("Parameters") {
                ForEach(OpenAPIParameterLocation.allCases, id: \.self) { location in
                    let parameters = operation.parameters.filter { $0.location == location }
                    if !parameters.isEmpty {
                        Text(location.rawValue)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        ForEach(parameters) { parameter in
                            fieldRow(parameter.name, isRequired: parameter.isRequired) {
                                TextField(parameter.schema?.typeSummary ?? "", text: Binding(
                                    get: { model.storedOperation(operation).parameters[parameter.id] ?? "" },
                                    set: { value in model.updateOperation(operation) { $0.parameters[parameter.id] = value } }))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Credentials (docs/openapi.md › Credentials)

    @ViewBuilder
    private var credentialsPart: some View {
        let schemes = contract.credentialSchemes(for: operation)
        if !schemes.isEmpty {
            part("Credentials") {
                ForEach(schemes) { scheme in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scheme.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        if let description = scheme.description {
                            MarkdownText(description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        switch scheme.kind {
                        case .apiKey(let name, let location):
                            fieldRow("\(name) (\(location))") {
                                TextField("", text: credential(scheme, \.value))
                            }
                        case .basic:
                            fieldRow("Username") {
                                TextField("", text: credential(scheme, \.username))
                            }
                            fieldRow("Password") {
                                SecureField("", text: credential(scheme, \.password))
                            }
                        case .bearer:
                            fieldRow("Token") {
                                SecureField("", text: credential(scheme, \.token))
                            }
                        case .unsupported:
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    private func credential(_ scheme: OpenAPISecurityScheme,
                            _ field: WritableKeyPath<OpenAPIStoredCredential, String?>) -> Binding<String> {
        Binding(get: { model.stored?.credentials[scheme.name]?[keyPath: field] ?? "" },
                set: { value in
                    model.update { values in
                        var credential = values.credentials[scheme.name] ?? OpenAPIStoredCredential()
                        credential[keyPath: field] = value
                        values.credentials[scheme.name] = credential
                    }
                })
    }

    // MARK: Body (docs/openapi.md › Body)

    @ViewBuilder
    private var bodyPart: some View {
        if let requestBody = operation.requestBody, let media = model.mediaType(operation) {
            part("Body") {
                HStack(spacing: 8) {
                    if requestBody.content.count > 1 {
                        Picker("Media Type", selection: Binding(
                            get: { media.name },
                            set: { name in model.updateOperation(operation) { $0.mediaType = name } })) {
                            ForEach(requestBody.content) { item in
                                Text(item.name).tag(item.name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        Text(media.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if requestBody.isRequired {
                        RequiredTag()
                    }
                }
                BodyEditor(model: model, operation: operation, media: media, editor: model.bodyModel(operation, media))
            }
        }
    }

    // MARK: Headers (docs/openapi.md › Headers)

    private var headersPart: some View {
        let headers = model.stored?.headers ?? []
        return part("Headers") {
            ForEach(Array(headers.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 6) {
                    TextField("Name", text: header(index, \.name))
                        .frame(maxWidth: 200)
                    TextField("Value", text: header(index, \.value))
                    Button {
                        model.update { values in
                            if values.headers.indices.contains(index) { values.headers.remove(at: index) }
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add Header") {
                model.update { $0.headers.append(OpenAPIHeader(name: "", value: "")) }
            }
        }
    }

    private func header(_ index: Int, _ field: WritableKeyPath<OpenAPIHeader, String>) -> Binding<String> {
        Binding(get: { (model.stored?.headers.indices.contains(index) ?? false) ? model.stored?.headers[index][keyPath: field] ?? "" : "" },
                set: { value in
                    model.update { values in
                        if values.headers.indices.contains(index) { values.headers[index][keyPath: field] = value }
                    }
                })
    }

    // MARK: Layout

    private func part(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    /// A label, `required` when it applies, and the field under them.
    private func fieldRow(_ label: String, isRequired: Bool = false, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isRequired {
                    RequiredTag()
                }
            }
            field()
                .frame(maxWidth: 420, alignment: .leading)
        }
    }
}

/// The 200 pt editor of a media type's body.
private struct BodyEditor: View {
    let model: OpenAPIContractModel
    let operation: OpenAPIOperation
    let media: OpenAPIMediaType
    let editor: EditorTextModel

    var body: some View {
        SourceEditorView(model: editor)
            .frame(height: 200)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            .onChange(of: editor.text) { _, text in
                model.bodyChanged(operation, media, text: text)
            }
    }
}

// MARK: - Response (docs/openapi.md › Response)

/// The last response of the form, or the failure of its request.
struct OpenAPIResponseView: View {
    let form: OpenAPIOperationForm

    var body: some View {
        if let result = form.result {
            VStack(alignment: .leading, spacing: 8) {
                DetailSectionTitle(title: "Response")
                switch result {
                case .failure(let message):
                    Text("The request failed.")
                        .fontWeight(.semibold)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                case .response(let response, let body):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(response.statusText)
                            .fontWeight(.bold)
                        Text("\(response.milliseconds) ms")
                            .foregroundStyle(.secondary)
                    }
                    if !response.headers.isEmpty {
                        Text("Headers")
                            .font(.system(size: 12, weight: .semibold))
                        Text(response.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ResponseBodyView(content: body, form: form)
                }
            }
        }
    }
}

/// The body of a response: the read-only editor, or `Binary body (<size>)` with Quick Look.
private struct ResponseBodyView: View {
    let content: OpenAPIResponseBody
    let form: OpenAPIOperationForm

    var body: some View {
        switch content.kind {
        case .empty:
            EmptyView()
        case .text:
            if let editor = form.responseEditor {
                Text("Body")
                    .font(.system(size: 12, weight: .semibold))
                SourceEditorView(model: editor)
                    .frame(height: 300)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            }
        case .binary(let data):
            Text("Body")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                Text("Binary body (\(ByteSize.text(data.count)))")
                    .foregroundStyle(.secondary)
                Button("Quick Look") {
                    QuickLookPresenter.shared.show(data: data, name: content.quickLookName)
                }
            }
        }
    }
}
