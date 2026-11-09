import Foundation
import Testing
@testable import HephaestusCore

/// Docs conformance test 2 (docs/ci.md › Docs conformance tests, docs/engine-api.md ›
/// Conformance): every table row of docs/engine-api.md whose first cell is one backticked name of
/// the form `<area>.<verb>` against `Engine.registeredMethods`.
@Suite("Engine methods")
struct EngineMethodsConformanceTests {
    /// A first cell that is one backticked `<area>.<verb>` name.
    static func methodName(inFirstCell cell: String) -> String? {
        guard cell.count > 2, cell.hasPrefix("`"), cell.hasSuffix("`") else { return nil }
        let name = String(cell.dropFirst().dropLast())
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter } }) else { return nil }
        return name
    }

    /// The rows of docs/engine-api.md whose first cell is a backticked method name.
    static func methodRows() throws -> [(name: String, cells: [String])] {
        try MarkdownTable.tables(in: Repository.doc("engine-api.md")).flatMap(\.rows).compactMap { cells in
            guard let first = cells.first, let name = methodName(inFirstCell: first) else { return nil }
            return (name, cells)
        }
    }

    @Test("The documented method names equal Engine.registeredMethods")
    func registeredMethods() async throws {
        let documented = Set(try Self.methodRows().map(\.name))
        #expect(documented.count == 127)
        try await withTestEngine { engine, _, _ in
            #expect(Set(await engine.registeredMethods) == documented)
        }
    }

    // MARK: Beyond test 2: the other columns of docs/engine-api.md › Method index

    @Test("Each method type has the wire name and Swift type name of the Method index")
    func swiftTypes() throws {
        let rows = try Self.methodRows()
        let documented = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.cells[1]) })
        #expect(EngineMethods.all.count == rows.count)
        #expect(Set(EngineMethods.all.map { $0.name }).count == EngineMethods.all.count)
        for method in EngineMethods.all {
            #expect(documented[method.name] == String(describing: method), "Swift type of \(method.name)")
        }
    }

    @Test("Each method is registered with the actors of the Method index")
    func actors() async throws {
        let rows = try Self.methodRows()
        try await withTestEngine { engine, _, _ in
            for row in rows {
                let documented = Set(row.cells[4].split(separator: ",").compactMap {
                    ActorKind(rawValue: $0.trimmingCharacters(in: .whitespaces))
                })
                #expect(await engine.registeredActors(for: row.name) == documented, "actors of \(row.name)")
            }
        }
    }

    @Test("Claude may call exactly the 61 methods that MCP tools map to")
    func claudeMethodsAreTheToolMethods() async throws {
        try await withTestEngine { engine, _, _ in
            var claudeMethods: Set<String> = []
            for method in await engine.registeredMethods {
                if await engine.registeredActors(for: method)?.contains(.claude) == true {
                    claudeMethods.insert(method)
                }
            }
            let toolMethods = Set(MCPToolCatalog.tools.compactMap(\.engineMethod))
            #expect(claudeMethods.count == 61)
            #expect(claudeMethods == toolMethods)
        }
    }

    @Test("The event types have the names and Swift types of the Event list")
    func events() throws {
        let table = try #require(MarkdownTable.tables(in: Repository.doc("engine-api.md")).first {
            $0.header.first == "Event" && $0.header.count > 1 && $0.header[1] == "Swift type"
        })
        let documented = table.rows.map { ($0[0], $0[1]) }
        #expect(documented.count == 22)
        #expect(EngineEvents.all.map { $0.name } == documented.map(\.0))
        #expect(EngineEvents.all.map { String(describing: $0) } == documented.map(\.1))
    }
}
