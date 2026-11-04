// OWNER: ui-code-docs — the state of an OpenAPI contract's Contract view: parsing, the selection,
// the request forms with their stored values, sending and the responses (docs/openapi.md).
import Foundation
import HephaestusCore
import HephaestusText
import Observation
import UniformTypeIdentifiers

/// The state of one tab's Contract view, held by its buffer and never persisted.
@MainActor @Observable
final class OpenAPIContractModel {
    enum State {
        case loading
        case loaded(OpenAPIContract)
        case failed(String)
    }

    /// A row of the list (docs/openapi.md › List).
    enum Selection: Hashable {
        case info
        case operation(String)
        case schema(String)
    }

    /// The server of a form: one of the operation's servers by URL as written, or `Custom URL`.
    enum ServerChoice: Hashable {
        case server(String)
        case custom
    }

    /// The parse delay after a change of the text.
    static let parseDelay: Duration = .milliseconds(300)

    var state: State = .loading
    var selection: Selection = .info
    var listWidth: Double = 240
    /// The stored values of the contract file (docs/openapi.md › Stored values).
    private(set) var stored: OpenAPIStoredContract?

    @ObservationIgnored private weak var buffer: EditorBuffer?
    @ObservationIgnored private var forms: [String: OpenAPIOperationForm] = [:]
    @ObservationIgnored private var parseTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isVisible = false

    init(buffer: EditorBuffer) {
        self.buffer = buffer
    }

    var contract: OpenAPIContract? {
        if case .loaded(let contract) = state { return contract }
        return nil
    }

    // MARK: Parsing (docs/openapi.md › Contract and Source, › $ref resolution)

    /// The view appeared: the contract is parsed again.
    func appear() {
        isVisible = true
        followFileChanges()
        parse()
    }

    func disappear() {
        isVisible = false
    }

