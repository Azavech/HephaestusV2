import Foundation
import Testing
@testable import HephaestusCore

/// docs/views.md › List of views and › Preview blocks: the Swift files read, what a view is, the
/// preview blocks and the code that the builds generate from them.
@Suite("Views of a project")
struct ViewFinderTests {
    static let swiftUI = """
    import SwiftUI

    struct ContentView: View {
        var body: some View { Text("struct NotAView: View {}") }
    }

    public struct Card<Content: View>: SwiftUI.View where Content: Equatable {
        var body: some View { EmptyView() }
    }

    struct MapRepresentable: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    struct PhoneRepresentable: UIViewRepresentable {}

    struct Rounded: Shape {
        func path(in rect: CGRect) -> Path { Path(rect) }
    }

    struct Model: Equatable {
        var name: String
    }

    struct Bold: ViewModifier {
        func body(content: Content) -> some View { content.bold() }
    }

    protocol CardView: View {}
    struct Fancy: CardView {
        var body: some View { EmptyView() }
    }

    struct Later {}
    extension Later: View {
        var body: some View { EmptyView() }
    }

    enum Settings {
        struct Row: View {
            var body: some View { EmptyView() }
        }
    }

    func helper() {
        struct Local: View {
            var body: some View { EmptyView() }
        }
    }

    // struct Commented: View {}
    /* struct Blocked: View { } */
    let text = #"struct Raw: View {}"#
    let multi = \"\"\"
    struct Multi: View {}
    \"\"\"

    #Preview("First") {
        ContentView()
    }

    #Preview {
        @Previewable @State var on = true
        Toggle("On", isOn: $on)
        Settings.Row()
    }

    #Preview(as: .systemSmall) {
        ContentView()
    } timeline: {
        Entry()
    }
    """

    static let appKit = """
    import AppKit

    final class Canvas: NSView {}
    class Fancy2: Canvas {}
    class Button2: NSButton {}
    class Web: WKWebView {}
    class Holder: NSViewController {}
    class Cell: NSTextFieldCell {}
    class Delegate: NSObject, NSTableViewDelegate {}

    #Preview {
        Canvas()
    }
    """

    static let uiKit = """
    import UIKit

    class PhoneView: UIView {}
    class PhoneCell: UITableViewCell {}
    class Map: MKMapView {}
    """

    /// A project folder with the three files, a sub project's view, and views inside skipped
    /// folders and comments that are not listed.
    static func project(_ folder: URL) throws -> URL {
        let root = folder.appendingPathComponent("Project")
        let files = [
            "Sources/App/ContentView.swift": swiftUI,
            "Sources/App/AppKit/Canvas.swift": appKit,
            "Sources/Phone/PhoneView.swift": uiKit,
            "Packages/Kit/Sources/Kit/KitView.swift": "import SwiftUI\nstruct KitView: View { var body: some View { EmptyView() } }\n",
            ".build/checkouts/Dep/Dep.swift": "import SwiftUI\nstruct Hidden: View { var body: some View { EmptyView() } }\n",
            "DerivedData/X.swift": "import SwiftUI\nstruct Derived: View { var body: some View { EmptyView() } }\n",
            "Notes.md": "struct Markdown: View {}",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    static func views(_ root: URL) -> [ProjectView] {
        let files = ViewFinder.swiftFiles(under: root).compactMap { file in
            ViewFinder.scanFile(at: file.url).map { ScannedSwiftFile(path: file.path, url: file.url, scan: $0) }
        }
        return ViewFinder.views(in: files)
    }

    @Test("SwiftUI views, representables, NSView and UIView subclasses and a sub project's view are listed; nothing else is")
    func listsExactlyTheViews() throws {
        try withTemporaryDirectory { folder in
            let views = Self.views(try Self.project(folder))
            let listed = Set(views.map { "\($0.path):\($0.name):\($0.kind.rawValue)" })
            #expect(listed == [
                "Sources/App/ContentView.swift:ContentView:swiftUI",
                "Sources/App/ContentView.swift:Card:swiftUI",
                "Sources/App/ContentView.swift:MapRepresentable:swiftUI",
                "Sources/App/ContentView.swift:PhoneRepresentable:swiftUI",
                "Sources/App/ContentView.swift:Rounded:swiftUI",
                "Sources/App/ContentView.swift:Fancy:swiftUI",
                "Sources/App/ContentView.swift:Later:swiftUI",
                "Sources/App/ContentView.swift:Settings.Row:swiftUI",
                "Sources/App/AppKit/Canvas.swift:Canvas:appKit",
                "Sources/App/AppKit/Canvas.swift:Fancy2:appKit",
                "Sources/App/AppKit/Canvas.swift:Button2:appKit",
                "Sources/App/AppKit/Canvas.swift:Web:appKit",
                "Sources/Phone/PhoneView.swift:PhoneView:uiKit",
                "Sources/Phone/PhoneView.swift:PhoneCell:uiKit",
                "Sources/Phone/PhoneView.swift:Map:uiKit",
                "Packages/Kit/Sources/Kit/KitView.swift:KitView:swiftUI",
            ])
            // Sorted by path, then line.
            #expect(views == views.sorted { ($0.path, $0.line) < ($1.path, $1.line) })
            #expect(views.first { $0.name == "ContentView" }?.line == 3)
        }
    }

