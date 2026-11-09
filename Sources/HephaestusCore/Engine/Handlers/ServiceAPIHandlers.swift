import Foundation
import HephaestusText

/// Sends the request of an `api.call` and returns the response; `allowInvalidCertificates` is the
/// environment's setting (docs/mcp.md › api_call). Throws the client's error.
typealias APIRequestSender = @Sendable (_ request: URLRequest, _ allowInvalidCertificates: Bool) async throws -> OpenAPIHTTPResponse

extension Engine {
    /// The contract of the API tools: `openapi/contract.yaml` of the project root (docs/mcp.md ›
    /// API tools).
    static let apiContractPath = "openapi/contract.yaml"
    /// A UTF-8 text body smaller than this is returned as text (docs/mcp.md › api_call).
    static let apiTextBodyLimit = 51_200

    /// docs/engine-api.md › API: the methods of the API tools (docs/mcp.md › API tools), for the
    /// chat's own Claude only.
    func registerServiceAPIHandlers() {
        register(APIOperations.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.apiOperations(params, actor)
        }
        register(APICall.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.apiCall(params, actor)
        }
    }

    // MARK: Methods

    /// `api.operations` (docs/mcp.md › api_operations): the operations of the contract, read from
    /// disk with their refs resolved.
    func apiOperations(_ params: APIOperations.Params, _ actor: Actor) async throws -> APIContract {
        let (_, contract) = try await apiTarget(params.chatID, actor, tool: "api_operations")
        return Self.apiContract(contract)
    }

    /// `api.call` (docs/mcp.md › api_call): checks 6 to 10, then the request built as the request
    /// form builds it, with the stored credentials and added headers, sent from the engine.
    func apiCall(_ params: APICall.Params, _ actor: Actor) async throws -> APICallResult {
        let (projectID, contract) = try await apiTarget(params.chatID, actor, tool: "api_call")
        guard let environment = resolvedEnvironments(of: projectID).environments.first(where: { $0.name == params.environment }) else {
            throw EngineError.invalid("environment", "\(projectID) has no environment named “\(params.environment)”")
        }
        guard environment.url != nil else {
            throw EngineError(.invalid, "Environment “\(environment.name)” has no URL; the user sets its API Access in Project Settings.")
        }
        guard environment.isUsable, let baseURL = environment.baseURL else {
            throw EngineError(.invalid, "Environment “\(environment.name)” has an invalid URL or port.")
        }
        guard let operation = contract.operations.first(where: { $0.id == params.operation }) else {
            throw EngineError.invalid("operation", "\(Self.apiContractPath) has no operation “\(params.operation)”")
        }
        let options = params.options ?? APICallOptions()
        let input = try Self.apiRequestInput(operation, contract: contract, baseURL: baseURL, options: options,
                                             stored: OpenAPIRequestStore(dataDirectory: dataDirectory)
                                                 .contract(deviceID: deviceID, projectID: projectID, path: Self.apiContractPath))
        guard let request = OpenAPIRequestBuilder.request(for: input) else {
            throw Self.apiRequestFailure(URLError(.badURL))
        }
        let response: OpenAPIHTTPResponse
        do {
            response = try await apiRequestSender(request, environment.allowInvalidCertificates)
        } catch {
            throw Self.apiRequestFailure(error)
        }
        let folder = apiResponseFolder
        return try await Task.detached {
            try Self.apiCallResult(response, temporaryFolder: folder)
        }.value
    }

    // MARK: Checks and the contract

    /// Checks 1 to 5 of docs/engine-api.md › API: the actor is the Claude of the chat, the chat
    /// exists, its project has the type `goService`, and its root holds an OpenAPI 3.x contract
    /// that parses. The files are read from disk outside the engine's actor.
    func apiTarget(_ chatID: ChatID, _ actor: Actor, tool: String) async throws -> (ProjectID, OpenAPIContract) {
        try ActorRules.requireOwnChat(chatID, actor, else: ActorRules.ownChatAPIOnly)
        let meta = try requireChat(chatID)
        guard domain.project(meta.projectID)?.type == .goService else {
            throw EngineError(.forbidden, "\(tool) is only available in Go service projects.")
        }
        guard let root = domain.projectRoot(meta.projectID) else {
            throw EngineError.notFound("Chat", chatID.uuidString)
        }
        let projectID = meta.projectID
        let contract = try await Task.detached {
            try await Self.loadAPIContract(root: root, projectID: projectID)
        }.value
        return (projectID, contract)
    }

    /// Reads and parses `openapi/contract.yaml` of `root` and the files its refs name, every file
    /// from disk (docs/mcp.md › Rules of the API tools, rule 4).
    static func loadAPIContract(root: URL, projectID: ProjectID) async throws -> OpenAPIContract {
        guard let text = apiFileText(root: root, path: apiContractPath),
              OpenAPIDetection.isContract(text: text, isJSON: false) else {
            throw EngineError(.invalid, "\(projectID) has no OpenAPI 3.x contract at \(apiContractPath).")
        }
        let isJSON: @Sendable (String) -> Bool = { file in
            SyntaxHighlighter.language(forFileName: (file as NSString).lastPathComponent, firstLine: nil) == .json
        }
        let result = await OpenAPILoader.load(path: apiContractPath, text: text, isJSON: isJSON) { path in
            apiFileText(root: root, path: path)
        }
        switch result {
        case .success(let contract):
            return contract
        case .failure(let error):
            let message = error.message.hasSuffix(".") ? error.message : error.message + "."
            throw EngineError(.invalid, "The contract \(apiContractPath) could not be read: \(message)")
        }
    }