    /// The buffer's text changed: parsed again 300 ms later while the view is shown.
    func textChanged() {
        guard isVisible else { return }
        parseTask?.cancel()
        generation += 1
        let token = generation
        parseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.parseDelay)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.parse()
        }
    }

    /// Stops parsing, following events and every running request (the tab closed).
    func stop() {
        parseTask?.cancel()
        eventsTask?.cancel()
        eventsTask = nil
        for form in forms.values {
            form.cancel()
        }
    }

    private func parse() {
        guard let buffer, buffer.content == .text else { return }
        parseTask?.cancel()
        generation += 1
        let token = generation
        let text = buffer.text
        let path = buffer.path
        let isJSON: @Sendable (String) -> Bool = { file in
            SyntaxHighlighter.language(forFileName: (file as NSString).lastPathComponent, firstLine: nil) == .json
        }
        let read: OpenAPILoader.Reader = { [weak self] file in
            await self?.readReferenced(file)
        }
        parseTask = Task { [weak self] in
            let result = await OpenAPILoader.load(path: path, text: text, isJSON: isJSON, read: read)
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: Result<OpenAPIContract, OpenAPIParseError>) {
        switch result {
        case .success(let contract):
            loadStoredValues()
            state = .loaded(contract)
            switch selection {
            case .info:
                break
            case .operation(let id):
                if !contract.operations.contains(where: { $0.id == id }) { selection = .info }
            case .schema(let name):
                if !contract.schemas.contains(where: { $0.name == name }) { selection = .info }
            }
            refreshPrefilledBodies(contract)
        case .failure(let error):
            state = .failed(error.message)
        }
    }

    /// The text of a file a ref names: the open tab's text, unsaved changes included, else
    /// `files.read` through the window's engine (docs/openapi.md › $ref resolution, step 5).
    private func readReferenced(_ path: String) async -> String? {
        guard let buffer, let workspace = buffer.workspace, let projectID = buffer.projectID else { return nil }
        if let window = buffer.window,
           let tab = FileActions.viewState(window, projectID).editorTabs.first(where: { $0.path == path }),
           tab.buffer.content == .text {
            return tab.buffer.text
        }
        return try? await workspace.call(FilesRead.self, FilesRead.Params(projectID: projectID, path: path)).text
    }

    /// Parses again after a `files.changed` event that names a file the refs read, while the view
    /// is shown.
    private func followFileChanges() {
        guard eventsTask == nil, let workspace = buffer?.workspace else { return }
        let events = workspace.events()
        eventsTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                guard case .filesChanged(let payload) = event.event, payload.projectID == self.buffer?.projectID,
                      let contract = self.contract else { continue }
                let affected = contract.readFiles.contains { file in
                    payload.paths.contains { $0.isEmpty || file == $0 || file.hasPrefix($0 + "/") }
                }
                // A hidden view parses when it appears again.
                if affected, self.isVisible {
                    self.parse()
                }
            }
        }
    }

    // MARK: Stored values (docs/openapi.md › Stored values)

    private var storeModel: OpenAPIStoreModel? {
        buffer?.window?.app.map { OpenAPIStoreModel.shared(dataDirectory: $0.engine.dataDirectory) }
    }

    /// Reads the stored values of the contract file, again when its path changed.
    private func loadStoredValues() {
        guard let buffer, let workspace = buffer.workspace, let projectID = buffer.projectID else { return }
        if let stored, stored.path == buffer.path, stored.deviceID == workspace.deviceID, stored.projectID == projectID { return }
        if stored != nil {
            for form in forms.values {
                form.cancel()
            }
            forms.removeAll()
        }
        stored = storeModel?.store.contract(deviceID: workspace.deviceID, projectID: projectID, path: buffer.path)
            ?? OpenAPIStoredContract(deviceID: workspace.deviceID, projectID: projectID, path: buffer.path)
    }

    /// Changes the stored values and writes them 500 ms later.
    func update(_ change: (inout OpenAPIStoredContract) -> Void) {
        guard var values = stored else { return }
        change(&values)
        guard values != stored else { return }
        stored = values
        if let storeModel {
            storeModel.store.set(values)
            storeModel.scheduleSave()
        }
    }

    func storedOperation(_ operation: OpenAPIOperation) -> OpenAPIStoredOperation {
        stored?.operations[operation.id] ?? OpenAPIStoredOperation()
    }

    func updateOperation(_ operation: OpenAPIOperation, _ change: (inout OpenAPIStoredOperation) -> Void) {
        update { values in
            var stored = values.operations[operation.id] ?? OpenAPIStoredOperation()
            change(&stored)
            values.operations[operation.id] = stored
        }
    }

    // MARK: Server (docs/openapi.md › Server)

    /// The operation's servers whose URL is an absolute `http` or `https` URL.
    func usableServers(_ operation: OpenAPIOperation) -> [OpenAPIServer] {
        operation.servers.filter(\.isUsable)
    }

    func serverChoice(_ operation: OpenAPIOperation) -> ServerChoice {
        let servers = usableServers(operation)
        if stored?.usesCustomURL == true || servers.isEmpty { return .custom }
        if let url = stored?.server, servers.contains(where: { $0.url == url }) { return .server(url) }
        return .server(servers[0].url)
    }

    func setServerChoice(_ choice: ServerChoice) {
        update { values in
            switch choice {
            case .custom:
                values.usesCustomURL = true
            case .server(let url):
                values.usesCustomURL = false
                values.server = url
            }
        }
    }

    func variableValue(_ variable: OpenAPIServerVariable, of server: OpenAPIServer) -> String {
        stored?.serverVariables[server.url]?[variable.name] ?? variable.defaultValue
    }

    func setVariableValue(_ value: String, _ variable: OpenAPIServerVariable, of server: OpenAPIServer) {
        update { $0.serverVariables[server.url, default: [:]][variable.name] = value }
    }

    /// The base URL of an operation's request.
    func baseURL(_ operation: OpenAPIOperation) -> String {
        switch serverChoice(operation) {
        case .custom:
            return stored?.customURL ?? ""
        case .server(let url):
            guard let server = usableServers(operation).first(where: { $0.url == url }) else { return "" }
            var values: [String: String] = [:]
            for variable in server.variables {
                values[variable.name] = variableValue(variable, of: server)
            }
            return server.url(values: values)
        }
    }

    // MARK: Forms

    /// The runtime state of an operation's form: its body editors, its running request and its
    /// last response.
    func form(_ operation: OpenAPIOperation) -> OpenAPIOperationForm {
        if let form = forms[operation.id] { return form }
        let form = OpenAPIOperationForm()
        forms[operation.id] = form
        return form
    }

    /// The selected media type of an operation's body.
    func mediaType(_ operation: OpenAPIOperation) -> OpenAPIMediaType? {
        let content = operation.requestBody?.content ?? []
        if let name = storedOperation(operation).mediaType, let media = content.first(where: { $0.name == name }) {
            return media
        }
        return content.first
    }

    /// The editor of a media type's body: its stored body, else the prefilled one.
    func bodyModel(_ operation: OpenAPIOperation, _ media: OpenAPIMediaType) -> EditorTextModel {
        let form = form(operation)
        if let model = form.bodies[media.name] { return model }
        let text = storedOperation(operation).bodies[media.name] ?? OpenAPISample.body(for: media)
        let isJSON = OpenAPISample.isJSON(mediaType: media.name)
        let model = EditorTextModel(text: text, fileName: isJSON ? "body.json" : "body.txt", language: isJSON ? .json : .plain)
        form.bodies[media.name] = model
        form.prefilled[media.name] = text
        return model
    }

    /// The body changed in its editor: stored once it differs from the prefilled body.
    func bodyChanged(_ operation: OpenAPIOperation, _ media: OpenAPIMediaType, text: String) {
        let form = form(operation)
        guard storedOperation(operation).bodies[media.name] != nil || form.prefilled[media.name] != text else { return }
        updateOperation(operation) { $0.bodies[media.name] = text }
    }

    /// Bodies that were never stored follow the contract's examples and schemas.
    private func refreshPrefilledBodies(_ contract: OpenAPIContract) {
        for operation in contract.operations {
            guard let form = forms[operation.id] else { continue }
            for media in operation.requestBody?.content ?? [] {
                guard let model = form.bodies[media.name], storedOperation(operation).bodies[media.name] == nil,
                      model.text == form.prefilled[media.name] else { continue }
                let text = OpenAPISample.body(for: media)
                form.prefilled[media.name] = text
                if model.text != text {
                    model.text = text
                }
            }
        }
    }

    // MARK: Sending (docs/openapi.md › Sending a request)

    /// The form's values as a request input.
    func requestInput(_ operation: OpenAPIOperation, contract: OpenAPIContract) -> OpenAPIRequestInput {
        let values = storedOperation(operation)
        let ordered = OpenAPIParameterLocation.allCases.flatMap { location in
            operation.parameters.filter { $0.location == location }
        }
        let parameters = ordered.map { (location: $0.location, name: $0.name, value: values.parameters[$0.id] ?? "") }
        let credentials: [OpenAPICredential] = contract.credentialSchemes(for: operation).compactMap { scheme in
            let credential = stored?.credentials[scheme.name] ?? OpenAPIStoredCredential()
            switch scheme.kind {
            case .apiKey(let name, let location):
                return .apiKey(name: name, location: location, value: credential.value ?? "")
            case .basic:
                return .basic(username: credential.username ?? "", password: credential.password ?? "")
            case .bearer:
                return .bearer(token: credential.token ?? "")
            case .unsupported:
                return nil
            }
        }
        let media = mediaType(operation)
        let body = media.map { bodyModel(operation, $0).text } ?? ""
        return OpenAPIRequestInput(baseURL: baseURL(operation), method: operation.method, path: operation.path,
                                   parameters: parameters, credentials: credentials, mediaType: media?.name, body: body,
                                   headers: stored?.headers ?? [])
    }

    func send(_ operation: OpenAPIOperation) {
        guard let contract, let request = OpenAPIRequestBuilder.request(for: requestInput(operation, contract: contract)) else { return }
        let rewrite: (@Sendable (URL) -> URL)? = LocalhostRewrite.deviceAddress(of: buffer?.window).map { address in
            { url in URL(string: LocalhostRewrite.forward(url.absoluteString, deviceAddress: address)) ?? url }
        }
        form(operation).send(request, rewrite: rewrite)
    }
}

