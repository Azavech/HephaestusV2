import Foundation

/// A parsed OpenAPI 3.x contract with its refs resolvable (docs/openapi.md › Contract view).
public struct OpenAPIContract: Sendable {
    /// The methods of a path item, in the order of the list (docs/openapi.md › List).
    public static let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]
    /// The group of the operations without tags.
    public static let defaultTag = "default"

    public let resolver: OpenAPIResolver
    /// The `openapi` value.
    public let version: String
    /// The other project files its refs tried to read, found or not.
    public let readFiles: Set<String>
    public let info: OpenAPIInfo
    public let servers: [OpenAPIServer]
    public let operations: [OpenAPIOperation]
    public let groups: [OpenAPITagGroup]
    public let schemas: [OpenAPINamedSchema]
    public let securitySchemes: [OpenAPISecurityScheme]

    public var path: String { resolver.mainPath }

    init(resolver: OpenAPIResolver, version: String, readFiles: Set<String>) {
        self.resolver = resolver
        self.version = version
        self.readFiles = readFiles
        let path = resolver.mainPath
        let root = OpenAPINode(value: resolver.files[path] ?? .null, file: path)
        let builder = OpenAPIContractBuilder(resolver: resolver)
        info = builder.info(root.value["info"].map { OpenAPINode(value: $0, file: path) })
        servers = builder.servers(root.value["servers"])
        securitySchemes = builder.securitySchemes(root)
        let operations = builder.operations(root)
        self.operations = operations
        groups = builder.groups(root.value["tags"], operations: operations)
        schemas = builder.schemas(root)
    }

    /// The schemes of `securitySchemes` that an operation's form shows (docs/openapi.md ›
    /// Credentials): those its security requirements name, or every supported one when neither the
    /// operation nor the root has `security`.
    public func credentialSchemes(for operation: OpenAPIOperation) -> [OpenAPISecurityScheme] {
        let supported = securitySchemes.filter(\.isSupported)
        guard let requirements = operation.security else { return supported }
        var names: [String] = []
        for requirement in requirements {
            for name in requirement where !names.contains(name) {
                names.append(name)
            }
        }
        return names.compactMap { name in supported.first { $0.name == name } }
    }
}

public struct OpenAPIInfo: Sendable {
    public var title = ""
    public var version = ""
    public var summary: String?
    public var description: String?
    public var termsOfService: String?
    public var contactName: String?
    public var contactEmail: String?
    public var contactURL: String?
    public var licenseName: String?
    public var licenseURL: String?
    public var licenseIdentifier: String?
}

public struct OpenAPIServerVariable: Sendable, Equatable {
    public var name: String
    public var defaultValue: String
    public var values: [String]
    public var description: String?
}

/// A server of the root `servers`, shown in the Info detail (docs/openapi.md › Info detail); the
/// requests go to the project's environments instead (docs/openapi.md › Environment).
public struct OpenAPIServer: Sendable, Equatable {
    /// The URL as written, with its `{variables}`.
    public var url: String
    public var description: String?
    public var variables: [OpenAPIServerVariable]
}

public enum OpenAPIParameterLocation: String, Sendable, CaseIterable {
    case path, query, header, cookie
}

public struct OpenAPIParameter: Sendable, Identifiable {
    /// `<in>:<name>`, the key of its stored value.
    public var id: String { "\(location.rawValue):\(name)" }
    public var name: String
    public var location: OpenAPIParameterLocation
    public var isRequired: Bool
    public var description: String?
    public var schema: OpenAPISchema?
}

public struct OpenAPIMediaType: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var schema: OpenAPISchema?
    /// `example`, else the value of the first member of `examples`.
    public var example: OpenAPIValue?
}

public struct OpenAPIRequestBody: Sendable {
    public var description: String?
    public var isRequired: Bool
    public var content: [OpenAPIMediaType]
    /// The ref as written when it cannot be resolved.
    public var unresolvedRef: String?
}

public struct OpenAPIResponse: Sendable, Identifiable {
    public var id: String { code }
    public var code: String
    public var description: String?
    public var content: [OpenAPIMediaType]
    public var unresolvedRef: String?
}

public struct OpenAPIOperation: Sendable, Identifiable {
    /// `<METHOD> <path>`, the identity of an operation in the list and in the stored values.
    public var id: String { "\(method.uppercased()) \(path)" }
    /// Lowercase, as in the contract.
    public var method: String
    public var path: String
    public var summary: String?
    public var description: String?
    public var tags: [String]
    public var parameters: [OpenAPIParameter]
    /// Parameters whose ref cannot be resolved, as written.
    public var unresolvedParameters: [String]
    public var requestBody: OpenAPIRequestBody?
    public var responses: [OpenAPIResponse]
    /// The scheme names of each security requirement; nil when neither the operation nor the root
    /// has `security`.
    public var security: [[String]]?
}