    @Test("A block belongs to the views it names, or to every view of its file; a widget preview is no block")
    func previewBlocks() throws {
        try withTemporaryDirectory { folder in
            let views = Self.views(try Self.project(folder))
            let content = try #require(views.first { $0.name == "ContentView" })
            #expect(content.previews.map(\.name) == ["First"])
            let row = try #require(views.first { $0.name == "Settings.Row" })
            #expect(row.previews.map(\.name) == [nil])
            #expect(views.first { $0.name == "Rounded" }?.previews.isEmpty == true)
            // `Canvas()` names Canvas only.
            #expect(views.first { $0.name == "Canvas" }?.previews.count == 1)
            #expect(views.first { $0.name == "Web" }?.previews.isEmpty == true)
            let unnamed = SwiftSourceScanner.scan("import SwiftUI\nstruct A: View {}\nstruct B: View {}\n#Preview { Text(\"x\") }\n")
            let both = ViewFinder.views(in: [ScannedSwiftFile(path: "A.swift", url: URL(fileURLWithPath: "/A.swift"), scan: unnamed)])
            #expect(both.map(\.previews.count) == [1, 1])
        }
    }

    @Test("The scan finds the @Previewable statements, the @main attributes, the imports and the #if conditions")
    func scanDetails() throws {
        let text = """
        import SwiftUI
        @testable import Kit

        @main
        struct App: SwiftUI.App { var body: some Scene { WindowGroup { Text("@main") } } }

        #if os(macOS)
        #Preview("Mac") { Text("mac") }
        #elseif DEBUG
        #Preview { Text("debug") }
        #else
        #Preview { Text("other") }
        #endif
        """
        let scan = SwiftSourceScanner.scan(text)
        #expect(scan.importedModules == ["SwiftUI", "Kit"])
        #expect(scan.importStatements == ["import SwiftUI", "@testable import Kit"])
        #expect(scan.mainAttributes.count == 1)
        #expect(scan.previews.map(\.conditions) == [["(os(macOS))"], ["!(os(macOS)) && (DEBUG)"], ["!(os(macOS)) && !(DEBUG)"]])
        #expect(scan.previews.map(\.name) == ["Mac", nil, nil])

        let previewable = SwiftSourceScanner.scan(Self.swiftUI).previews[1]
        let bytes = Array(Self.swiftUI.utf8)
        #expect(previewable.previewables.map { String(decoding: bytes[$0.range], as: UTF8.self) } == ["@Previewable @State var on = true"])
    }

