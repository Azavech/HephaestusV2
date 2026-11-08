import Foundation
import Security
import Testing
@testable import HephaestusCore

/// A contract of the tests: tags, path-level parameters, a request body, refs inside the document
/// and to another file, and a circular schema.
private let petStore = """
openapi: 3.1.0
info:
  title: Pet Store
  version: 1.2.0
servers:
  - url: https://{region}.example.com/v1
    variables:
      region:
        default: eu
        enum: [eu, us]
  - url: /relative
tags:
  - name: pets
    description: Everything about pets
security:
  - bearerAuth: []
paths:
  /pets:
    get:
      tags: [pets]
      summary: List pets
      parameters:
        - name: limit
          in: query
          schema: { type: integer, minimum: 1 }
      responses:
        '200':
          description: A list
          content:
            application/json:
              schema:
                type: array
                items: { $ref: '#/components/schemas/Pet' }
    post:
      tags: [pets]
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/NewPet' }
          application/x-www-form-urlencoded:
            schema: { $ref: '#/components/schemas/NewPet' }
      responses:
        '201': { $ref: '#/components/responses/Created' }
  /pets/{petId}:
    parameters:
      - $ref: '#/components/parameters/PetId'
    get:
      tags: [pets, store]
      security: []
      responses:
        default:
          description: Any
          content:
            application/json:
              schema: { $ref: 'schemas/error.yaml#/Error' }
  /health:
    get:
      responses:
        '200': { description: OK }
components:
  parameters:
    PetId:
      name: petId
      in: path
      schema: { type: string, format: uuid }
  responses:
    Created:
      description: Created
  securitySchemes:
    bearerAuth: { type: http, scheme: bearer }
    basicAuth: { type: http, scheme: basic }
    apiKey: { type: apiKey, name: X-API-Key, in: header }
    oauth: { type: oauth2, flows: {} }
  schemas:
    Pet:
      type: object
      required: [id, name]
      properties:
        id: { type: integer, readOnly: true }
        name: { type: string }
        parent: { $ref: '#/components/schemas/Pet' }
        owner: { $ref: 'schemas/owner.json' }
        missing: { $ref: '#/components/schemas/Missing' }
    NewPet:
      type: object
      properties:
        id: { type: integer, readOnly: true }
        name: { type: string, example: Rex }
        born: { type: string, format: date }
        tags: { type: array, items: { type: string } }
"""

private let errorFile = """
Error:
  type: object
  properties:
    code: { type: integer }
    message: { type: string }
"""

private let ownerFile = """
{ "type": "object", "properties": { "email": { "type": "string", "format": "email" } } }
"""

/// Loads a contract with other files given by path.
private func load(_ text: String, path: String = "api/openapi.yaml", files: [String: String] = [:]) async -> Result<OpenAPIContract, OpenAPIParseError> {
    await OpenAPILoader.load(path: path, text: text, isJSON: { $0.hasSuffix(".json") }, read: { files[$0] })
}

private func loadContract(_ text: String = petStore, files: [String: String] = ["api/schemas/error.yaml": errorFile,
                                                                           "api/schemas/owner.json": ownerFile]) async throws -> OpenAPIContract {
    try await load(text, files: files).get()
}

@Suite("OpenAPI detection")
struct OpenAPIDetectionTests {
    @Test("OpenAPI 3.0 and 3.1 YAML files are detected, quoted or not, with comments")
    func yaml() {
        #expect(OpenAPIDetection.isContract(text: "openapi: 3.1.0\ninfo: {}\n", isJSON: false))
        #expect(OpenAPIDetection.isContract(text: "# API\n---\nopenapi: \"3.0.3\" # version\n", isJSON: false))
        #expect(OpenAPIDetection.isContract(text: "info:\n  title: x\n'openapi': '3.0.0'\n", isJSON: false))
        #expect(OpenAPIDetection.isContract(text: "openapi: 3.0\npaths: [unclosed\n", isJSON: false))
        #expect(OpenAPIDetection.isContract(text: "description: |\nopenapi: 3.0.0\n", isJSON: false))
        #expect(!OpenAPIDetection.isContract(text: "tags: [a,\nopenapi: 3.0.0]\n", isJSON: false))
    }