    /// The text of a project file as `files.read` gives it: a regular file of at most 20 MiB,
    /// valid UTF-8 without NUL bytes; nil otherwise.
    static func apiFileText(root: URL, path: String) -> String? {
        let url = root.appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let content = try? FileSystemItems.content(of: url, size: size) else { return nil }
        return content.text
    }

    // MARK: Results and requests

    /// The `APIContract` of a parsed contract (docs/engine-api.md › APIContract).
    static func apiContract(_ contract: OpenAPIContract) -> APIContract {
        APIContract(path: contract.path, title: contract.info.title, version: contract.info.version,
                    operations: contract.operations.map { apiOperation($0, contract: contract) })
    }

    static func apiOperation(_ operation: OpenAPIOperation, contract: OpenAPIContract) -> APIContractOperation {
        func media(_ content: [OpenAPIMediaType]) -> [APIContractMedia] {
            content.map { APIContractMedia(mediaType: $0.name, schema: $0.schema?.resolvedJSON) }
        }
        let body = operation.requestBody.map { body in
            APIContractBody(required: body.isRequired, description: body.description, content: media(body.content),
                            unresolvedRef: body.unresolvedRef)
        }
        return APIContractOperation(
            operation: operation.id,
            operationId: operation.operationId,
            tags: operation.tags,
            summary: operation.summary,
            description: operation.description,
            parameters: operation.parameters.map { parameter in
                APIContractParameter(name: parameter.name, in: parameter.location.rawValue, required: parameter.isRequired,
                                     description: parameter.description, schema: parameter.schema?.resolvedJSON)
            },
            unresolvedParameters: operation.unresolvedParameters.isEmpty ? nil : operation.unresolvedParameters,
            requestBody: body,
            responses: operation.responses.map { response in
                APIContractResponse(code: response.code, description: response.description, content: media(response.content),
                                    unresolvedRef: response.unresolvedRef)
            },
            security: contract.credentialSchemes(for: operation).map(\.name))
    }

    /// Checks 8 to 10 of docs/mcp.md › api_call, then the form's input: the parameters of
    /// `options` in the form's order, the stored credentials of the operation's schemes, the body
    /// with its media type, and the stored added headers followed by those of `options` in ascending
    /// order of name.
    static func apiRequestInput(_ operation: OpenAPIOperation, contract: OpenAPIContract, baseURL: String, options: APICallOptions,
                                stored: OpenAPIStoredContract) throws -> OpenAPIRequestInput {
        let values = options.parameters ?? [:]
        let known = Set(operation.parameters.map(\.id))
        for key in values.keys.sorted() where !known.contains(key) {
            throw EngineError.invalid("options.parameters", "\(operation.id) has no parameter “\(key)”")
        }
        let content = operation.requestBody?.content ?? []
        let body = options.body ?? ""
        if content.isEmpty, options.mediaType != nil {
            throw EngineError.invalid("options.mediaType", "\(operation.id) has no request body")
        }
        if content.isEmpty, !body.isEmpty {
            throw EngineError.invalid("options.body", "\(operation.id) has no request body")
        }
        var mediaType = content.first?.name
        if let requested = options.mediaType {
            guard content.contains(where: { $0.name == requested }) else {
                throw EngineError.invalid("options.mediaType", "\(operation.id) has no request media type “\(requested)”")
            }
            mediaType = requested
        }
        let ordered = OpenAPIParameterLocation.allCases.flatMap { location in
            operation.parameters.filter { $0.location == location }
        }
        let parameters = ordered.map { (location: $0.location, name: $0.name, value: values[$0.id] ?? "") }
        let added = (options.headers ?? [:]).sorted { $0.key < $1.key }.map { OpenAPIHeader(name: $0.key, value: $0.value) }
        return OpenAPIRequestInput(baseURL: baseURL, method: operation.method, path: operation.path, parameters: parameters,
                                   credentials: contract.credentials(for: operation, stored: stored.credentials),
                                   mediaType: mediaType, body: body, headers: stored.headers + added)
    }

    /// The result of a response (docs/engine-api.md › APICallResult): a UTF-8 text body smaller
    /// than 50 KB as text, any other body that is not empty written to a file in `temporaryFolder`.
    static func apiCallResult(_ response: OpenAPIHTTPResponse, temporaryFolder: URL) throws -> APICallResult {
        var result = APICallResult(status: response.status, reason: OpenAPIHTTPClient.reasonPhrases[response.status],
                                   milliseconds: response.milliseconds, headers: response.headers)
        guard !response.body.isEmpty else { return result }
        if response.body.count < apiTextBodyLimit, let text = response.bodyText {
            result.body = text
            return result
        }
        let file: URL
        do {
            file = try OpenAPIResponseFiles.write(response.body, name: OpenAPIResponseFiles.name(contentType: response.contentType),
                                                  temporaryFolder: temporaryFolder)
        } catch {
            throw EngineError.internalError(error)
        }
        result.bodyFile = APIBodyFile(path: file.path, size: response.body.count, contentType: response.contentType)
        return result
    }

    /// `unavailable` `The request failed: <localized description>.` for a request that fails
    /// without a response.
    static func apiRequestFailure(_ error: Error) -> EngineError {
        var description = error.localizedDescription
        while description.hasSuffix(".") {
            description.removeLast()
        }
        return EngineError(.unavailable, "The request failed: \(description).")
    }
}
