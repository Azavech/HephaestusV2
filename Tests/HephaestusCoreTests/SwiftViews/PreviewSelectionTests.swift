import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › previews.select and previews.edit: selecting an element in a running
/// preview of a SwiftUI and an AppKit view, outlining it, and rewriting its code, which builds the
/// previews again.
@Suite("Visual inspector methods")
struct PreviewSelectionTests {
    static let badge = """
    import AppKit

    final class Badge: NSView {
        let label = NSTextField(labelWithString: "Old")

        override init(frame: NSRect) {
            super.init(frame: frame)
            label.frame = NSRect(x: 10, y: 10, width: 120, height: 24)
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError() }
    }

    #Preview {
        Badge(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    }

    """

    @Test("A SwiftUI element is selected in its preview, outlined, and its colour rewritten",
          .enabled(if: PreviewMethodsTests.runsBuilds, "Set PREVIEW_BUILD_TESTS=1 to build previews"), .timeLimit(.minutes(10)))
    func swiftUI() async throws {
        try await withTestEngine { engine, connection, folder in
            await engine.useLoginEnvironment(ProcessInfo.processInfo.environment)
            let root = try await PreviewMethodsTests.makeProject(connection, in: folder)
            let file = root.appendingPathComponent("Sources/Demo/Greeting.swift")
            let session = try await connection.call(PreviewsStart.self, .init(projectID: "DEMO", path: "Sources/Demo/Greeting.swift",
                                                                               name: "Greeting", settings: PreviewSettings(width: 200, height: 100)))
            let id = session.sessionID
            #expect(await engineError { try await connection.call(PreviewsEdit.self, .init(sessionID: id, edit: ViewElementEdit(property: .text, text: "x"))) }
                == EngineError(.invalid, "No element is selected."))
            #expect(await engineError { try await connection.call(PreviewsSelect.self, .init(sessionID: id, preview: 2, x: 1, y: 1)) }
                == EngineError(.invalid, "preview: use 0 to 1."))
            #expect(await engineError { try await connection.call(PreviewsSelect.self, .init(sessionID: id, preview: 0, y: 1)) }
                == EngineError(.invalid, "x: required with preview."))
            var after = 0
            _ = try await PreviewMethodsTests.poll(connection, id, after: &after) { status, sizes in
                status.state == .running && sizes.count == 2
            }

            // The text in the middle of the first preview.
            let selection = try await connection.call(PreviewsSelect.self, .init(sessionID: id, preview: 0, x: 100, y: 50))
            let element = try #require(selection.element)
            #expect(element.type == "Text" && element.kind == .swiftUI && element.path == "Sources/Demo/Greeting.swift" && element.line == 6)
            #expect(element.text == ViewElementText(code: "text"))
            let outlined = try await PreviewMethodsTests.poll(connection, id, after: &after) { status, _ in
                !status.previews[0].outlines.isEmpty
            }
            #expect(outlined.element == element)
            let outline = try #require(outlined.previews[0].outlines.first)
            #expect(outline.x < 100 && outline.x + outline.width > 100 && outline.y < 50 && outline.y + outline.height > 50)

            // A place without an element clears the selection.
            #expect(try await connection.call(PreviewsSelect.self, .init(sessionID: id, preview: 0, x: 2, y: 2)).element == nil)
            _ = try await connection.call(PreviewsSelect.self, .init(sessionID: id, preview: 0, x: 100, y: 50))

            let edited = try await connection.call(PreviewsEdit.self, .init(sessionID: id, edit: ViewElementEdit(
                property: .color, color: ViewElementColorValue(red: 1, green: 0, blue: 0))))
            #expect(edited.color == ViewElementColor(code: "Color(red: 1, green: 0, blue: 0)", red: 1, green: 0, blue: 0, opacity: 1))
            #expect(try String(contentsOf: file, encoding: .utf8).contains("Text(text).padding().foregroundStyle(Color(red: 1, green: 0, blue: 0))"))

            // The save builds the previews again; the selection and its outlines follow.
            let builtAt = outlined.builtAt
            await engine.previewFilesChanged(rootPath: root.standardizedFileURL.path, paths: ["Sources/Demo/Greeting.swift"])
            let rebuilt = try await PreviewMethodsTests.poll(connection, id, after: &after) { status, _ in
                status.state == .running && status.builtAt != builtAt && !status.previews[0].outlines.isEmpty
            }
            #expect(rebuilt.element?.color?.red == 1)
            _ = try await connection.call(PreviewsStop.self, .init(sessionID: id))
        }
    }

    @Test("An AppKit element is selected in its preview and its text rewritten",
          .enabled(if: PreviewMethodsTests.runsBuilds, "Set PREVIEW_BUILD_TESTS=1 to build previews"), .timeLimit(.minutes(10)))
    func appKit() async throws {
        try await withTestEngine { engine, connection, folder in
            await engine.useLoginEnvironment(ProcessInfo.processInfo.environment)
            let root = try await PreviewMethodsTests.makeProject(connection, in: folder)
            let file = root.appendingPathComponent("Sources/Demo/Badge.swift")
            try Self.badge.write(to: file, atomically: true, encoding: .utf8)
            let session = try await connection.call(PreviewsStart.self, .init(projectID: "DEMO", path: "Sources/Demo/Badge.swift",
                                                                               name: "Badge", settings: PreviewSettings(width: 200, height: 100)))
            let id = session.sessionID
            var after = 0
            let running = try await PreviewMethodsTests.poll(connection, id, after: &after) { status, sizes in
                (status.state == .running && sizes.count == 1) || status.state == .buildFailed
            }
            #expect(running.state == .running, "\(running.messages)")
            // The label is at 10, 10 from the bottom left: 66 to 90 points from the top.
            let selection = try await connection.call(PreviewsSelect.self, .init(sessionID: id, preview: 0, x: 30, y: 78))
            let element = try #require(selection.element)
            #expect(element.type == "NSTextField" && element.kind == .appKit && element.variable == "label")
            #expect(element.text == ViewElementText(code: "\"Old\"", value: "Old"))
            let edited = try await connection.call(PreviewsEdit.self, .init(sessionID: id, edit: ViewElementEdit(property: .text, text: "New")))
            #expect(edited.text?.value == "New")
            #expect(try String(contentsOf: file, encoding: .utf8).contains("let label = NSTextField(labelWithString: \"New\")"))
            await engine.previewFilesChanged(rootPath: root.standardizedFileURL.path, paths: ["Sources/Demo/Badge.swift"])
            let rebuilt = try await PreviewMethodsTests.poll(connection, id, after: &after) { status, _ in
                (status.state == .running && status.builtAt != running.builtAt) || status.state == .buildFailed
            }
            #expect(rebuilt.state == .running, "\(rebuilt.messages)")
            #expect(rebuilt.element?.text?.value == "New")
            _ = try await connection.call(PreviewsStop.self, .init(sessionID: id))
        }
    }
}