    @Test("OpenAPI 3.x JSON files are detected at the top level only")
    func json() {
        #expect(OpenAPIDetection.isContract(text: #"{"info": {"openapi": "2"}, "openapi": "3.1.0"}"#, isJSON: true))
        #expect(OpenAPIDetection.isContract(text: "{\n  \"openapi\" : \"3.0.2\",\n  \"paths\": {}\n}", isJSON: true))
        #expect(!OpenAPIDetection.isContract(text: #"{"info": {"openapi": "3.0.0"}}"#, isJSON: true))
        #expect(!OpenAPIDetection.isContract(text: #"[{"openapi": "3.0.0"}]"#, isJSON: true))
        // A YAML file holding JSON is scanned as JSON.
        #expect(OpenAPIDetection.isContract(text: "# comment\n{\"openapi\": \"3.0.0\"}", isJSON: false))
    }

    @Test("Swagger 2.0 and other files are not detected")
    func rejected() {
        #expect(!OpenAPIDetection.isContract(text: "swagger: \"2.0\"\ninfo: {}\n", isJSON: false))
        #expect(!OpenAPIDetection.isContract(text: #"{"swagger": "2.0"}"#, isJSON: true))
        #expect(!OpenAPIDetection.isContract(text: "openapi: 2.0\n", isJSON: false))
        #expect(!OpenAPIDetection.isContract(text: "info:\n  openapi: 3.0.0\n", isJSON: false))
        #expect(!OpenAPIDetection.isContract(text: "name: a\n---\nopenapi: 3.0.0\n", isJSON: false))
        #expect(!OpenAPIDetection.isContract(text: "", isJSON: false))
    }
}

@Suite("OpenAPI parsing")
struct OpenAPIParsingTests {
    @Test("Info, servers, tag groups and the order of operations")
    func structure() async throws {
        let contract = try await loadContract()
        #expect(contract.version == "3.1.0")
        #expect(contract.info.title == "Pet Store")
        #expect(contract.info.version == "1.2.0")
        #expect(contract.servers.map(\.url) == ["https://{region}.example.com/v1", "/relative"])
        #expect(contract.servers[0].variables.first?.values == ["eu", "us"])
        #expect(contract.operations.map(\.id) == ["GET /pets", "POST /pets", "GET /pets/{petId}", "GET /health"])
        #expect(contract.groups.map(\.name) == ["pets", "store", "default"])
        #expect(contract.groups[0].description == "Everything about pets")
        #expect(contract.groups[0].operations.map(\.id) == ["GET /pets", "POST /pets", "GET /pets/{petId}"])
        #expect(contract.groups[1].operations.map(\.id) == ["GET /pets/{petId}"])
        #expect(contract.groups[2].operations.map(\.id) == ["GET /health"])
        #expect(contract.schemas.map(\.name) == ["Pet", "NewPet"])
    }

    @Test("Parameters, request bodies and responses reached through refs inside the document")
    func refsInsideTheDocument() async throws {
        let contract = try await loadContract()
        let get = try #require(contract.operations.first { $0.id == "GET /pets/{petId}" })
        #expect(get.parameters.map(\.id) == ["path:petId"])
        #expect(get.parameters[0].isRequired)
        #expect(get.parameters[0].schema?.format == "uuid")
        let post = try #require(contract.operations.first { $0.id == "POST /pets" })
        #expect(post.requestBody?.isRequired == true)
        #expect(post.requestBody?.content.map(\.name) == ["application/json", "application/x-www-form-urlencoded"])
        #expect(post.requestBody?.content[0].schema?.name == "NewPet")
        #expect(post.responses.map(\.code) == ["201"])
        #expect(post.responses[0].description == "Created")
        let pet = try #require(contract.schemas.first?.schema)
        #expect(pet.properties.map(\.name) == ["id", "name", "parent", "owner", "missing"])
        #expect(pet.properties.map(\.isRequired) == [true, true, false, false, false])
        #expect(pet.typeSummary == "object")
        #expect(pet.properties[2].schema.typeSummary == "Pet · object")
    }