    @Test("The generated code keeps each body with its lines and columns, maps them to the file, and turns @Previewable into state")
    func generatedCode() throws {
        let scan = SwiftSourceScanner.scan(Self.swiftUI)
        let generated = PreviewHostSource.previewFunctions(file: 3, scan: scan, text: Self.swiftUI, path: "/Users/example/App/ContentView.swift")
        #expect(generated.entries.map(\.key) == ["/Users/example/App/ContentView.swift#0", "/Users/example/App/ContentView.swift#1"])
        #expect(generated.entries.map(\.function) == ["__hephaestusPreview_3_0", "__hephaestusPreview_3_1"])
        // The body keeps its columns: the text after `#Preview("First") {` starts at column 19.
        #expect(generated.code.contains("\n" + String(repeating: " ", count: 19) + "\n    ContentView()\n"))
        #expect(generated.code.contains("struct __HephaestusPreviewBody: SwiftUI.View {"))
        #expect(generated.code.contains("                 @State var on = true"))
        #expect(!generated.code.contains("@Previewable"))
        // Each line of a body maps to its line in the file.
        let codeLines = generated.code.components(separatedBy: "\n")
        let map = PreviewSourceMap(path: "/Users/example/App/ContentView.swift", segments: generated.segments)
        let fileLines = Self.swiftUI.components(separatedBy: "\n")
        let contentLine = try #require(codeLines.firstIndex(of: "    ContentView()")) + 1
        #expect(fileLines[try #require(map.originalLine(contentLine)) - 1] == "    ContentView()")
        let stateLine = try #require(codeLines.firstIndex { $0.contains("@State var on = true") }) + 1
        #expect(fileLines[try #require(map.originalLine(stateLine)) - 1].contains("@Previewable @State var on = true"))
        #expect(map.originalLine(1) == nil)
        let host = PreviewHostSource.hostFile(entries: generated.entries)
        #expect(host.contains("\"/Users/example/App/ContentView.swift#1\": __hephaestusPreview_3_1,"))
        #expect(host.contains("@main\nfileprivate enum __HephaestusPreviewHostMain"))
    }

