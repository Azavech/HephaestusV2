import Foundation
import Testing
@testable import HephaestusCore

/// docs/views.md › Elements, Properties and Rewriting the code: the elements of SwiftUI, AppKit and
/// UIKit files, their properties, the rewriting of their text, colour, font and spacing, and the
/// marks of the builds.
@Suite("Visual inspector elements")
struct ViewElementTests {
    static let swiftUI = """
    import SwiftUI

    struct Greeting: View {
        var name: String
        var body: some View {
            VStack(alignment: .leading) {
                Text("Hello")
                    .font(.title)
                Text(name).foregroundStyle(.red)
                Button("OK") { print("ok") }
                Button {
                    Text("Action").bold()
                } label: {
                    Text("Label")
                }
                if name.isEmpty {
                    Label("Empty", systemImage: "tray")
                } else {
                    Text("a") + Text("b")
                }
                ForEach(0..<3) { index in
                    Text("Row")
                }
                Badge()
                Spacer()
            }
            .padding(8)
        }

        private var footer: some View {
            HStack { Text("Footer") }
        }
    }

    struct Badge: View {
        var body: some View { Circle().fill(.blue) }
    }

    #Preview {
        Greeting(name: "x")
    }

    """

    static let appKit = """
    import AppKit

    final class Card: NSView {
        private let title = NSTextField(labelWithString: "Title")
        private let stack: NSStackView = {
            let stack = NSStackView()
            stack.spacing = 6
            return stack
        }()

        override init(frame: NSRect) {
            super.init(frame: frame)
            title.textColor = .labelColor
            addSubview(title)
            let button = NSButton(title: "Go", target: nil, action: nil)
            addSubview(button)
        }

        required init?(coder: NSCoder) { fatalError() }
    }

    """

    static let uiKit = """
    import UIKit

    final class ProfileView: UIView {
        let nameLabel = UILabel()
        let saveButton = UIButton(type: .system)
        let stack = UIStackView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            nameLabel.text = "Name"
            nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            saveButton.setTitle("Save", for: .normal)
            stack.addArrangedSubview(nameLabel)
            addSubview(stack)
        }

        required init?(coder: NSCoder) { fatalError() }
    }

    """

    static let context = ViewElementContext(swiftUIViews: ["Greeting", "Badge"])

    static func element(_ text: String, _ index: Int) -> ViewElement {
        let file = ViewElementScanner.read(text, context: context)
        return ViewElementEditor.viewElement(file.elements[index], in: file, path: "F.swift")
    }

    static func edit(_ text: String, _ index: Int, _ edit: ViewElementEdit) throws -> String {
        let file = ViewElementScanner.read(text, context: context)
        return try ViewElementEditor.apply(edit, to: file.elements[index], in: file)
    }

    static let blue = ViewElementColorValue(red: 0.2, green: 0.4, blue: 0.6)

    // MARK: SwiftUI