public struct OpenAPITagGroup: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String?
    public var operations: [OpenAPIOperation]
}

public struct OpenAPINamedSchema: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var schema: OpenAPISchema
}

public struct OpenAPISecurityScheme: Sendable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// `name` and `in` (`query`, `header` or `cookie`).
        case apiKey(name: String, location: String)
        case basic
        case bearer
        /// Any other type or http scheme; not shown in forms.
        case unsupported
    }

    public var id: String { name }
    /// The scheme's name in `components.securitySchemes`.
    public var name: String
    public var kind: Kind
    public var description: String?

    public var isSupported: Bool { kind != .unsupported }
}

// MARK: - Building

/// Builds the contract's model from its resolved values.
struct OpenAPIContractBuilder {
    let resolver: OpenAPIResolver

    private func resolved(_ node: OpenAPINode) -> OpenAPIResolution {
        resolver.resolve(node)
    }

    func info(_ node: OpenAPINode?) -> OpenAPIInfo {
        var info = OpenAPIInfo()
        guard let node, let value = resolved(node).node?.value else { return info }
        info.title = value["title"]?.scalarText ?? ""
        info.version = value["version"]?.scalarText ?? ""
        info.summary = value["summary"]?.stringValue
        info.description = value["description"]?.stringValue
        info.termsOfService = value["termsOfService"]?.stringValue
        info.contactName = value["contact"]?["name"]?.stringValue
        info.contactEmail = value["contact"]?["email"]?.stringValue
        info.contactURL = value["contact"]?["url"]?.stringValue
        info.licenseName = value["license"]?["name"]?.stringValue
        info.licenseURL = value["license"]?["url"]?.stringValue
        info.licenseIdentifier = value["license"]?["identifier"]?.stringValue
        return info
    }

    func servers(_ value: OpenAPIValue?) -> [OpenAPIServer] {
        (value?.arrayValue ?? []).compactMap { server in
            guard let url = server["url"]?.stringValue else { return nil }
            let variables = (server["variables"]?.members ?? []).map { member in
                OpenAPIServerVariable(name: member.key,
                                      defaultValue: member.value["default"]?.scalarText ?? "",
                                      values: (member.value["enum"]?.arrayValue ?? []).compactMap(\.scalarText),
                                      description: member.value["description"]?.stringValue)
            }
            return OpenAPIServer(url: url, description: server["description"]?.stringValue, variables: variables)
        }
    }

    func securitySchemes(_ root: OpenAPINode) -> [OpenAPISecurityScheme] {
        (root.value["components"]?["securitySchemes"]?.members ?? []).map { member in
            let scheme = resolved(OpenAPINode(value: member.value, file: root.file)).node?.value ?? .null
            let kind: OpenAPISecurityScheme.Kind
            switch scheme["type"]?.stringValue {
            case "apiKey":
                kind = .apiKey(name: scheme["name"]?.stringValue ?? member.key, location: scheme["in"]?.stringValue ?? "header")
            case "http":
                switch scheme["scheme"]?.stringValue?.lowercased() {
                case "basic": kind = .basic
                case "bearer": kind = .bearer
                default: kind = .unsupported
                }
            default:
                kind = .unsupported
            }
            return OpenAPISecurityScheme(name: member.key, kind: kind, description: scheme["description"]?.stringValue)
        }
    }

    func operations(_ root: OpenAPINode) -> [OpenAPIOperation] {
        let rootSecurity = security(root.value["security"])
        var operations: [OpenAPIOperation] = []
        for member in root.value["paths"]?.members ?? [] {
            guard let item = resolved(OpenAPINode(value: member.value, file: root.file)).node else { continue }
            let pathParameters = item.value["parameters"]?.arrayValue ?? []
            for method in OpenAPIContract.methods {
                guard let operationValue = item.value[method], operationValue.members != nil else { continue }
                let operation = OpenAPINode(value: operationValue, file: item.file)
                var (parameters, unresolved) = self.parameters(pathParameters, file: item.file)
                let (own, ownUnresolved) = self.parameters(operationValue["parameters"]?.arrayValue ?? [], file: item.file)
                for parameter in own {
                    if let index = parameters.firstIndex(where: { $0.id == parameter.id }) {
                        parameters[index] = parameter
                    } else {
                        parameters.append(parameter)
                    }
                }
                unresolved += ownUnresolved
                operations.append(OpenAPIOperation(
                    method: method,
                    path: member.key,
                    summary: operationValue["summary"]?.stringValue,
                    description: operationValue["description"]?.stringValue,
                    tags: (operationValue["tags"]?.arrayValue ?? []).compactMap(\.scalarText),
                    parameters: parameters,
                    unresolvedParameters: unresolved,
                    requestBody: requestBody(operationValue["requestBody"], file: operation.file),
                    responses: responses(operationValue["responses"], file: operation.file),
                    security: operationValue["security"] != nil ? security(operationValue["security"]) : rootSecurity))
            }
        }
        return operations
    }

