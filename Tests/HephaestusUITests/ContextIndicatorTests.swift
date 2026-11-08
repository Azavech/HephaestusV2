import AppKit
import HephaestusCore
import SwiftUI
import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/chats.md › Context indicator: `<n>% left`, the colour thresholds at 20 and 10, the
/// tooltip, and the controls row that keeps the ring and drops the text once its menus fold.
@MainActor
@Suite("Context indicator")
struct ContextIndicatorTests {
    static let received = Date(timeIntervalSince1970: 1_800_000_000)

    /// A usage with `left` tokens left of the 967,000 before compaction.
    static func usage(left: Int) -> ContextUsage {
        ContextUsage(usedTokens: 967_000 - left, windowTokens: 1_000_000, bufferTokens: 33000, received: received)
    }

    @Test("Green from 20% left, orange under 20%, red under 10%, after rounding")
    func levels() throws {
        let cases: [(left: Int, percent: Int, level: ContextIndicatorPresentation.Level)] = [
            (967_000, 100, .normal),
            (193_400, 20, .normal),
            (189_532, 20, .normal),  // 19.6% rounds to 20
            (183_730, 19, .warning),
            (145_050, 15, .warning),
            (96700, 10, .warning),
            (90898, 9, .critical),  // 9.4% rounds to 9
            (48350, 5, .critical),
            (0, 0, .critical),
        ]
        for item in cases {
            let presentation = try #require(ContextIndicatorPresentation(usage: Self.usage(left: item.left)))
            #expect(presentation.percentLeft == item.percent, "\(item.left)")
            #expect(presentation.level == item.level, "\(item.left)")
            #expect(presentation.text == "\(item.percent)% left")
        }
        #expect(ContextIndicatorPresentation(usage: Self.usage(left: 145_050))?.color == .orange)
        #expect(ContextIndicatorPresentation(usage: Self.usage(left: 48350))?.color == .red)
        #expect(ContextIndicatorPresentation(usage: Self.usage(left: 948_446))?.color == .green)
    }

    @Test("The ring is filled to the used part of window − buffer; the tooltip gives the numbers")
    func ringAndTooltip() throws {
        let presentation = try #require(ContextIndicatorPresentation(usage: Self.usage(left: 948_446)))
        #expect(abs(presentation.fraction - 18554.0 / 967_000.0) < 1e-9)
        #expect(presentation.text == "98% left")
        #expect(presentation.tooltip == "18.6K of 1M tokens used · 948.4K left before compaction")
        let full = ContextUsage(usedTokens: 2_000_000, windowTokens: 1_000_000, bufferTokens: 33000, received: Self.received)
        #expect(ContextIndicatorPresentation(usage: full)?.fraction == 1)
        // A buffer that is not below the window shows no indicator.
        let broken = ContextUsage(usedTokens: 1, windowTokens: 1000, bufferTokens: 1000, received: Self.received)
        #expect(ContextIndicatorPresentation(usage: broken) == nil)
    }

    /// Records the preference of the shown controls row.
    final class Shown {
        var value: Bool?
    }

    /// Lays out the composer of a chat with a context usage, `width` points wide, in a window,
    /// and returns whether its context indicator shows `<n>% left` (nil: no indicator).
    func textShown(width: CGFloat, usage: ContextUsage?, app: AppModel) -> Bool? {
        let meta = ChatMeta(id: UUID(), kind: .project, created: Self.received, contextUsage: usage, projectID: "DEMO")
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.chats[meta.id.uuidString] = meta
        let model = ChatViewModel(workspace: workspace, chatID: meta.id.uuidString, draft: nil)
        let shown = Shown()
        let host = NSHostingView(rootView: ComposerView(model: model)
            .environment(app)
            .frame(width: width)
            .onPreferenceChange(ContextIndicatorTextShown.self) { shown.value = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.close()
        return shown.value
    }

    @Test("A wide controls row shows the ring and <n>% left; a narrow one, whose menus fold, keeps only the ring")
    func narrowRow() async throws {
        try await withAppModel { app in
            #expect(textShown(width: 900, usage: Self.usage(left: 948_446), app: app) == true)
            #expect(textShown(width: 260, usage: Self.usage(left: 948_446), app: app) == false)
            #expect(textShown(width: 900, usage: nil, app: app) == nil)
        }
    }
}

/// Runs `check` with an app model over a test engine in a temporary folder; the composer's CLI
/// banner reads it.
@MainActor
private func withAppModel(_ check: (AppModel) async throws -> Void) async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HephaestusUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = folder.appendingPathComponent("Data", isDirectory: true)
    let engine = try await Engine(configuration: .test(dataDirectory: data, claudeLauncher: SilentClaudeLauncher()))
    let connection = await LocalEngineConnection(engine: engine)
    let app = AppModel(environment: LaunchEnvironment(dataDirectory: data), engine: engine,
                       appVersion: AppVersion(version: "0.0.0", build: 0), connection: connection, restartWindows: nil)
    do {
        try await check(app)
    } catch {
        connection.close()
        await engine.shutdown()
        throw error
    }
    connection.close()
    await engine.shutdown()
}

/// A launcher that starts nothing: no Claude process runs.
private struct SilentClaudeLauncher: ClaudeProcessLauncher {}
