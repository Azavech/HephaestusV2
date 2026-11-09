import Foundation
import Testing
@testable import HephaestusCore

/// The API methods behind the API tools, called as a chat's Claude: their checks in the order of
/// docs/engine-api.md › API, the operations of docs/mcp.md › api_operations with their schemas
/// (docs/mcp.md › Schemas in results), and the requests and results of docs/mcp.md › api_call,
/// sent through a recorded sender.
@Suite("API methods")
struct ServiceAPIMethodsTests {
    static let contract = """
    openapi: 3.0.3
    info:
      title: Pet Store
      version: 1.2.0
    security:
      - bearerAuth: []
    paths:
      /pets:
        get:
          operationId: listPets
          tags: [pets]
          summary: List pets
          parameters:
            - $ref: '#/components/parameters/limit'
          responses:
            '200':
              description: The pets.
              content:
                application/json:
                  schema:
                    type: array
                    items:
                      $ref: 'schemas/pet.yaml'
        post:
          operationId: createPet
          tags: [pets]
          requestBody:
            required: true
            description: The new pet.
            content:
              application/json:
                schema:
                  $ref: 'schemas/pet.yaml'
              text/plain:
                schema:
                  type: string
          responses:
            '201':
              description: Created.
      /pets/{petId}:
        parameters:
          - name: petId
            in: path
            required: true
            description: The id of the pet.
            schema:
              type: string
        get:
          operationId: showPetById
          tags: [pets]
          summary: Info for a specific pet
          parameters:
            - name: X-Trace
              in: header
              schema:
                type: string
            - $ref: '#/components/parameters/missing'
          responses:
            '200':
              $ref: '#/components/responses/Pet'
            '404':
              $ref: '#/components/responses/Missing'
            default:
              description: Error.
              content:
                application/json:
                  schema:
                    $ref: 'schemas/error.yaml#/Error'
        delete:
          security:
            - apiKeyAuth: []
          responses:
            '204':
              description: Deleted.
      /health:
        get:
          security: []
          responses:
            '200':
              description: OK.
    components:
      parameters:
        limit:
          name: limit
          in: query
          schema:
            type: integer
            minimum: 1
            maximum: 100
      responses:
        Pet:
          description: The pet.
          content:
            application/json:
              schema:
                $ref: 'schemas/pet.yaml'
      securitySchemes:
        bearerAuth:
          type: http
          scheme: bearer
        apiKeyAuth:
          type: apiKey
          name: X-API-Key
          in: header
        oauth:
          type: oauth2
          flows: {}
    """

    /// A schema of another file, whose `parent` refers to itself.
    static let pet = """
    type: object
    required: [id, name]
    properties:
      id:
        type: string
      name:
        type: string
      parent:
        $ref: 'pet.yaml'
    """

