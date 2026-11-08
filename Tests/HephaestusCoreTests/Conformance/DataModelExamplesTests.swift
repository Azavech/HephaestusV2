import Foundation
import Testing
import Yams
@testable import HephaestusCore

/// Docs conformance test 4 (docs/ci.md › Docs conformance tests): the examples of
/// docs/data-model.md decode with the Swift models, as docs/data-model.md › Conformance tests
/// states.
@Suite("Data model examples")
struct DataModelExamplesTests {
    struct Example: CustomTestStringConvertible, Sendable {
        var path: String
        var format: String
        var text: String
        var testDescription: String { path }
    }

    /// Every `yaml` block whose first line is `# <path>`, and every `json <path>` or
    /// `jsonl <path>` block.
    static func examples() throws -> [Example] {
        let blocks = MarkdownSource.fencedBlocks(in: try Repository.doc("data-model.md"))
        var examples: [Example] = []
        for block in blocks {
            if block.info == "yaml", let first = block.lines.first, first.hasPrefix("# ") {
                examples.append(Example(path: String(first.dropFirst(2)), format: "yaml", text: block.text + "\n"))
            } else if block.info.hasPrefix("json ") {
                examples.append(Example(path: String(block.info.dropFirst(5)), format: "json", text: block.text + "\n"))
            } else if block.info.hasPrefix("jsonl ") {
                examples.append(Example(path: String(block.info.dropFirst(6)), format: "jsonl", text: block.text + "\n"))
            }
        }
        return examples
    }

    @Test("Every row of the conformance table has an example")
    func everyTypeHasAnExample() throws {
        let paths = try Self.examples().map(\.path)
        let suffixes = [".hephaestus/project.yml", "/device.yml", "/registry.yml", "/settings.yml", "/remotes.yml",
                        "/plan-usage.yml", "/current-environments.yml", "/secrets.json", "/SKILL.md"]
        for suffix in suffixes {
            #expect(paths.contains { $0.hasSuffix(suffix) }, "no example for \(suffix)")
        }
        for folder in ["ticket", "bundle", "chats"] {
            #expect(paths.contains { $0.contains(".hephaestus/\(folder)/") && $0.hasSuffix(".yml") }, "no example for \(folder)")
        }
        #expect(paths.contains { $0.hasSuffix(".jsonl") })
    }

    @Test("Every example decodes, round-trips and keeps its keys", arguments: try DataModelExamplesTests.examples())
    func example(_ example: Example) throws {
        let path = example.path
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent

        if path.hasSuffix(".hephaestus/project.yml") {
            try checkYAML(Project.self, example)
        } else if path.contains(".hephaestus/ticket/"), path.hasSuffix(".yml") {
            let ticket = try checkYAML(Ticket.self, example)
            #expect(ticket.id == name)
        } else if path.contains(".hephaestus/bundle/"), path.hasSuffix(".yml") {
            let bundle = try checkYAML(TicketBundle.self, example)
            #expect(bundle.id == name)
        } else if path.contains(".hephaestus/chats/"), path.hasSuffix(".yml") {
            let meta = try checkYAML(ChatMeta.self, example)
            #expect(meta.id.uuidString == name)
        } else if path.contains(".hephaestus/chats/"), path.hasSuffix("/agents.jsonl") {
            try checkAgents(example)
        } else if path.contains(".hephaestus/chats/"), path.hasSuffix(".jsonl") {
            try checkTranscript(example)
        } else if path.hasSuffix("/device.yml") {
            try checkYAML(DeviceRecord.self, example)
        } else if path.hasSuffix("/registry.yml") {
            try checkYAML(Registry.self, example)
        } else if path.hasSuffix("/settings.yml") {
            try checkYAML(HostSettings.self, example)
        } else if path.hasSuffix("/remotes.yml") {
            try checkYAML(RemotesFile.self, example)
        } else if path.hasSuffix("/plan-usage.yml") {
            try checkYAML(PlanUsage.self, example)
        } else if path.hasSuffix("/current-environments.yml") {
            try checkYAML(CurrentEnvironments.self, example)
        } else if path.hasSuffix("/secrets.json") {
            try checkSecrets(example)
        } else if path.hasSuffix("/SKILL.md") {
            let frontmatter = try checkYAML(SkillFrontmatter.self, example)
            #expect(frontmatter.name == folder)
        } else {
            Issue.record("\(path): no type for this path")
        }
    }

    // MARK: - Checks