    private func security(_ value: OpenAPIValue?) -> [[String]]? {
        guard let requirements = value?.arrayValue else { return nil }
        return requirements.map { ($0.members ?? []).map(\.key) }
    }

    private func parameters(_ values: [OpenAPIValue], file: String) -> ([OpenAPIParameter], [String]) {
        var parameters: [OpenAPIParameter] = []
        var unresolved: [String] = []
        for value in values {
            let resolution = resolved(OpenAPINode(value: value, file: file))
            guard let node = resolution.node else {
                unresolved.append(resolution.ref ?? "")
                continue
            }
            guard let name = node.value["name"]?.scalarText,
                  let location = node.value["in"]?.stringValue.flatMap(OpenAPIParameterLocation.init(rawValue:)) else { continue }
            var schemaValue = node.value["schema"]
            if schemaValue == nil, let first = node.value["content"]?.members?.first {
                schemaValue = first.value["schema"]
            }
            parameters.append(OpenAPIParameter(
                name: name,
                location: location,
                isRequired: location == .path || node.value["required"]?.boolValue == true,
                description: node.value["description"]?.stringValue,
                schema: schemaValue.map { OpenAPISchema.make(resolver: resolver, node: OpenAPINode(value: $0, file: node.file), chain: []) }))
        }
        return (parameters, unresolved)
    }

    private func requestBody(_ value: OpenAPIValue?, file: String) -> OpenAPIRequestBody? {
        guard let value else { return nil }
        let resolution = resolved(OpenAPINode(value: value, file: file))
        guard let node = resolution.node else {
            return OpenAPIRequestBody(description: nil, isRequired: false, content: [], unresolvedRef: resolution.ref)
        }
        return OpenAPIRequestBody(description: node.value["description"]?.stringValue,
                                  isRequired: node.value["required"]?.boolValue == true,
                                  content: content(node.value["content"], file: node.file))
    }

    private func responses(_ value: OpenAPIValue?, file: String) -> [OpenAPIResponse] {
        (value?.members ?? []).map { member in
            let resolution = resolved(OpenAPINode(value: member.value, file: file))
            guard let node = resolution.node else {
                return OpenAPIResponse(code: member.key, description: nil, content: [], unresolvedRef: resolution.ref)
            }
            return OpenAPIResponse(code: member.key, description: node.value["description"]?.stringValue,
                                   content: content(node.value["content"], file: node.file))
        }
    }

    private func content(_ value: OpenAPIValue?, file: String) -> [OpenAPIMediaType] {
        (value?.members ?? []).map { member in
            let media = resolved(OpenAPINode(value: member.value, file: file)).node ?? OpenAPINode(value: .null, file: file)
            var example = media.value["example"]
            if example == nil, let first = media.value["examples"]?.members?.first {
                example = resolved(OpenAPINode(value: first.value, file: media.file)).node?.value["value"]
            }
            return OpenAPIMediaType(
                name: member.key,
                schema: media.value["schema"].map { OpenAPISchema.make(resolver: resolver, node: OpenAPINode(value: $0, file: media.file), chain: []) },
                example: example)
        }
    }

    func groups(_ tags: OpenAPIValue?, operations: [OpenAPIOperation]) -> [OpenAPITagGroup] {
        var names: [String] = []
        var descriptions: [String: String] = [:]
        for tag in tags?.arrayValue ?? [] {
            guard let name = tag["name"]?.scalarText, !names.contains(name) else { continue }
            names.append(name)
            descriptions[name] = tag["description"]?.stringValue
        }
        for operation in operations {
            for tag in operation.tags where !names.contains(tag) {
                names.append(tag)
            }
        }
        var groups = names.compactMap { name -> OpenAPITagGroup? in
            let members = operations.filter { $0.tags.contains(name) }
            guard !members.isEmpty else { return nil }
            return OpenAPITagGroup(name: name, description: descriptions[name], operations: members)
        }
        let untagged = operations.filter(\.tags.isEmpty)
        if !untagged.isEmpty {
            groups.append(OpenAPITagGroup(name: OpenAPIContract.defaultTag, description: nil, operations: untagged))
        }
        return groups
    }