    static let environments = [
        ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080),
        ProjectEnvironment(name: "secure", url: "https://10.0.0.5/api/", allowInvalidCertificates: true),
        ProjectEnvironment(name: "bare"),
        ProjectEnvironment(name: "broken", url: "http://127.0.0.1", port: 0),
    ]

    /// The resolved schema of `pet`: its circular ref stays a ref.
    static let petSchema = JSONValue.object([
        "type": "object",
        "required": .array(["id", "name"]),
        "properties": .object([
            "id": .object(["type": "string"]),
            "name": .object(["type": "string"]),
            "parent": .object(["$ref": "pet.yaml"]),
        ]),
    ])

    // MARK: Test bed

    /// A test bed whose project DEMO has the type `type`, the environments of `environments` and,
    /// with `contract`, `openapi/contract.yaml` and `openapi/schemas/pet.yaml`.
    static func withAPIEngine<T>(type: ProjectType = .goService, contract: String? = Self.contract,
                                 _ body: (ChatTestBed, ChatMeta, RecordedSender) async throws -> T) async throws -> T {
        try await withChatEngine(prepare: { folder, _ in
            try ProjectFileStore.write(Project(id: "DEMO", name: "Demo", created: ISODate.date(from: "2026-10-31T12:00:00Z")!, type: type,
                                               environments: environments),
                                       to: folder)
            if let contract {
                let schemas = folder.root.appendingPathComponent("openapi/schemas", isDirectory: true)
                try FileManager.default.createDirectory(at: schemas, withIntermediateDirectories: true)
                try Data(contract.utf8).write(to: folder.root.appendingPathComponent("openapi/contract.yaml"))
                try Data(pet.utf8).write(to: schemas.appendingPathComponent("pet.yaml"))
            }
        }) { bed in
            let sender = RecordedSender()
            await bed.engine.useAPISender(sender, folder: bed.root.deletingLastPathComponent().appendingPathComponent("Temporary"))
            return try await body(bed, try await bed.createChat(), sender)
        }
    }

    /// Stores credentials and added headers for the contract of DEMO under `deviceID`, as the API
    /// Explorer does.
    static func store(_ bed: ChatTestBed, deviceID: String, token: String, headers: [OpenAPIHeader]) throws {
        let store = OpenAPIRequestStore(dataDirectory: bed.dataDirectory)
        var contract = store.contract(deviceID: deviceID, projectID: "DEMO", path: "openapi/contract.yaml")
        contract.credentials = ["bearerAuth": OpenAPIStoredCredential(token: token), "apiKeyAuth": OpenAPIStoredCredential(value: "key-1")]
        contract.headers = headers
        contract.operations = ["GET /pets": OpenAPIStoredOperation(parameters: ["query:limit": "99"])]
        store.set(contract)
        try store.save()
    }

    static func call(_ bed: ChatTestBed, _ chat: ChatMeta, environment: String = "local", _ operation: String,
                     _ options: APICallOptions? = nil, actor: Actor? = nil) async throws -> APICallResult {
        try await bed.engine.call(APICall.self, .init(chatID: chat.id, environment: environment, operation: operation, options: options),
                                  actor: actor ?? .claude(chatID: chat.id.uuidString))
    }

    static func operations(_ bed: ChatTestBed, _ chat: ChatMeta, actor: Actor? = nil) async throws -> APIContract {
        try await bed.engine.call(APIOperations.self, .init(chatID: chat.id), actor: actor ?? .claude(chatID: chat.id.uuidString))
    }

    // MARK: Checks

    @Test("Only the chat's own Claude calls them: the external token, an answer, another chat and the user are refused")
    func actors() async throws {
        try await Self.withAPIEngine { bed, chat, sender in
            let other = try await bed.createChat()
            for actor in [Actor.claude(chatID: Actor.externalChatID), .claude(chatID: Actor.answerChatID), .claude(chatID: other.id.uuidString)] {
                #expect(await engineError { try await Self.operations(bed, chat, actor: actor) } == ActorRules.ownChatAPIOnly)
                #expect(await engineError { try await Self.call(bed, chat, "GET /pets", actor: actor) } == ActorRules.ownChatAPIOnly)
            }
            #expect(ActorRules.ownChatAPIOnly == EngineError(.forbidden, "Only the chat's own Claude can use the API tools."))
            #expect(await engineError { try await bed.connection.call(APIOperations.self, .init(chatID: chat.id)) }
                == EngineError(.forbidden, "api.operations is not available to user."))
            let missing = UUID()
            #expect(await engineError {
                try await bed.engine.call(APIOperations.self, .init(chatID: missing), actor: .claude(chatID: missing.uuidString))
            } == EngineError(.notFound, "Chat \(missing.uuidString) not found."))
            #expect(sender.requests.isEmpty)
        }
    }

    @Test("A project whose type is not Go service fails with forbidden, naming the tool", arguments: [ProjectType.none, .swiftApplication])
    func projectType(type: ProjectType) async throws {
        try await Self.withAPIEngine(type: type) { bed, chat, sender in
            #expect(await engineError { try await Self.operations(bed, chat) }
                == EngineError(.forbidden, "api_operations is only available in Go service projects."))
            #expect(await engineError { try await Self.call(bed, chat, "GET /pets") }
                == EngineError(.forbidden, "api_call is only available in Go service projects."))
            #expect(sender.requests.isEmpty)
        }
    }

    @Test("A missing contract, a file that is not an OpenAPI 3.x contract and a contract that cannot be parsed fail with invalid")
    func contracts() async throws {
        try await Self.withAPIEngine(contract: nil) { bed, chat, sender in
            let noContract = EngineError(.invalid, "DEMO has no OpenAPI 3.x contract at openapi/contract.yaml.")
            #expect(await engineError { try await Self.operations(bed, chat) } == noContract)
            #expect(await engineError { try await Self.call(bed, chat, "GET /pets") } == noContract)
            let file = bed.root.appendingPathComponent("openapi/contract.yaml")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            for text in ["swagger: \"2.0\"\npaths: {}\n", "openapi: 2.0\n", "# openapi: 3.0.0\n", "{\"swagger\": \"3.0.0\"}\n", "\u{0}\u{1}binary"] {
                try Data(text.utf8).write(to: file)
                #expect(await engineError { try await Self.operations(bed, chat) } == noContract, "\(text)")
            }
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            #expect(await engineError { try await Self.operations(bed, chat) } == noContract)
            try FileManager.default.removeItem(at: file)
            try Data("openapi: 3.0.0\npaths: [\n".utf8).write(to: file)
            let unparsed = try #require(await engineError { try await Self.operations(bed, chat) })
            #expect(unparsed.code == .invalid)
            #expect(unparsed.message.hasPrefix("The contract openapi/contract.yaml could not be read: "))
            #expect(unparsed.message.hasSuffix("."))
            #expect(sender.requests.isEmpty)
        }
    }

    // MARK: api.operations

    @Test("The operations in the list's order, with their parameters, bodies, responses and security names, refs resolved across files")
    func operations() async throws {
        try await Self.withAPIEngine { bed, chat, _ in
            let contract = try await Self.operations(bed, chat)
            #expect(contract.path == "openapi/contract.yaml")
            #expect(contract.title == "Pet Store" && contract.version == "1.2.0")
            #expect(contract.operations.map(\.operation) == ["GET /pets", "POST /pets", "GET /pets/{petId}", "DELETE /pets/{petId}", "GET /health"])

            let list = contract.operations[0]
            #expect(list == APIContractOperation(
                operation: "GET /pets", operationId: "listPets", tags: ["pets"], summary: "List pets",
                parameters: [APIContractParameter(name: "limit", in: "query", required: false,
                                                  schema: .object(["type": "integer", "minimum": .int(1), "maximum": .int(100)]))],
                responses: [APIContractResponse(code: "200", description: "The pets.", content: [
                    APIContractMedia(mediaType: "application/json", schema: .object(["type": "array", "items": Self.petSchema])),
                ])],
                security: ["bearerAuth"]))

            let create = contract.operations[1]
            #expect(create.requestBody == APIContractBody(required: true, description: "The new pet.", content: [
                APIContractMedia(mediaType: "application/json", schema: Self.petSchema),
                APIContractMedia(mediaType: "text/plain", schema: .object(["type": "string"])),
            ]))

            let show = contract.operations[2]
            #expect(show.parameters == [
                APIContractParameter(name: "petId", in: "path", required: true, description: "The id of the pet.", schema: .object(["type": "string"])),
                APIContractParameter(name: "X-Trace", in: "header", required: false, schema: .object(["type": "string"])),
            ])
            #expect(show.unresolvedParameters == ["#/components/parameters/missing"])
            #expect(show.requestBody == nil)
            #expect(show.responses == [
                APIContractResponse(code: "200", description: "The pet.", content: [APIContractMedia(mediaType: "application/json", schema: Self.petSchema)]),
                APIContractResponse(code: "404", unresolvedRef: "#/components/responses/Missing"),
                APIContractResponse(code: "default", description: "Error.", content: [
                    APIContractMedia(mediaType: "application/json", schema: .object(["$ref": "schemas/error.yaml#/Error", "unresolved": true])),
                ]),
            ])
            #expect(show.security == ["bearerAuth"])
            #expect(contract.operations[3].security == ["apiKeyAuth"])
            #expect(contract.operations[4].security == [])
            // No stored value reaches the result.
            try Self.store(bed, deviceID: bed.engine.deviceID, token: "secret-token", headers: [OpenAPIHeader(name: "X-Tenant", value: "demo")])
            let text = String(decoding: try EngineJSON.encode(try await Self.operations(bed, chat)), as: UTF8.self)
            #expect(!text.contains("secret-token") && !text.contains("key-1") && !text.contains("X-Tenant"))
        }
    }

    @Test("The contract is read from disk at each call")
    func readAtEachCall() async throws {
        try await Self.withAPIEngine { bed, chat, _ in
            #expect(try await Self.operations(bed, chat).operations.count == 5)
            let file = bed.root.appendingPathComponent("openapi/contract.yaml")
            try Data(Self.contract.replacingOccurrences(of: "  /health:\n    get:", with: "  /health:\n    head:").utf8).write(to: file)
            #expect(try await Self.operations(bed, chat).operations.last?.operation == "HEAD /health")
        }
    }

    // MARK: api.call

    @Test("The request is built as the form builds it, with the credentials and added headers stored under the main device's id")
    func request() async throws {
        try await Self.withAPIEngine { bed, chat, sender in
            try Self.store(bed, deviceID: bed.engine.deviceID, token: "secret-token",
                           headers: [OpenAPIHeader(name: "X-Tenant", value: "demo"), OpenAPIHeader(name: "X-Trace", value: "stored")])
            try Self.store(bed, deviceID: "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E", token: "other-mac", headers: [OpenAPIHeader(name: "X-Other", value: "1")])
            sender.response = OpenAPIHTTPResponse(status: 200, headers: [], body: Data("{}".utf8), milliseconds: 3, contentType: "application/json")

            _ = try await Self.call(bed, chat, "GET /pets/{petId}",
                                    APICallOptions(parameters: ["path:petId": "a b/c"], headers: ["x-trace": "given", "Accept": "application/json"]))
            let show = try #require(sender.requests.last)
            #expect(show.request.url?.absoluteString == "http://127.0.0.1:8080/pets/a%20b%2Fc")
            #expect(show.request.httpMethod == "GET")
            #expect(show.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
            #expect(show.request.value(forHTTPHeaderField: "X-Tenant") == "demo")
            #expect(show.request.value(forHTTPHeaderField: "X-Trace") == "given")
            #expect(show.request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(show.request.value(forHTTPHeaderField: "X-Other") == nil)
            #expect(show.request.httpBody == nil)
            #expect(show.allowInvalidCertificates == false)

            // The query takes the parameters given, never the values stored for the operation.
            _ = try await Self.call(bed, chat, "GET /pets", APICallOptions(parameters: ["query:limit": "5"]))
            #expect(sender.requests.last?.request.url?.absoluteString == "http://127.0.0.1:8080/pets?limit=5")
            _ = try await Self.call(bed, chat, "GET /pets", APICallOptions(parameters: ["query:limit": ""]))
            #expect(sender.requests.last?.request.url?.absoluteString == "http://127.0.0.1:8080/pets")

            // The body with the first media type, or the one given; an API key in a header.
            _ = try await Self.call(bed, chat, "POST /pets", APICallOptions(body: #"{"name":"Rex"}"#))
            let create = try #require(sender.requests.last?.request)
            #expect(create.httpMethod == "POST")
            #expect(create.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(create.httpBody == Data(#"{"name":"Rex"}"#.utf8))
            _ = try await Self.call(bed, chat, "POST /pets", APICallOptions(body: "Rex", mediaType: "text/plain"))
            #expect(sender.requests.last?.request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
            _ = try await Self.call(bed, chat, "POST /pets", APICallOptions(body: ""))
            #expect(sender.requests.last?.request.httpBody == nil)
            #expect(sender.requests.last?.request.value(forHTTPHeaderField: "Content-Type") == nil)
            _ = try await Self.call(bed, chat, "DELETE /pets/{petId}", APICallOptions(parameters: ["path:petId": "7"]))
            let delete = try #require(sender.requests.last?.request)
            #expect(delete.value(forHTTPHeaderField: "X-API-Key") == "key-1")
            #expect(delete.value(forHTTPHeaderField: "Authorization") == nil)

            // Another environment, with Allow invalid certificates on.
            _ = try await Self.call(bed, chat, environment: "secure", "GET /health")
            #expect(sender.requests.last?.request.url?.absoluteString == "https://10.0.0.5/api/health")
            #expect(sender.requests.last?.allowInvalidCertificates == true)
            #expect(sender.requests.last?.request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test("Without stored values, the request sends no credential")
    func noStoredValues() async throws {
        try await Self.withAPIEngine { bed, chat, sender in
            _ = try await Self.call(bed, chat, "GET /pets")
            let request = try #require(sender.requests.last?.request)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.url?.absoluteString == "http://127.0.0.1:8080/pets")
        }
    }

    @Test("Unknown environments, operations, parameters and media types, and environments without a usable URL, fail with invalid before any request")
    func checks() async throws {
        try await Self.withAPIEngine { bed, chat, sender in
            let cases: [(environment: String, operation: String, options: APICallOptions?, message: String)] = [
                ("Local", "GET /pets", nil, "environment: DEMO has no environment named “Local”."),
                ("bare", "GET /pets", nil, "Environment “bare” has no URL; the user sets its API Access in Project Settings."),
                ("broken", "GET /pets", nil, "Environment “broken” has an invalid URL or port."),
                ("local", "GET /cats", nil, "operation: openapi/contract.yaml has no operation “GET /cats”."),
                ("local", "get /pets", nil, "operation: openapi/contract.yaml has no operation “get /pets”."),
                ("local", "GET /pets", APICallOptions(parameters: ["query:limit": "1", "query:a": "x", "path:petId": "1"]),
                 "options.parameters: GET /pets has no parameter “path:petId”."),
                ("local", "GET /pets", APICallOptions(parameters: ["limit": "1"]), "options.parameters: GET /pets has no parameter “limit”."),
                ("local", "GET /pets", APICallOptions(body: "{}", mediaType: "application/json"),
                 "options.mediaType: GET /pets has no request body."),
                ("local", "GET /pets", APICallOptions(body: "{}"), "options.body: GET /pets has no request body."),
                ("local", "POST /pets", APICallOptions(mediaType: "application/xml"),
                 "options.mediaType: POST /pets has no request media type “application/xml”."),
                ("local", "POST /pets", APICallOptions(mediaType: "Application/JSON"),
                 "options.mediaType: POST /pets has no request media type “Application/JSON”."),
            ]
            for (environment, operation, options, message) in cases {
                #expect(await engineError { try await Self.call(bed, chat, environment: environment, operation, options) }
                    == EngineError(.invalid, message), "\(message)")
            }
            #expect(sender.requests.isEmpty)
            // An empty body needs no request body.
            _ = try await Self.call(bed, chat, "GET /pets", APICallOptions(body: ""))
            #expect(sender.requests.count == 1)
        }
    }

    @Test("Result: the status, its reason, the duration, the headers and a text body smaller than 50 KB")
    func textResult() async throws {
        try await Self.withAPIEngine { bed, chat, sender in
            let headers = [OpenAPIHeader(name: "Content-Type", value: "application/json"), OpenAPIHeader(name: "Date", value: "Sun, 08 Nov 2026 22:09:12 GMT")]
            let text = #"{"id":"42","name":"Rex"}"#
            sender.response = OpenAPIHTTPResponse(status: 200, headers: headers, body: Data(text.utf8), milliseconds: 71,
                                                  contentType: "application/json")
            let shown = try await Self.call(bed, chat, "GET /pets/{petId}", APICallOptions(parameters: ["path:petId": "42"]))
            #expect(shown == APICallResult(status: 200, reason: "OK", milliseconds: 71, headers: headers, body: text))
            // The text as received, not pretty-printed; the largest text body still returned as text.
            let largest = String(repeating: "a", count: 51_199)
            sender.response = OpenAPIHTTPResponse(status: 418, headers: [], body: Data(largest.utf8), milliseconds: 5, contentType: nil)
            let teapot = try await Self.call(bed, chat, "GET /pets")
            #expect(teapot == APICallResult(status: 418, milliseconds: 5, body: largest))
            sender.response = OpenAPIHTTPResponse(status: 204, headers: [], body: Data(), milliseconds: 2, contentType: nil)
            let empty = try await Self.call(bed, chat, "GET /pets")
            #expect(empty == APICallResult(status: 204, reason: "No Content", milliseconds: 2))
        }
    }

    @Test("A text body of 50 KB or more and a binary body are written to a file whose path, size and Content-Type are returned")
    func fileResult() async throws {
        try await Self.withAPIEngine { bed, chat, sender in
            let folder = bed.root.deletingLastPathComponent().appendingPathComponent("Temporary")
            let large = Data(("[" + String(repeating: "0,", count: 25_598) + "10]").utf8)
            #expect(large.count == 51_200)
            sender.response = OpenAPIHTTPResponse(status: 200, headers: [], body: large, milliseconds: 9, contentType: "application/json; charset=utf-8")
            let text = try await Self.call(bed, chat, "GET /pets")
            #expect(text.body == nil)
            let textFile = try #require(text.bodyFile)
            #expect(textFile.size == 51_200 && textFile.contentType == "application/json; charset=utf-8")
            #expect(textFile.path.hasPrefix(folder.appendingPathComponent("HephaestusV2/Files/").path))
            #expect(textFile.path.hasSuffix("/response.json"))
            #expect(FileManager.default.contents(atPath: textFile.path) == large)

            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
            sender.response = OpenAPIHTTPResponse(status: 200, headers: [], body: png, milliseconds: 4, contentType: "image/png")
            let binary = try await Self.call(bed, chat, "GET /pets")
            let binaryFile = try #require(binary.bodyFile)
            #expect(binary.body == nil && binaryFile.size == png.count && binaryFile.contentType == "image/png")
            #expect(binaryFile.path.hasSuffix("/response.png") && binaryFile.path != textFile.path)
            #expect(FileManager.default.contents(atPath: binaryFile.path) == png)

            // A small text body with a NUL byte is binary; without Content-Type, the file is `response`.
            sender.response = OpenAPIHTTPResponse(status: 200, headers: [], body: Data("a\u{0}b".utf8), milliseconds: 1, contentType: nil)
            let untyped = try #require(try await Self.call(bed, chat, "GET /pets").bodyFile)
            #expect(untyped.path.hasSuffix("/response") && untyped.contentType == nil && untyped.size == 3)
        }
    }

    @Test("A request that fails without a response fails with unavailable and the error's description")
    func failure() async throws {
        try await Self.withAPIEngine { bed, chat, sender in
            sender.error = URLError(.serverCertificateUntrusted)
            let error = try #require(await engineError { try await Self.call(bed, chat, "GET /pets") })
            #expect(error.code == .unavailable)
            #expect(error.message == "The request failed: \(URLError(.serverCertificateUntrusted).localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))).")
        }
    }
}

/// Records the requests of `api.call` and answers them with `response`, or fails with `error`.
final class RecordedSender: @unchecked Sendable {
    struct Sent {
        var request: URLRequest
        var allowInvalidCertificates: Bool
    }

    private let lock = NSLock()
    private var sent: [Sent] = []
    private var answer = OpenAPIHTTPResponse(status: 200, headers: [], body: Data(), milliseconds: 1, contentType: nil)
    private var failure: Error?

    var requests: [Sent] { lock.withLock { sent } }
    var response: OpenAPIHTTPResponse {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }
    var error: Error? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var send: APIRequestSender {
        { [self] request, allowInvalidCertificates in
            try lock.withLock {
                sent.append(Sent(request: request, allowInvalidCertificates: allowInvalidCertificates))
                if let failure { throw failure }
                return answer
            }
        }
    }
}

extension Engine {
    /// Sends the requests of `api.call` through `sender` and writes the body files in `folder`.
    func useAPISender(_ sender: RecordedSender, folder: URL) {
        apiRequestSender = sender.send
        apiResponseFolder = folder
    }
}

extension OpenAPIStoredOperation {
    init(parameters: [String: String]) {
        self.init()
        self.parameters = parameters
    }
}