    @discardableResult
    private func checkYAML<T: Codable & Equatable>(_ type: T.Type, _ example: Example) throws -> T {
        let value = try YAMLCoding.decode(type, from: example.text)
        let encoded = try YAMLCoding.encode(value)
        let decodedAgain = try YAMLCoding.decode(type, from: encoded)
        #expect(decodedAgain == value, "\(example.path): the round trip changed the value")
        let exampleTree = YAMLCoding.jsonValue(of: try YAMLCoding.parseMapping(example.text))
        let encodedTree = YAMLCoding.jsonValue(of: try YAMLCoding.parseMapping(encoded))
        for missing in missingKeys(exampleTree, in: encodedTree, path: "") {
            Issue.record("\(example.path): the key \(missing) is missing from the encoded output")
        }
        return value
    }

    private func checkSecrets(_ example: Example) throws {
        let data = Data(example.text.utf8)
        let value = try StorageJSON.decodeObject(Secrets.self, from: data)
        #expect(!DeviceFileStore.generatedKeys(in: data))
        let encoded = try StorageJSON.fileEncoder().encode(value)
        let decodedAgain = try StorageJSON.decodeObject(Secrets.self, from: encoded)
        #expect(decodedAgain == value)
        let exampleTree = try JSONDecoder().decode(JSONValue.self, from: data)
        let encodedTree = try JSONDecoder().decode(JSONValue.self, from: encoded)
        for missing in missingKeys(exampleTree, in: encodedTree, path: "") {
            Issue.record("\(example.path): the key \(missing) is missing from the encoded output")
        }
    }

    private func checkTranscript(_ example: Example) throws {
        let data = Data(example.text.utf8)
        let replay = TranscriptReplay.replay(data)
        #expect(replay.skipped.isEmpty, "\(example.path): replay skipped \(replay.skipped)")
        let lines = JSONLines.lines(of: data)
        #expect(!lines.isEmpty)
        for (index, line) in lines.enumerated() {
            let value = try StorageJSON.decoder().decode(TranscriptLine.self, from: line)
            let encoded = try StorageJSON.lineEncoder().encode(value)
            #expect(!encoded.contains(0x0A))
            let decodedAgain = try StorageJSON.decoder().decode(TranscriptLine.self, from: encoded)
            #expect(decodedAgain == value, "line \(index + 1): the round trip changed the value")
            let exampleTree = try JSONDecoder().decode(JSONValue.self, from: line)
            let encodedTree = try JSONDecoder().decode(JSONValue.self, from: encoded)
            for missing in missingKeys(exampleTree, in: encodedTree, path: "") {
                Issue.record("\(example.path):\(index + 1): the key \(missing) is missing from the encoded output")
            }
        }
    }

    /// docs/data-model.md › Chat agents file: every line decodes, round-trips and keeps its keys,
    /// and replay skips none.
    private func checkAgents(_ example: Example) throws {
        let data = Data(example.text.utf8)
        let replay = ChatAgentsReplay.replay(data)
        #expect(replay.skipped.isEmpty, "\(example.path): replay skipped \(replay.skipped)")
        let lines = JSONLines.lines(of: data)
        #expect(!lines.isEmpty)
        for (index, line) in lines.enumerated() {
            let value = try StorageJSON.decoder().decode(ChatAgentsLine.self, from: line)
            let encoded = try StorageJSON.lineEncoder().encode(value)
            #expect(!encoded.contains(0x0A))
            let decodedAgain = try StorageJSON.decoder().decode(ChatAgentsLine.self, from: encoded)
            #expect(decodedAgain == value, "line \(index + 1): the round trip changed the value")
            let exampleTree = try JSONDecoder().decode(JSONValue.self, from: line)
            let encodedTree = try JSONDecoder().decode(JSONValue.self, from: encoded)
            for missing in missingKeys(exampleTree, in: encodedTree, path: "") {
                Issue.record("\(example.path):\(index + 1): the key \(missing) is missing from the encoded output")
            }
        }
    }

    /// The key paths of `example` that `encoded` lacks; sequences are compared element by element.
    private func missingKeys(_ example: JSONValue, in encoded: JSONValue, path: String) -> [String] {
        switch (example, encoded) {
        case let (.object(exampleObject), .object(encodedObject)):
            return exampleObject.keys.sorted().flatMap { key -> [String] in
                guard let value = encodedObject[key] else { return [path + "/" + key] }
                return missingKeys(exampleObject[key]!, in: value, path: path + "/" + key)
            }
        case let (.array(exampleArray), .array(encodedArray)):
            return exampleArray.enumerated().flatMap { index, element -> [String] in
                guard index < encodedArray.count else { return ["\(path)[\(index)]"] }
                return missingKeys(element, in: encodedArray[index], path: "\(path)[\(index)]")
            }
        default:
            return []
        }
    }
}
