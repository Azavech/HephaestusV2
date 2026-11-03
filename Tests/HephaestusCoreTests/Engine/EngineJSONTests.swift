import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › JSON encoding and the JSON examples of › API types.
@Suite("Engine JSON")
struct EngineJSONTests {
    static func encoded<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try EngineJSON.encode(value), as: UTF8.self)
    }

    @Test("Dates: whole seconds without a fraction, milliseconds otherwise; both forms and offsets decode")
    func dates() throws {
        let whole = try #require(ISODate.apiDate(from: "2026-10-31T14:03:00Z"))
        let fraction = try #require(ISODate.apiDate(from: "2026-10-31T14:03:07.412Z"))
        #expect(try Self.encoded([whole, fraction]) == #"["2026-10-31T14:03:00Z","2026-10-31T14:03:07.412Z"]"#)
        #expect(ISODate.apiDate(from: "2026-10-31T16:03:00+02:00") == whole)
        #expect(ISODate.apiDate(from: "2026-10-31T14:03:07.4Z").map(ISODate.millisecondString(from:)) == "2026-10-31T14:03:07.400Z")
        #expect(ISODate.date(from: "2026-10-31T14:03:07.412Z") == fraction.truncatedToSeconds)
        let decoded = try EngineJSON.decode([Date].self, from: Data(#"["2026-10-31T14:03:07.412Z"]"#.utf8))
        #expect(decoded == [fraction])
    }

    @Test("Keys are sorted, slashes are not escaped and absent optional values are omitted")
    func encoding() throws {
        let entry = BrowseResult.Entry(name: "HephaestusV2", path: "/Users/example/Developer/HephaestusV2", hasProject: true)
        #expect(try Self.encoded(entry) == #"{"hasProject":true,"name":"HephaestusV2","path":"/Users/example/Developer/HephaestusV2"}"#)
        #expect(try Self.encoded(BrowseResult(path: "/")) == #"{"entries":[],"hasGoMod":false,"path":"/"}"#)
        #expect(try Self.encoded(BrowseResult(path: "/Users/example/api", hasGoMod: true)) == #"{"entries":[],"hasGoMod":true,"path":"/Users/example/api"}"#)
        #expect(try Self.encoded(Empty()) == "{}")
    }

    @Test("BrowseResult: hasGoMod absent, from an engine of an earlier version, reads as false")
    func browseResultWithoutGoMod() throws {
        let result = try EngineJSON.decode(BrowseResult.self, from: Data(#"{"entries":[],"path":"/"}"#.utf8))
        #expect(result == BrowseResult(path: "/"))
    }

    @Test("Patch: absent keeps, null clears, a value replaces")
    func patch() throws {
        let params = SettingsUpdate.Params(claudePath: .clear, mcpPort: 47830)
        #expect(try Self.encoded(params) == #"{"claudePath":null,"mcpPort":47830}"#)
        func decode(_ json: String) throws -> SettingsUpdate.Params {
            try EngineJSON.decode(SettingsUpdate.Params.self, from: Data(json.utf8))
        }
        #expect(try decode("{}").claudePath == .keep)
        #expect(try decode(#"{"claudePath": null}"#).claudePath == .clear)
        #expect(try decode(#"{"claudePath": "/usr/local/bin/claude"}"#).claudePath == .set("/usr/local/bin/claude"))
        #expect(try decode(#"{"mcpPort": null}"#).mcpPort == nil)
    }

    @Test("Empty decodes from any object and from nothing else")
    func empty() throws {
        #expect(throws: Never.self) { try EngineJSON.decode(Empty.self, from: Data(#"{"a": 1}"#.utf8)) }
        #expect(throws: DecodingError.self) { try EngineJSON.decode(Empty.self, from: Data("[]".utf8)) }
    }

    /// The type of each JSON example of docs/engine-api.md › API types, by heading.
    static let decoders: [String: (Data) throws -> Data] = [
        "### Actor": roundTrip([Actor].self),
        "### EngineError": roundTrip(EngineError.self),
        "### Patch": roundTrip(SettingsUpdate.Params.self),
        "### Snapshot": roundTrip(Snapshot.self),
        "### RunResult": roundTrip(RunResult.self),
        "### FileEntry": roundTrip(FileEntry.self),
        "### FileContent": roundTrip(FileContent.self),
        "### BrowseResult": roundTrip(BrowseResult.self),
        "### SearchResult": roundTrip([SearchResult].self),
        "### NavigationTarget": roundTrip([NavigationTarget].self),
        "### AttachmentUpload": roundTrip([AttachmentUpload].self),
        "### BinaryContent": roundTrip(BinaryContent.self),
        "### ChatMessageInput": roundTrip(ChatMessageInput.self),
        "### QuestionSet": roundTrip(QuestionSet.self),
        "### SymbolRequest": roundTrip(SymbolRequest.self),
        "### FeedbackContext": roundTrip(FeedbackContext.self),
        "### ClaudeModel": roundTrip(ClaudeModel.self),
        "### ClaudeStatus": roundTrip([ClaudeStatus].self),
        "### PlanUsageState": roundTrip([PlanUsageState].self),
        "### Skill": roundTrip(Skill.self),
        "### EngineEventEnvelope": roundTrip(EngineEventEnvelope.self),
    ]

    static func roundTrip<T: Codable>(_ type: T.Type) -> (Data) throws -> Data {
        { data in try EngineJSON.encode(try EngineJSON.decode(T.self, from: data)) }
    }

    @Test("Every JSON example of the API types decodes and encodes back to the same JSON")
    func apiTypeExamples() throws {
        let text = try Repository.doc("engine-api.md")
        let start = try #require(text.range(of: "\n## API types\n"))
        let end = try #require(text.range(of: "\n## Swift shape\n"))
        let blocks = MarkdownSource.fencedBlocks(in: String(text[start.lowerBound..<end.lowerBound])).filter { $0.info == "json" }
        var checked: Set<String> = []
        for block in blocks {
            let heading = try #require(block.heading)
            let roundTrip = try #require(Self.decoders[heading], "no Swift type for the example under \(heading)")
            let encoded = try roundTrip(Data(block.text.utf8))
            #expect(try jsonValue(String(decoding: encoded, as: UTF8.self)) == (try jsonValue(block.text)), "example under \(heading)")
            checked.insert(heading)
        }
        #expect(checked == Set(Self.decoders.keys))
    }

    @Test("An envelope's payload decodes only as its own event")
    func envelopePayload() throws {
        let envelope = EngineEventEnvelope(name: TicketDeletedEvent.name, origin: .system,
                                           data: ["projectID": "HEPH", "ticketID": "HEPH-12"])
        #expect(try envelope.payload(TicketDeletedEvent.self) == .init(projectID: "HEPH", ticketID: "HEPH-12"))
        #expect(try envelope.decoded() == .ticketDeleted(.init(projectID: "HEPH", ticketID: "HEPH-12")))
        #expect(throws: EngineError(.invalid, "Event ticket.deleted is not bundle.deleted.")) {
            try envelope.payload(BundleDeletedEvent.self)
        }
        let unknown = EngineEventEnvelope(name: "future.event", origin: .system, data: [:])
        #expect(try unknown.decoded() == .unknown(name: "future.event"))
    }
}