    func schemas(_ root: OpenAPINode) -> [OpenAPINamedSchema] {
        (root.value["components"]?["schemas"]?.members ?? []).map { member in
            let key = OpenAPIResolver.Target(file: root.file, pointer: ["components", "schemas", member.key]).key
            return OpenAPINamedSchema(name: member.key,
                                      schema: OpenAPISchema.make(resolver: resolver, node: OpenAPINode(value: member.value, file: root.file),
                                                                 chain: [key]))
        }
    }
}

// MARK: - Schemas

/// A schema of the contract, its refs followed lazily so that large and circular contracts stay
/// cheap (docs/openapi.md › Schema trees).
public struct OpenAPISchema: Sendable {
    public let resolver: OpenAPIResolver
    /// The schema's value; nil when its ref cannot be resolved.
    public let node: OpenAPINode?
    /// The first `$ref` followed to reach it, as written.
    public let ref: String?
    /// True when its ref is already on the way from the top: it has no children.
    public let isCircular: Bool
    /// The refs followed from the top, `<file>#<pointer>`.
    let chain: [String]

    /// The schema of a value, following its refs.
    static func make(resolver: OpenAPIResolver, node: OpenAPINode, chain: [String]) -> OpenAPISchema {
        let resolution = resolver.resolve(node)
        let circular = resolution.keys.contains { chain.contains($0) }
        return OpenAPISchema(resolver: resolver, node: resolution.node, ref: resolution.ref, isCircular: circular,
                             chain: chain + resolution.keys)
    }

    public var isUnresolved: Bool { node == nil }

    /// The name its ref gives it (`Pet` for `#/components/schemas/Pet`).
    public var name: String? { ref.map(OpenAPIResolver.name(of:)) }

    var value: OpenAPIValue { node?.value ?? .null }

    private func child(_ value: OpenAPIValue) -> OpenAPISchema {
        .make(resolver: resolver, node: OpenAPINode(value: value, file: node?.file ?? resolver.mainPath), chain: chain)
    }

    /// `type` as a list (3.1 allows an array).
    public var types: [String] {
        switch value["type"] {
        case .string(let type): return [type]
        case .array(let items): return items.compactMap(\.stringValue)
        default: return []
        }
    }

    public var format: String? { value["format"]?.scalarText }
    public var title: String? { value["title"]?.stringValue }
    public var description: String? { value["description"]?.stringValue }
    public var enumValues: [OpenAPIValue] { value["enum"]?.arrayValue ?? [] }
    public var isNullable: Bool { value["nullable"]?.boolValue == true }
    public var isReadOnly: Bool { value["readOnly"]?.boolValue == true }
    public var defaultValue: OpenAPIValue? { value["default"] }
    public var constValue: OpenAPIValue? { value["const"] }
    public var minimum: OpenAPIValue? { value["minimum"] }

    /// `example`, else the first value of `examples` when it is an array (3.1).
    public var example: OpenAPIValue? {
        if let example = value["example"] { return example }
        return value["examples"]?.arrayValue?.first
    }

    public var requiredNames: [String] {
        (value["required"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    public var hasProperties: Bool { value["properties"]?.members != nil }

    public var properties: [OpenAPIProperty] {
        guard !isCircular else { return [] }
        let required = requiredNames
        return (value["properties"]?.members ?? []).map {
            OpenAPIProperty(name: $0.key, isRequired: required.contains($0.key), schema: child($0.value))
        }
    }

    public var items: OpenAPISchema? {
        guard !isCircular, let items = value["items"], items.members != nil else { return nil }
        return child(items)
    }

    /// `additionalProperties` when it is a schema.
    public var additionalProperties: OpenAPISchema? {
        guard !isCircular, let additional = value["additionalProperties"], additional.members != nil else { return nil }
        return child(additional)
    }

    /// The schemas of `allOf`, `oneOf` or `anyOf`.
    public func composition(_ keyword: String) -> [OpenAPISchema] {
        guard !isCircular else { return [] }
        return (value[keyword]?.arrayValue ?? []).map(child)
    }

    public static let compositionKeywords = ["allOf", "oneOf", "anyOf"]

    public var hasChildren: Bool {
        guard !isCircular, node != nil else { return false }
        return !properties.isEmpty || items != nil || additionalProperties != nil
            || Self.compositionKeywords.contains { !composition($0).isEmpty }
    }

    /// The type summary of a row (docs/openapi.md › Schema trees).
    public var typeSummary: String {
        var base: String
        let types = self.types
        if !types.isEmpty {
            base = types.joined(separator: " | ")
            if isNullable { base += " | null" }
        } else if hasProperties {
            base = "object"
        } else if let keyword = Self.compositionKeywords.first(where: { value[$0] != nil }) {
            base = keyword
        } else {
            base = "any"
        }
        if let name {
            return "\(name) · \(base)"
        }
        return base
    }
}

public struct OpenAPIProperty: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isRequired: Bool
    public var schema: OpenAPISchema
}