    @Test("A ref to another file of the project is followed, relative to the file that holds it")
    func refsAcrossFiles() async throws {
        let contract = try await loadContract()
        let get = try #require(contract.operations.first { $0.id == "GET /pets/{petId}" })
        let error = try #require(get.responses.first?.content.first?.schema)
        #expect(!error.isUnresolved)
        #expect(error.name == "Error")
        #expect(error.properties.map(\.name) == ["code", "message"])
        let owner = try #require(contract.schemas.first?.schema.properties.first { $0.name == "owner" }?.schema)
        #expect(!owner.isUnresolved)
        #expect(owner.name == "owner.json")
        #expect(owner.properties.first?.schema.format == "email")
        #expect(contract.readFiles == ["api/schemas/error.yaml", "api/schemas/owner.json"])
    }

    @Test("Refs that cannot be resolved, and circular refs")
    func unresolvedAndCircular() async throws {
        let contract = try await loadContract(files: [:])
        let pet = try #require(contract.schemas.first?.schema)
        let missing = try #require(pet.properties.first { $0.name == "missing" }?.schema)
        #expect(missing.isUnresolved)
        #expect(missing.ref == "#/components/schemas/Missing")
        #expect(!missing.hasChildren)
        let owner = try #require(pet.properties.first { $0.name == "owner" }?.schema)
        #expect(owner.isUnresolved)
        let parent = try #require(pet.properties.first { $0.name == "parent" }?.schema)
        #expect(parent.isCircular)
        #expect(!parent.isUnresolved)
        #expect(!parent.hasChildren)
        #expect(parent.properties.isEmpty)
    }

    @Test("Refs with a URL scheme, an absolute path or leaving the project are not followed")
    func refTargets() {
        #expect(OpenAPIResolver.target(of: "#/components/schemas/Pet", from: "api/a.yaml")
                == .init(file: "api/a.yaml", pointer: ["components", "schemas", "Pet"]))
        #expect(OpenAPIResolver.target(of: "../common.yaml#/A~1B~0C", from: "api/a.yaml")
                == .init(file: "common.yaml", pointer: ["A/B~C"]))
        #expect(OpenAPIResolver.target(of: "./schemas/pet%20one.yaml", from: "a.yaml")
                == .init(file: "schemas/pet one.yaml", pointer: []))
        #expect(OpenAPIResolver.target(of: "https://example.com/a.yaml", from: "a.yaml") == nil)
        #expect(OpenAPIResolver.target(of: "/etc/a.yaml", from: "a.yaml") == nil)
        #expect(OpenAPIResolver.target(of: "../../a.yaml", from: "api/a.yaml") == nil)
    }

    @Test("Security requirements choose the credentials of the form")
    func credentials() async throws {
        let contract = try await loadContract()
        let list = try #require(contract.operations.first { $0.id == "GET /pets" })
        #expect(contract.credentialSchemes(for: list).map(\.name) == ["bearerAuth"])
        let item = try #require(contract.operations.first { $0.id == "GET /pets/{petId}" })
        #expect(contract.credentialSchemes(for: item).isEmpty)
        let noSecurity = try await loadContract(petStore.replacingOccurrences(of: "security:\n  - bearerAuth: []\n", with: ""))
        let health = try #require(noSecurity.operations.first { $0.id == "GET /health" })
        #expect(noSecurity.credentialSchemes(for: health).map(\.name) == ["bearerAuth", "basicAuth", "apiKey"])
    }

    @Test("Texts that are not an OpenAPI 3.x document fail with a message")
    func failures() async {
        guard case .failure(let syntax) = await load("openapi: 3.0.0\npaths: [unclosed\n") else {
            Issue.record("expected a failure")
            return
        }
        #expect(!syntax.message.isEmpty)
        guard case .failure(let version) = await load("swagger: \"2.0\"\n") else {
            Issue.record("expected a failure")
            return
        }
        #expect(version.message == "The document has no openapi version starting with 3.")
        guard case .failure(let json) = await load("{\"openapi\": \"3.0.0\",}", path: "a.json") else {
            Issue.record("expected a failure")
            return
        }
        #expect(json.message.hasPrefix("1:"))
    }

    @Test("JSON keeps the order of members and the text of numbers; YAML follows the 1.2 core schema")
    func values() throws {
        let json = try OpenAPIValue.parseJSON(#"{"b": 1.50, "a": [true, null, "xé"]}"#)
        #expect(json.members?.map(\.key) == ["b", "a"])
        #expect(json["b"] == .number("1.50"))
        #expect(json["a"] == .array([.bool(true), .null, .string("xé")]))
        let yaml = try OpenAPIValue.parseYAML("a: yes\nb: 0x1F\nc: 1e3\nd: ~\ne: '42'\n")
        #expect(yaml["a"] == .string("yes"))
        #expect(yaml["b"] == .number("31"))
        #expect(yaml["c"] == .number("1e3"))
        #expect(yaml["d"] == .null)
        #expect(yaml["e"] == .string("42"))
        #expect(json.jsonText() == "{\n  \"b\": 1.50,\n  \"a\": [\n    true,\n    null,\n    \"xé\"\n  ]\n}")
    }
}