/// The runtime state of one operation's form.
@MainActor @Observable
final class OpenAPIOperationForm {
    enum Result {
        case response(OpenAPIHTTPResponse, OpenAPIResponseBody)
        case failure(String)
    }

    /// The last response, kept while the tab is open (docs/openapi.md › Response).
    var result: Result?
    /// The read-only editor of the last response's text body.
    var responseEditor: EditorTextModel?
    var isSending = false
    /// Body editors by media type.
    @ObservationIgnored var bodies: [String: EditorTextModel] = [:]
    /// The prefilled text of each body editor, to know whether the user changed it.
    @ObservationIgnored var prefilled: [String: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sendCount = 0

    func send(_ request: URLRequest, rewrite: (@Sendable (URL) -> URL)?) {
        task?.cancel()
        sendCount += 1
        let token = sendCount
        isSending = true
        task = Task { [weak self] in
            let outcome: Result?
            do {
                let response = try await OpenAPIHTTPClient.send(request, rewrite: rewrite)
                let body = await Task.detached { OpenAPIResponseBody(response) }.value
                outcome = .response(response, body)
            } catch is CancellationError {
                outcome = nil
            } catch let error as URLError where error.code == .cancelled {
                outcome = nil
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            guard let self, token == self.sendCount else { return }
            if let outcome, !Task.isCancelled {
                self.show(outcome)
            }
            self.isSending = false
            self.task = nil
        }
    }

    private func show(_ outcome: Result) {
        if case .response(_, let body) = outcome, case .text(let text, let isJSON) = body.kind {
            let editor = EditorTextModel(text: text, fileName: isJSON ? "response.json" : "response.txt",
                                         language: isJSON ? .json : .plain, isEditable: false)
            editor.highlightsSyntax = text.utf8.count <= OpenAPIResponseBody.highlightLimit
            responseEditor = editor
        } else {
            responseEditor = nil
        }
        result = outcome
    }

    /// Cancel: the request stops and the response area keeps what it showed.
    func cancel() {
        task?.cancel()
        task = nil
        sendCount += 1
        isSending = false
    }
}

/// How a response body shows (docs/openapi.md › Response).
struct OpenAPIResponseBody: Sendable {
    enum Kind: Sendable {
        case empty
        case text(String, isJSON: Bool)
        case binary(Data)
    }

    /// Bodies larger than this are not highlighted (2 MB, as in the editor).
    static let highlightLimit = 2_097_152

    let kind: Kind
    let contentType: String?

    init(_ response: OpenAPIHTTPResponse) {
        contentType = response.contentType
        guard !response.body.isEmpty else {
            kind = .empty
            return
        }
        guard let text = String(data: response.body, encoding: .utf8), !text.contains("\0") else {
            kind = .binary(response.body)
            return
        }
        if let value = try? OpenAPIValue.parseJSON(text) {
            kind = .text(value.jsonText(pretty: true), isJSON: true)
        } else {
            kind = .text(text, isJSON: false)
        }
    }

    /// `response.<extension>` from the media type, or `response`.
    var quickLookName: String {
        let essence = contentType.map(OpenAPISample.essence(of:)) ?? ""
        if let ext = UTType(mimeType: essence)?.preferredFilenameExtension {
            return "response.\(ext)"
        }
        return "response"
    }
}

/// The stored values of this Mac's request forms and their delayed writes (docs/openapi.md ›
/// Stored values).
@MainActor
final class OpenAPIStoreModel {
    /// The write delay after a change.
    static let saveDelay: Duration = .milliseconds(500)

    private static var models: [URL: OpenAPIStoreModel] = [:]

    let store: OpenAPIRequestStore
    private var saveTask: Task<Void, Never>?

    private init(store: OpenAPIRequestStore) {
        self.store = store
    }

    /// The model of a data directory, the process's own on this Mac.
    static func shared(dataDirectory: DataDirectory) -> OpenAPIStoreModel {
        if let model = models[dataDirectory.url] { return model }
        let model = OpenAPIStoreModel(store: OpenAPIRequestStore(dataDirectory: dataDirectory))
        models[dataDirectory.url] = model
        return model
    }

    func scheduleSave() {
        saveTask?.cancel()
        let store = self.store
        saveTask = Task {
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            await Task.detached {
                try? store.save()
            }.value
        }
    }
}
