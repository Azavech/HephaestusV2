// OWNER: ui-code-docs — the tab of an OpenAPI contract: the mode bar, the Contract view with its
// list and details, and the schema trees (docs/openapi.md › Contract and Source, › Contract view).
import AppKit
import HephaestusCore
import SwiftUI

/// The tab of a detected contract: the mode bar `Contract`, `Source`, then the Contract view or the
/// editor.
struct OpenAPITabView: View {
    let buffer: EditorBuffer
    let workspace: DeviceWorkspace

    var body: some View {
        @Bindable var buffer = buffer
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("Mode", selection: $buffer.showsContract) {
                    Text("Contract").tag(true)
                    Text("Source").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            if buffer.showsContract {
                VStack(spacing: 0) {
                    EditorBannerView(buffer: buffer, showsLargeFileBanner: false)
                    OpenAPIContractView(model: buffer.contractModel, text: buffer.text)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                CodeEditorView(buffer: buffer, workspace: workspace)
            }
        }
    }
}

/// The Contract view: the list and the detail of the selected row, or the parse error.
struct OpenAPIContractView: View {
    let model: OpenAPIContractModel
    /// The buffer's text, read here so that its changes parse the contract again.
    let text: String

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 10) {
                    Text("The contract could not be read.")
                        .font(.headline)
                    Text(message)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: 640, alignment: .leading)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let contract):
                SplitPanes(leadingWidth: $model.listWidth, leadingRange: 180...400, minimumTrailingWidth: 300) {
                    OpenAPIListView(model: model, contract: contract)
                } trailing: {
                    OpenAPIDetailView(model: model, contract: contract)
                }
            }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: text) { model.textChanged() }
    }
}

// MARK: - List