@Suite("OpenAPI samples")
struct OpenAPISampleTests {
    @Test("A JSON body is the sample of its schema: readOnly left out, formats, examples")
    func jsonSample() async throws {
        let contract = try await loadContract()
        let post = try #require(contract.operations.first { $0.id == "POST /pets" })
        let json = try #require(post.requestBody?.content.first)
        #expect(OpenAPISample.body(for: json) == """
        {
          "name": "Rex",
          "born": "2024-01-01",
          "tags": [
            "string"
          ]
        }
        """)
        let form = try #require(post.requestBody?.content.last)
        #expect(OpenAPISample.body(for: form) == "name=Rex&born=2024-01-01&tags=%5B%22string%22%5D")
    }

    @Test("The contract's example wins over the schema; examples give their first value")
    func examples() async throws {
        let text = """
        openapi: 3.0.0
        info: { title: t, version: '1' }
        paths:
          /a:
            post:
              requestBody:
                content:
                  application/json:
                    schema: { type: object, properties: { a: { type: string } } }
                    example: { b: 2 }
                  application/problem+json:
                    examples:
                      first: { $ref: '#/components/examples/One' }
                      second: { value: 2 }
                  text/plain:
                    example: hello
              responses: {}
        components:
          examples:
            One: { value: { one: 1 } }
        """
        let contract = try await loadContract(text, files: [:])
        let content = try #require(contract.operations.first?.requestBody?.content)
        #expect(OpenAPISample.body(for: content[0]) == "{\n  \"b\": 2\n}")
        #expect(OpenAPISample.body(for: content[1]) == "{\n  \"one\": 1\n}")
        #expect(OpenAPISample.body(for: content[2]) == "hello")
    }

    @Test("Samples follow the table of rules")
    func rules() async throws {
        let text = """
        openapi: 3.1.0
        info: { title: t, version: '1' }
        paths: {}
        components:
          schemas:
            S:
              type: object
              properties:
                enum: { type: string, enum: [b, a] }
                default: { type: integer, default: 7 }
                min: { type: number, minimum: 2.5 }
                flag: { type: boolean }
                nullable: { type: [string, 'null'] }
                email: { type: string, format: email }
                one: { oneOf: [ { type: integer }, { type: string } ] }
                all: { allOf: [ { properties: { a: { type: integer } } }, { properties: { b: { const: x } } } ] }
                empty: { type: array }
                self: { $ref: '#/components/schemas/S' }
                lost: { $ref: '#/components/schemas/Lost' }
                anything: {}
        """
        let contract = try await loadContract(text, files: [:])
        let schema = try #require(contract.schemas.first?.schema)
        let sample = try #require(OpenAPISample.value(for: schema))
        #expect(sample.jsonText(pretty: false)
                == #"{"enum":"b","default":7,"min":2.5,"flag":true,"nullable":"string","email":"user@example.com","one":0,"all":{"a":0,"b":"x"},"empty":[],"anything":null}"#)
    }
}

@Suite("OpenAPI requests")
struct OpenAPIRequestTests {
    @Test("The URL takes the environment's base URL, the path parameters and the query")
    func url() throws {
        let environment = ProjectEnvironment(name: "local", url: "http://127.0.0.1/v1/", port: 8080)
        let input = OpenAPIRequestInput(
            baseURL: try #require(environment.baseURL), method: "get", path: "/pets/{petId}/toys",
            parameters: [(.path, "petId", "a b/c"), (.query, "limit", "10"), (.query, "empty", ""), (.query, "q", "x&y=é")],
            credentials: [.apiKey(name: "key", location: "query", value: "k1")])
        #expect(OpenAPIRequestBuilder.url(for: input)
                == "http://127.0.0.1:8080/v1/pets/a%20b%2Fc/toys?limit=10&q=x%26y%3D%C3%A9&key=k1")
        let stagingBaseURL = try #require(ProjectEnvironment(name: "staging", url: "https://staging.example.com/").baseURL)
        let request = try #require(OpenAPIRequestBuilder.request(for: OpenAPIRequestInput(
            baseURL: stagingBaseURL, method: "delete", path: "/pets")))
        #expect(request.url?.absoluteString == "https://staging.example.com/pets")
        #expect(request.httpMethod == "DELETE")
        #expect(OpenAPIRequestBuilder.isUsableBaseURL("http://127.0.0.1:8080"))
        #expect(!OpenAPIRequestBuilder.isUsableBaseURL("/v1"))
        #expect(!OpenAPIRequestBuilder.isUsableBaseURL(""))
        #expect(!OpenAPIRequestBuilder.isUsableBaseURL("ftp://example.com"))
    }

    @Test("The base URL of an environment: its URL with the port replaced by its port, without a trailing slash")
    func environmentBaseURL() {
        let cases: [(url: String, port: Int?, baseURL: String)] = [
            ("http://127.0.0.1", 8080, "http://127.0.0.1:8080"),
            ("https://api.example.com:8443/v1/", 9000, "https://api.example.com:9000/v1"),
            ("https://api.example.com:8443/v1", nil, "https://api.example.com:8443/v1"),
            ("https://staging.example.com/", nil, "https://staging.example.com"),
            ("http://localhost:3000//", nil, "http://localhost:3000"),
            (" http://[::1] ", 8080, "http://[::1]:8080"),
            ("http://user@localhost/api?x=1", 8081, "http://user@localhost:8081/api?x=1"),
        ]
        for item in cases {
            #expect(ProjectEnvironment(name: "e", url: item.url, port: item.port).baseURL == item.baseURL, "\(item.url)")
        }
        #expect(ProjectEnvironment(name: "e", url: "http://127.0.0.1", port: 8080).isUsable)
        #expect(ProjectEnvironment(name: "e", url: " https://staging.example.com ").isUsable)
        #expect(!ProjectEnvironment(name: "e", url: "ftp://example.com").isUsable)
        #expect(!ProjectEnvironment(name: "e", url: "127.0.0.1:8080").isUsable)
        #expect(!ProjectEnvironment(name: "e", url: "http://127.0.0.1", port: 70000).isUsable)
        #expect(!ProjectEnvironment(name: "e", url: "http://127.0.0.1", port: -1).isUsable)
        #expect(ProjectEnvironment(name: "e", url: "http://127.0.0.1", port: -1).baseURL == "http://127.0.0.1")
        // Without a URL, an environment has no base URL, whatever its port, and cannot send.
        #expect(ProjectEnvironment(name: "e").baseURL == nil)
        #expect(ProjectEnvironment(name: "e", port: 8080).baseURL == nil)
        #expect(!ProjectEnvironment(name: "e", port: 8080).isUsable)
    }

    @Test("Headers: parameters, cookies, credentials, content type, then added headers")
    func headers() throws {
        let input = OpenAPIRequestInput(
            baseURL: "http://localhost:8080/", method: "post", path: "/a",
            parameters: [(.header, "X-Trace", "t1"), (.cookie, "session", "s1"), (.header, "X-Empty", "")],
            credentials: [.apiKey(name: "theme", location: "cookie", value: "dark"), .apiKey(name: "X-API-Key", location: "header", value: "k"),
                          .basic(username: "user", password: "pass"), .bearer(token: "")],
            mediaType: "application/json", body: "{}", headers: [OpenAPIHeader(name: "authorization", value: "Custom"), OpenAPIHeader(name: " ", value: "x")])
        #expect(OpenAPIRequestBuilder.headers(for: input) == [
            OpenAPIHeader(name: "X-Trace", value: "t1"),
            OpenAPIHeader(name: "Cookie", value: "session=s1; theme=dark"),
            OpenAPIHeader(name: "X-API-Key", value: "k"),
            OpenAPIHeader(name: "Content-Type", value: "application/json"),
            OpenAPIHeader(name: "authorization", value: "Custom"),
        ])
        let request = try #require(OpenAPIRequestBuilder.request(for: input))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://localhost:8080/a")
        #expect(request.httpBody == Data("{}".utf8))
        let bearer = OpenAPIRequestInput(baseURL: "https://a.example", method: "get", path: "/", credentials: [.bearer(token: "t"), .basic(username: "u", password: "")])
        #expect(OpenAPIRequestBuilder.headers(for: bearer).map(\.value) == ["Basic dTo=", "Bearer t"])
        #expect(OpenAPIRequestBuilder.request(for: OpenAPIRequestInput(baseURL: "", method: "get", path: "/")) == nil)
    }

    @Test("Status texts use the reason phrases")
    func statusText() {
        #expect(OpenAPIHTTPResponse(status: 200, headers: [], body: Data(), milliseconds: 1, contentType: nil).statusText == "200 OK")
        #expect(OpenAPIHTTPResponse(status: 299, headers: [], body: Data(), milliseconds: 1, contentType: nil).statusText == "299")
    }

    /// A self-signed certificate for `localhost`, which no system trusts.
    static let selfSignedCertificate = """
        MIIBGDCBvgIJAI/vKkl67OMlMAoGCCqGSM49BAMCMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDAeFw0yNjExMDgxMzU1MjlaFw0zNjEx\
        MDUxMzU1MjlaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABALaZSWMwouaHSWKtr+AA+Ry\
        uKbXdNfXMNikBQZzoifvEF1SWCgtktMqnu4Wp/n16bNfbrktGAiHRN/QnG7GI3swCgYIKoZIzj0EAwIDSQAwRgIhANS3LoFZIel1\
        hv+wt844KpNKKktuzDK+2T0RamadXj7kAiEAwjQbUSO7/1AUkahOcKgAlLRccqNtJPbRbctMofZa+gQ=
        """

    @Test("With Allow invalid certificates, a server trust challenge trusts the server; without it, and for other challenges, the default handling applies")
    func trustDecision() throws {
        let data = try #require(Data(base64Encoded: Self.selfSignedCertificate))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "10.0.0.5" as CFString), &trust) == errSecSuccess)
        let serverTrust = try #require(trust)
        #expect(!SecTrustEvaluateWithError(serverTrust, nil))

        let accepted = OpenAPIHTTPClient.trustDecision(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                                       serverTrust: serverTrust, allowInvalidCertificates: true)
        #expect(accepted.0 == .useCredential)
        #expect(accepted.1 != nil)

        let checked = OpenAPIHTTPClient.trustDecision(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                                      serverTrust: serverTrust, allowInvalidCertificates: false)
        #expect(checked.0 == .performDefaultHandling)
        #expect(checked.1 == nil)

        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodClientCertificate] {
            let other = OpenAPIHTTPClient.trustDecision(authenticationMethod: method, serverTrust: serverTrust, allowInvalidCertificates: true)
            #expect(other.0 == .performDefaultHandling, "\(method)")
            #expect(other.1 == nil, "\(method)")
        }
        #expect(OpenAPIHTTPClient.trustDecision(authenticationMethod: NSURLAuthenticationMethodServerTrust, serverTrust: nil,
                                                allowInvalidCertificates: true).0 == .performDefaultHandling)
    }
}

@Suite("OpenAPI stored values")
struct OpenAPIRequestStoreTests {
    @Test("Values are written with mode 0600 and read back by a new store")
    func roundTrip() throws {
        try withTemporaryDirectory { folder in
            let file = folder.appendingPathComponent(OpenAPIRequestStore.fileName)
            let store = OpenAPIRequestStore(file: file)
            var contract = store.contract(deviceID: "D1", projectID: "DEMO", path: "api/openapi.yaml")
            #expect(contract.operations.isEmpty)
            contract.credentials["bearerAuth"] = OpenAPIStoredCredential(token: "secret")
            contract.headers = [OpenAPIHeader(name: "X-Tenant", value: "demo")]
            var operation = OpenAPIStoredOperation()
            operation.parameters["query:limit"] = "5"
            operation.mediaType = "application/json"
            operation.bodies["application/json"] = "{}"
            contract.operations["GET /pets"] = operation
            store.set(contract)
            store.set(OpenAPIStoredContract(deviceID: "D2", projectID: "DEMO", path: "api/openapi.yaml"))
            try store.save()

            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
            let reread = OpenAPIRequestStore(file: file)
            #expect(reread.contract(deviceID: "D1", projectID: "DEMO", path: "api/openapi.yaml") == contract)
            #expect(reread.contract(deviceID: "D1", projectID: "OTHER", path: "api/openapi.yaml").credentials.isEmpty)
        }
    }

    @Test("A missing or invalid file counts as empty and is replaced at the next write")
    func invalidFile() throws {
        try withTemporaryDirectory { folder in
            let file = folder.appendingPathComponent(OpenAPIRequestStore.fileName)
            #expect(OpenAPIRequestStore(file: file).contract(deviceID: "D", projectID: "P", path: "a.yaml").headers.isEmpty)
            try Data("not json".utf8).write(to: file)
            let store = OpenAPIRequestStore(file: file)
            var contract = store.contract(deviceID: "D", projectID: "P", path: "a.yaml")
            contract.headers = [OpenAPIHeader(name: "X-Tenant", value: "demo")]
            store.set(contract)
            try store.save()
            #expect(OpenAPIRequestStore(file: file).contract(deviceID: "D", projectID: "P", path: "a.yaml").headers
                == [OpenAPIHeader(name: "X-Tenant", value: "demo")])
        }
    }

    @Test("The environment and server keys of an earlier version are ignored and left out at the next write")
    func earlierServerKeys() throws {
        try withTemporaryDirectory { folder in
            let file = folder.appendingPathComponent(OpenAPIRequestStore.fileName)
            try Data(#"""
                {"contracts": [{"deviceID": "D", "projectID": "P", "path": "a.yaml", "environment": "staging",
                  "server": "https://{region}.example.com/v1", "usesCustomURL": true, "customURL": "http://localhost:3000",
                  "serverVariables": {"https://{region}.example.com/v1": {"region": "us"}},
                  "headers": [{"name": "X-Tenant", "value": "demo"}]}]}
                """#.utf8).write(to: file)
            let store = OpenAPIRequestStore(file: file)
            var contract = store.contract(deviceID: "D", projectID: "P", path: "a.yaml")
            #expect(contract.headers == [OpenAPIHeader(name: "X-Tenant", value: "demo")])
            contract.headers.append(OpenAPIHeader(name: "X-Trace", value: "1"))
            store.set(contract)
            try store.save()
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains(#""X-Trace""#))
            for key in ["environment", "server", "usesCustomURL", "customURL", "serverVariables"] {
                #expect(!text.contains("\"\(key)\""), "\(key)")
            }
        }
    }

    @Test("The example of docs/openapi.md › Stored values reads back")
    func docsExample() throws {
        let block = try #require(MarkdownSource.fencedBlocks(in: try Repository.doc("openapi.md"))
            .first { $0.heading == "## Stored values" && $0.info == "json" })
        try withTemporaryDirectory { folder in
            let file = folder.appendingPathComponent(OpenAPIRequestStore.fileName)
            try Data(block.text.utf8).write(to: file)
            let contract = OpenAPIRequestStore(file: file)
                .contract(deviceID: "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E", projectID: "DEMO", path: "api/openapi.yaml")
            #expect(contract.credentials["bearerAuth"]?.token == "example-token")
            #expect(contract.headers == [OpenAPIHeader(name: "X-Tenant", value: "demo")])
            #expect(contract.operations["GET /pets/{petId}"]?.parameters["path:petId"] == "42")
        }
    }
}