    @Test("The compiler's errors, in both forms, name the project's file and line; other lines are no errors")
    func compilerErrors() {
        let map = PreviewSourceMap(path: "/Users/example/App/A.swift", segments: [.init(line: 1, original: 1, count: 10), .init(line: 20, original: 5, count: 3)])
        let maps = ["/var/build/A.swift": map]
        #expect(PreviewBuildOutput.error("/private/var/build/A.swift:21:4: error: cannot find 'x' in scope", maps: maps)
            == "/Users/example/App/A.swift:6:4: error: cannot find 'x' in scope")
        #expect(PreviewBuildOutput.error("error: /var/build/A.swift:3:1 extraneous '}' at top level: FixIt(sourceRange: …)", maps: maps)
            == "/Users/example/App/A.swift:3:1: error: extraneous '}' at top level")
        #expect(PreviewBuildOutput.error("/Users/example/Other Folder/B.swift:7:2: error: expected '}'")
            == "/Users/example/Other Folder/B.swift:7:2: error: expected '}'")
        #expect(PreviewBuildOutput.error("error: Build failed") == nil)
        #expect(PreviewBuildOutput.error("[12/345] Compiling Demo A.swift") == nil)
        #expect(PreviewBuildOutput.progress(of: "[12/345] Compiling Demo A.swift") == "12/345")
        #expect(PreviewBuildOutput.plain("\u{1B}[1;31merror\u{1B}[0m: x  ") == "error: x")
    }

    @Test("The package or Xcode project of a file is the nearest folder with Package.swift or an .xcodeproj, up to the root")
    func buildUnit() throws {
        try withTemporaryDirectory { folder in
            let root = folder.appendingPathComponent("Root")
            let manager = FileManager.default
            try manager.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
            try manager.createDirectory(at: root.appendingPathComponent("Packages/Kit/Sources/Kit"), withIntermediateDirectories: true)
            try "// swift-tools-version: 6.0".write(to: root.appendingPathComponent("Packages/Kit/Package.swift"), atomically: true, encoding: .utf8)
            let kit = PreviewBuildUnit.of(file: root.appendingPathComponent("Packages/Kit/Sources/Kit/A.swift"), root: root)
            #expect(kit?.folder.lastPathComponent == "Kit" && kit?.kind == .package)
            let app = PreviewBuildUnit.of(file: root.appendingPathComponent("App/ContentView.swift"), root: root)
            #expect(app?.kind == .xcodeProject(root.appendingPathComponent("App.xcodeproj").standardizedFileURL))
            #expect(PreviewBuildUnit.of(file: folder.appendingPathComponent("Other/A.swift"), root: folder.appendingPathComponent("Other")) == nil)
        }
    }

    @Test("The target of a package file comes from swift package describe")
    func packageTarget() throws {
        let describe = Data("""
        {"targets": [
          {"name": "AppTests", "path": "Tests/AppTests", "sources": ["A.swift"], "type": "test", "module_type": "SwiftTarget"},
          {"name": "App", "path": "Sources/App", "sources": ["A.swift", "Rows/Row.swift"], "type": "executable", "module_type": "SwiftTarget"},
          {"name": "CLib", "path": "Sources/CLib", "sources": ["c.c"], "type": "library", "module_type": "ClangTarget"}
        ]}
        """.utf8)
        let targets = try #require(PackageTarget.decode(describe: describe))
        #expect(PackageTarget.target(of: "Sources/App/Rows/Row.swift", in: targets)?.name == "App")
        #expect(PackageTarget.target(of: "Tests/AppTests/A.swift", in: targets)?.name == "AppTests")
        #expect(PackageTarget.target(of: "Sources/CLib/c.c", in: targets) == nil)
        #expect(PackageTarget.target(of: "Sources/Other/B.swift", in: targets) == nil)
    }

    @Test("The target of an Xcode file: its Sources build phase or a folder it synchronizes without the folder's exceptions")
    func xcodeTarget() throws {
        try withTemporaryDirectory { folder in
            let project = folder.appendingPathComponent("App.xcodeproj")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let pbxproj = """
            // !$*UTF8*$!
            {
                archiveVersion = 1;
                objectVersion = 77;
                objects = {
                    P1 = {isa = PBXProject; mainGroup = G1; targets = (T1, T2); projectDirPath = ""; };
                    G1 = {isa = PBXGroup; children = (S1, G2); sourceTree = "<group>"; };
                    S1 = {isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; exceptions = (E1); };
                    E1 = {isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Excluded, "Other.swift"); target = T1; };
                    G2 = {isa = PBXGroup; children = (F1); path = Legacy; sourceTree = "<group>"; };
                    F1 = {isa = PBXFileReference; path = Old.swift; sourceTree = "<group>"; };
                    B1 = {isa = PBXBuildFile; fileRef = F1; };
                    SP = {isa = PBXSourcesBuildPhase; files = (B1); };
                    T1 = {isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; buildPhases = (); fileSystemSynchronizedGroups = (S1); };
                    T2 = {isa = PBXNativeTarget; name = Tool; productType = "com.apple.product-type.tool"; buildPhases = (SP); };
                };
                rootObject = P1;
            }
            """
            try pbxproj.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
            let read = try #require(XcodeProject.read(project))
            let base = folder.standardizedFileURL.path
            #expect(read.target(of: base + "/App/ContentView.swift")?.name == "App")
            #expect(read.target(of: base + "/App/Other.swift") == nil)
            #expect(read.target(of: base + "/App/Excluded/A.swift") == nil)
            #expect(read.target(of: base + "/Legacy/Old.swift")?.name == "Tool")
        }
    }
}