/// The list: the Info row, the operations by tag, the schemas (docs/openapi.md › List).
private struct OpenAPIListView: View {
    let model: OpenAPIContractModel
    let contract: OpenAPIContract

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                row(.info) {
                    HStack(spacing: 6) {
                        Text(contract.info.title.isEmpty ? contract.path : contract.info.title)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(contract.info.version)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ForEach(contract.groups) { group in
                    header(group.name)
                        .help(group.description ?? "")
                    ForEach(group.operations) { operation in
                        row(.operation(operation.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    MethodBadge(method: operation.method)
                                    Text(operation.path)
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if let summary = operation.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                if !contract.schemas.isEmpty {
                    header("Schemas")
                    ForEach(contract.schemas) { schema in
                        row(.schema(schema.name)) {
                            Text(schema.name)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }

    /// A row is a button so that a click selects it.
    private func row(_ selection: OpenAPIContractModel.Selection, @ViewBuilder content: () -> some View) -> some View {
        let isSelected = model.selection == selection
        return Button {
            model.selection = selection
        } label: {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}

/// A method in a capsule with the Swagger UI colors (docs/openapi.md › List).
struct MethodBadge: View {
    let method: String

    static func color(of method: String) -> Color {
        let hex: UInt32
        switch method.lowercased() {
        case "get": hex = 0x61AFFE
        case "post": hex = 0x49CC90
        case "put": hex = 0xFCA130
        case "delete": hex = 0xF93E3E
        case "patch": hex = 0x50E3C2
        default: hex = 0x9B9B9B
        }
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var body: some View {
        Text(method.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(width: 52, height: 17)
            .background(Capsule().fill(Self.color(of: method)))
    }
}

// MARK: - Details

/// The detail of the selected row.
private struct OpenAPIDetailView: View {
    let model: OpenAPIContractModel
    let contract: OpenAPIContract

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.selection {
                case .info:
                    OpenAPIInfoDetail(contract: contract)
                case .operation(let id):
                    if let operation = contract.operations.first(where: { $0.id == id }) {
                        OpenAPIOperationDetail(model: model, contract: contract, operation: operation)
                            .id(operation.id)
                    }
                case .schema(let name):
                    if let schema = contract.schemas.first(where: { $0.name == name }) {
                        Text(schema.name)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        if schema.schema.isUnresolved {
                            UnresolvedRow(label: nil, ref: schema.schema.ref ?? "")
                        } else {
                            if let description = schema.schema.description {
                                MarkdownText(description)
                            }
                            OpenAPISchemaChildren(schema: schema.schema)
                                .id(schema.name)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Descriptions: inline Markdown rendered, block structure kept as plain text.
struct MarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A section title of a detail.
struct DetailSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.top, 4)
    }
}

/// The Info detail (docs/openapi.md › Info detail).
private struct OpenAPIInfoDetail: View {
    let contract: OpenAPIContract

    var body: some View {
        let info = contract.info
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(info.title)
                    .font(.title2.weight(.semibold))
                Text(info.version)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            Text("OpenAPI \(contract.version)")
                .foregroundStyle(.secondary)
            if let summary = info.summary {
                MarkdownText(summary)
            }
            if let description = info.description {
                MarkdownText(description)
            }
            if let terms = info.termsOfService {
                labelled("Terms of Service") { link(terms, url: terms) }
            }
            if info.contactName != nil || info.contactEmail != nil || info.contactURL != nil {
                labelled("Contact") {
                    if let name = info.contactName { Text(name) }
                    if let email = info.contactEmail { link(email, url: "mailto:\(email)") }
                    if let url = info.contactURL { link(url, url: url) }
                }
            }
            if let license = info.licenseName {
                labelled("License") {
                    Text(license)
                    if let url = info.licenseURL {
                        link(url, url: url)
                    } else if let identifier = info.licenseIdentifier {
                        Text(identifier)
                    }
                }
            }
            if !contract.servers.isEmpty {
                DetailSectionTitle(title: "Servers")
                ForEach(Array(contract.servers.enumerated()), id: \.offset) { _, server in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(server.url)
                            .font(.system(size: 12, design: .monospaced))
                        if let description = server.description {
                            Text(description)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func link(_ text: String, url: String) -> some View {
        if let target = URL(string: url) {
            Link(text, destination: target)
        } else {
            Text(text)
        }
    }
}

/// The Operation detail (docs/openapi.md › Operation detail).
private struct OpenAPIOperationDetail: View {
    let model: OpenAPIContractModel
    let contract: OpenAPIContract
    let operation: OpenAPIOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MethodBadge(method: operation.method)
                Text(operation.path)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let summary = operation.summary {
                Text(summary)
                    .font(.headline)
            }
            if let description = operation.description {
                MarkdownText(description)
            }
            if !operation.parameters.isEmpty || !operation.unresolvedParameters.isEmpty {
                DetailSectionTitle(title: "Parameters")
                ForEach(operation.parameters) { parameter in
                    OpenAPISchemaRow(label: parameter.name, schema: parameter.schema, isRequired: parameter.isRequired,
                                     location: parameter.location.rawValue, descriptionOverride: parameter.description)
                }
                ForEach(operation.unresolvedParameters, id: \.self) { ref in
                    UnresolvedRow(label: nil, ref: ref)
                }
            }
            if let body = operation.requestBody {
                DetailSectionTitle(title: "Request Body")
                if let ref = body.unresolvedRef {
                    UnresolvedRow(label: nil, ref: ref)
                }
                if body.isRequired {
                    RequiredTag()
                }
                if let description = body.description {
                    MarkdownText(description)
                }
                ForEach(body.content) { media in
                    MediaTypeView(media: media)
                }
            }
            if !operation.responses.isEmpty {
                DetailSectionTitle(title: "Responses")
                ForEach(operation.responses) { response in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(response.code)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            if let description = response.description {
                                MarkdownText(description)
                            }
                        }
                        if let ref = response.unresolvedRef {
                            UnresolvedRow(label: nil, ref: ref)
                        }
                        ForEach(response.content) { media in
                            MediaTypeView(media: media)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            DetailSectionTitle(title: "Request")
            OpenAPIRequestFormView(model: model, contract: contract, operation: operation, form: model.form(operation))
            OpenAPIResponseView(form: model.form(operation))
        }
    }
}

/// A media type with its schema tree.
private struct MediaTypeView: View {
    let media: OpenAPIMediaType

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(media.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            if let schema = media.schema {
                OpenAPISchemaRow(label: nil, schema: schema, isRequired: false)
                    .padding(.leading, 8)
            }
        }
    }
}

struct RequiredTag: View {
    var body: some View {
        Text("required")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: .systemRed))
    }
}

// MARK: - Schema trees (docs/openapi.md › Schema trees)

/// `Unresolved` and the ref as written.
private struct UnresolvedRow: View {
    let label: String?
    let ref: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let label {
                Text(label)
                    .font(.system(size: 12, design: .monospaced))
            }
            Text("Unresolved")
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(ref)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// One row of a schema tree, with its children under a disclosure triangle.
struct OpenAPISchemaRow: View {
    let label: String?
    let schema: OpenAPISchema?
    let isRequired: Bool
    var location: String?
    var descriptionOverride: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let schema, schema.isUnresolved {
                UnresolvedRow(label: label, ref: schema.ref ?? "")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if schema?.hasChildren == true {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .frame(width: 12)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Color.clear.frame(width: 12, height: 1)
                    }
                    if let label {
                        Text(label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let location {
                        Text(location)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let schema {
                        Text(schema.typeSummary)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let format = schema.format {
                            Text(format)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if isRequired {
                        RequiredTag()
                    }
                }
                let enumValues = schema?.enumValues.compactMap { $0.scalarText ?? $0.jsonText(pretty: false) } ?? []
                if !enumValues.isEmpty {
                    Text("enum: \(enumValues.joined(separator: ", "))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)
                        .textSelection(.enabled)
                }
                if let description = descriptionOverride ?? schema?.description {
                    MarkdownText(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)
                }
                if isExpanded, let schema {
                    OpenAPISchemaChildren(schema: schema)
                        .padding(.leading, 18)
                }
            }
        }
    }
}

/// The children rows of a schema: properties, `additionalProperties`, `items`, compositions.
struct OpenAPISchemaChildren: View {
    let schema: OpenAPISchema

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(schema.properties) { property in
                OpenAPISchemaRow(label: property.name, schema: property.schema, isRequired: property.isRequired)
            }
            if let additional = schema.additionalProperties {
                OpenAPISchemaRow(label: "additionalProperties", schema: additional, isRequired: false)
            }
            if let items = schema.items {
                OpenAPISchemaRow(label: "items", schema: items, isRequired: false)
            }
            ForEach(OpenAPISchema.compositionKeywords, id: \.self) { keyword in
                let members = schema.composition(keyword)
                if !members.isEmpty {
                    CompositionRow(keyword: keyword, members: members)
                }
            }
        }
    }
}

/// `allOf`, `oneOf` or `anyOf`, whose children are its schemas labelled `1`, `2`, and so on.
private struct CompositionRow: View {
    let keyword: String
    let members: [OpenAPISchema]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                Text(keyword)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(members.enumerated()), id: \.offset) { index, member in
                        OpenAPISchemaRow(label: String(index + 1), schema: member, isRequired: false)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}