    @Test("The SwiftUI elements are the view calls of the bodies, the preview blocks and actions left out")
    func swiftUIElements() {
        let file = ViewElementScanner.read(Self.swiftUI, context: Self.context)
        #expect(file.elements.map(\.type) == ["VStack", "Text", "Text", "Button", "Button", "Text", "Label", "Text", "Badge", "HStack",
                                             "Text", "Circle"])
        #expect(file.elements.allSatisfy { $0.kind == .swiftUI })
        let label = Self.element(Self.swiftUI, 5)
        #expect(label.text?.value == "Label")
        #expect(label.line == 14)
    }

    @Test("A SwiftUI element shows its text, colour, font, padding and spacing")
    func swiftUIProperties() {
        let hello = Self.element(Self.swiftUI, 1)
        #expect(hello.text == ViewElementText(code: "\"Hello\"", value: "Hello"))
        #expect(hello.font == ViewElementFont(code: ".title", style: .title))
        #expect(hello.color == ViewElementColor())
        #expect(hello.padding == ViewElementLength())
        #expect(hello.spacing == nil)
        let name = Self.element(Self.swiftUI, 2)
        #expect(name.text == ViewElementText(code: "name"))
        #expect(name.color == ViewElementColor(code: ".red", name: "red"))
        let stack = Self.element(Self.swiftUI, 0)
        #expect(stack.text == nil)
        #expect(stack.padding == ViewElementLength(code: ".padding(8)", points: 8))
        #expect(stack.spacing == ViewElementLength())
        let circle = Self.element(Self.swiftUI, 11)
        #expect(circle.color == ViewElementColor(code: ".blue", name: "blue"))
    }

    @Test("Changing the text of a SwiftUI element rewrites its literal")
    func swiftUIText() throws {
        let text = try Self.edit(Self.swiftUI, 1, ViewElementEdit(property: .text, text: "Say \"hi\""))
        #expect(text.contains("Text(\"Say \\\"hi\\\"\")\n                .font(.title)"))
        #expect(throws: EngineError(.invalid, "The text of Text is not a string literal.")) {
            try Self.edit(Self.swiftUI, 2, ViewElementEdit(property: .text, text: "x"))
        }
    }

    @Test("Changing the colour of a SwiftUI element adds, replaces or removes its modifier")
    func swiftUIColor() throws {
        let added = try Self.edit(Self.swiftUI, 1, ViewElementEdit(property: .color, color: Self.blue))
        #expect(added.contains("Text(\"Hello\")\n                .font(.title)\n                .foregroundStyle(Color(red: 0.2, green: 0.4, blue: 0.6))\n"))
        let replaced = try Self.edit(Self.swiftUI, 2, ViewElementEdit(property: .color, color: ViewElementColorValue(red: 1, green: 0.5, blue: 0, opacity: 0.25)))
        #expect(replaced.contains("Text(name).foregroundStyle(Color(red: 1, green: 0.5, blue: 0, opacity: 0.25))\n"))
        let removed = try Self.edit(Self.swiftUI, 2, ViewElementEdit(property: .color))
        #expect(removed.contains("            Text(name)\n            Button(\"OK\")"))
        let shape = try Self.edit(Self.swiftUI, 11, ViewElementEdit(property: .color, color: Self.blue))
        #expect(shape.contains("Circle().fill(Color(red: 0.2, green: 0.4, blue: 0.6))"))
    }

    @Test("Changing the font of a SwiftUI element writes a text style or a system font")
    func swiftUIFont() throws {
        let style = try Self.edit(Self.swiftUI, 1, ViewElementEdit(property: .font, font: ViewElementFontValue(style: .headline)))
        #expect(style.contains("Text(\"Hello\")\n                .font(.headline)\n"))
        let system = try Self.edit(Self.swiftUI, 2, ViewElementEdit(property: .font, font: ViewElementFontValue(size: 17, weight: .bold)))
        #expect(system.contains("Text(name).foregroundStyle(.red).font(.system(size: 17, weight: .bold))\n"))
        let removed = try Self.edit(Self.swiftUI, 1, ViewElementEdit(property: .font))
        #expect(removed.contains("            Text(\"Hello\")\n            Text(name)"))
        let read = Self.element(system, 2)
        #expect(read.font == ViewElementFont(code: ".system(size: 17, weight: .bold)", size: 17, weight: .bold))
    }

    @Test("Changing the spacing and the padding of a SwiftUI element rewrites the stack's argument and the modifier")
    func swiftUISpacing() throws {
        let spacing = try Self.edit(Self.swiftUI, 0, ViewElementEdit(property: .spacing, points: 12.5))
        #expect(spacing.contains("VStack(alignment: .leading, spacing: 12.5) {"))
        #expect(Self.element(spacing, 0).spacing == ViewElementLength(code: "12.5", points: 12.5))
        #expect(try Self.edit(spacing, 0, ViewElementEdit(property: .spacing)) == Self.swiftUI)
        let stack = try Self.edit(Self.swiftUI, 9, ViewElementEdit(property: .spacing, points: 4))
        #expect(stack.contains("HStack(spacing: 4) { Text(\"Footer\") }"))
        #expect(try Self.edit(stack, 9, ViewElementEdit(property: .spacing)) == Self.swiftUI)
        let padding = try Self.edit(Self.swiftUI, 0, ViewElementEdit(property: .padding, points: 16))
        #expect(padding.contains("        }\n        .padding(16)\n    }"))
        let added = try Self.edit(Self.swiftUI, 10, ViewElementEdit(property: .padding, points: 2))
        #expect(added.contains("HStack { Text(\"Footer\").padding(2) }"))
        let removed = try Self.edit(Self.swiftUI, 0, ViewElementEdit(property: .padding))
        #expect(removed.contains("            Spacer()\n        }\n    }\n"))
        #expect(throws: EngineError(.invalid, "Text has no spacing.")) {
            try Self.edit(Self.swiftUI, 1, ViewElementEdit(property: .spacing, points: 2))
        }
        #expect(throws: EngineError(.invalid, "edit.points: use 0 to 1000.")) {
            try Self.edit(Self.swiftUI, 0, ViewElementEdit(property: .padding, points: 1001))
        }
    }

    @Test("A padding with edges keeps them")
    func paddingEdges() throws {
        let text = "import SwiftUI\nstruct A: View {\n    var body: some View {\n        Text(\"a\").padding(.horizontal)\n    }\n}\n"
        #expect(Self.element(text, 0).padding == ViewElementLength(code: ".padding(.horizontal)", edges: ".horizontal"))
        let set = try Self.edit(text, 0, ViewElementEdit(property: .padding, points: 8))
        #expect(set.contains("Text(\"a\").padding(.horizontal, 8)"))
        #expect(Self.element(set, 0).padding == ViewElementLength(code: ".padding(.horizontal, 8)", points: 8, edges: ".horizontal"))
    }

    // MARK: AppKit

    @Test("The AppKit elements are the view initializers, with their variables")
    func appKitElements() {
        let file = ViewElementScanner.read(Self.appKit, context: Self.context)
        #expect(file.elements.map(\.type) == ["NSTextField", "NSStackView", "NSButton"])
        #expect(file.elements.map(\.variable) == ["title", "stack", "button"])
        #expect(file.elements.map(\.isLocal) == [false, true, true])
        #expect(file.elements.allSatisfy { $0.kind == .appKit })
        let title = Self.element(Self.appKit, 0)
        #expect(title.text == ViewElementText(code: "\"Title\"", value: "Title"))
        #expect(title.color == ViewElementColor(code: ".labelColor", name: "labelColor"))
        #expect(title.font == ViewElementFont())
        #expect(title.padding == nil)
        #expect(Self.element(Self.appKit, 1).spacing == ViewElementLength(code: "6", points: 6))
    }

    @Test("Changing the text, colour, font and spacing of AppKit elements rewrites their code")
    func appKitEdits() throws {
        let text = try Self.edit(Self.appKit, 0, ViewElementEdit(property: .text, text: "Name"))
        #expect(text.contains("private let title = NSTextField(labelWithString: \"Name\")"))
        let color = try Self.edit(Self.appKit, 0, ViewElementEdit(property: .color, color: Self.blue))
        #expect(color.contains("        title.textColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)\n        addSubview(title)"))
        let font = try Self.edit(Self.appKit, 0, ViewElementEdit(property: .font, font: ViewElementFontValue(style: .title)))
        #expect(font.contains("        title.textColor = .labelColor\n        title.font = .preferredFont(forTextStyle: .title1)\n        addSubview(title)"))
        #expect(Self.element(font, 0).font == ViewElementFont(code: ".preferredFont(forTextStyle: .title1)", style: .title))
        let spacing = try Self.edit(Self.appKit, 1, ViewElementEdit(property: .spacing, points: 12))
        #expect(spacing.contains("        stack.spacing = 12\n"))
        let button = try Self.edit(Self.appKit, 2, ViewElementEdit(property: .color, color: Self.blue))
        #expect(button.contains("        let button = NSButton(title: \"Go\", target: nil, action: nil)\n        button.contentTintColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)\n        addSubview(button)"))
        let removed = try Self.edit(Self.appKit, 0, ViewElementEdit(property: .color))
        #expect(removed.contains("        super.init(frame: frame)\n        addSubview(title)"))
        #expect(throws: EngineError(.invalid, "NSTextField has no spacing.")) {
            try Self.edit(Self.appKit, 0, ViewElementEdit(property: .spacing, points: 1))
        }
    }

    @Test("A stored AppKit view without statements gets its first one before the first statement that names it")
    func appKitFirstStatement() throws {
        let text = """
        import AppKit

        final class Row: NSView {
            let label = NSTextField(labelWithString: "Row")

            func setUp() {
                addSubview(
                    label)
            }
        }

        """
        let edited = try Self.edit(text, 0, ViewElementEdit(property: .font, font: ViewElementFontValue(size: 13)))
        #expect(edited.contains("    func setUp() {\n        label.font = .systemFont(ofSize: 13)\n        addSubview(\n"))
    }

    // MARK: UIKit

    @Test("The UIKit elements and their properties")
    func uiKitElements() {
        let file = ViewElementScanner.read(Self.uiKit, context: Self.context)
        #expect(file.elements.map(\.type) == ["UILabel", "UIButton", "UIStackView"])
        #expect(file.elements.allSatisfy { $0.kind == .uiKit })
        let label = Self.element(Self.uiKit, 0)
        #expect(label.text == ViewElementText(code: "\"Name\"", value: "Name"))
        #expect(label.font == ViewElementFont(code: ".systemFont(ofSize: 15, weight: .semibold)", size: 15, weight: .semibold))
        #expect(label.color == ViewElementColor())
        #expect(Self.element(Self.uiKit, 1).text == ViewElementText(code: "\"Save\"", value: "Save"))
        #expect(Self.element(Self.uiKit, 2).spacing == ViewElementLength())
    }

    @Test("Changing the text, colour, font and spacing of UIKit elements rewrites their code")
    func uiKitEdits() throws {
        let text = try Self.edit(Self.uiKit, 0, ViewElementEdit(property: .text, text: "Full name"))
        #expect(text.contains("nameLabel.text = \"Full name\"\n"))
        let color = try Self.edit(Self.uiKit, 0, ViewElementEdit(property: .color, color: Self.blue))
        #expect(color.contains("        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)\n        nameLabel.textColor = UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)\n"))
        let font = try Self.edit(Self.uiKit, 0, ViewElementEdit(property: .font, font: ViewElementFontValue(style: .caption)))
        #expect(font.contains("nameLabel.font = .preferredFont(forTextStyle: .caption1)\n"))
        let title = try Self.edit(Self.uiKit, 1, ViewElementEdit(property: .text, text: "Done"))
        #expect(title.contains("saveButton.setTitle(\"Done\", for: .normal)\n"))
        let titleColor = try Self.edit(Self.uiKit, 1, ViewElementEdit(property: .color, color: Self.blue))
        #expect(titleColor.contains("        saveButton.setTitle(\"Save\", for: .normal)\n        saveButton.setTitleColor(UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1), for: .normal)\n"))
        let buttonFont = try Self.edit(Self.uiKit, 1, ViewElementEdit(property: .font, font: ViewElementFontValue(size: 20, weight: .heavy)))
        #expect(buttonFont.contains("        saveButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .heavy)\n"))
        let spacing = try Self.edit(Self.uiKit, 2, ViewElementEdit(property: .spacing, points: 8))
        #expect(spacing.contains("        stack.addArrangedSubview(nameLabel)\n        stack.spacing = 8\n        addSubview(stack)"))
        #expect(Self.element(spacing, 2).spacing == ViewElementLength(code: "8", points: 8))
    }

    // MARK: Checks and marks

    @Test("The values of an edit are checked")
    func checks() {
        #expect(throws: EngineError(.invalid, "edit.text: required for text.")) {
            try Self.edit(Self.swiftUI, 1, ViewElementEdit(property: .text))
        }
        #expect(throws: EngineError(.invalid, "edit.color.green: use 0 to 1.")) {
            try Self.edit(Self.swiftUI, 1, ViewElementEdit(property: .color, color: ViewElementColorValue(red: 0, green: 2, blue: 0)))
        }
        #expect(throws: EngineError(.invalid, "edit.font: give a style or a size.")) {
            try Self.edit(Self.swiftUI, 1, ViewElementEdit(property: .font, font: ViewElementFontValue()))
        }
        #expect(throws: EngineError(.invalid, "edit.font.size: use 1 to 1000.")) {
            try Self.edit(Self.swiftUI, 1, ViewElementEdit(property: .font, font: ViewElementFontValue(size: 0)))
        }
    }

    @Test("The marks keep the lines of the file and leave the preview blocks alone")
    func marks() throws {
        let marked = try #require(ViewElementScanner.marked(Self.swiftUI, path: "/p/Greeting.swift", context: Self.context))
        let lines = marked.components(separatedBy: "\n")
        let original = Self.swiftUI.components(separatedBy: "\n")
        #expect(lines[7] == "                .font(.title).__hephaestusPreviewElement(\"/p/Greeting.swift#1#Text\")")
        #expect(lines[original.count - 3] == "    Greeting(name: \"x\")")
        for (index, line) in original.enumerated() where !line.isEmpty {
            #expect(lines[index].hasPrefix(line.prefix(4)), "line \(index + 1)")
        }
        let appKit = try #require(ViewElementScanner.marked(Self.appKit, path: "/p/Card.swift", context: Self.context))
        #expect(appKit.contains("private let title = __hephaestusPreviewTag(NSTextField(labelWithString: \"Title\"), \"/p/Card.swift#0#NSTextField\")"))
        #expect(!appKit.contains("__HephaestusPreviewElementProbe"))
        #expect(ViewElementScanner.marked("struct A {}\n", path: "/p/A.swift", context: Self.context) == nil)
        let id = try #require(ViewElementScanner.parseMarkID("/p/a#b.swift#3#Text"))
        #expect(id.path == "/p/a#b.swift" && id.index == 3 && id.type == "Text")
    }

    @Test("The marked files compile with SwiftUI and AppKit, in Swift 5 and 6",
          .enabled(if: PreviewMethodsTests.runsBuilds, "Set PREVIEW_BUILD_TESTS=1 to build previews"), .timeLimit(.minutes(5)))
    func marksCompile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let swiftUI = Self.swiftUI.replacingOccurrences(of: "#Preview {\n    Greeting(name: \"x\")\n}\n", with: "")
        var paths: [String] = []
        for (name, text) in [("Greeting.swift", swiftUI), ("Card.swift", Self.appKit)] {
            let url = folder.appendingPathComponent(name)
            try #require(ViewElementScanner.marked(text, path: url.path, context: Self.context)).write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.path)
        }
        for version in ["5", "6"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swiftc", "-typecheck", "-parse-as-library", "-swift-version", version] + paths
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            let errors = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(errors)")
        }
    }
}
