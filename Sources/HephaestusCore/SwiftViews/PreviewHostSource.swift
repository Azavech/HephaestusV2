import Foundation

/// The code of the preview host and of the preview blocks (docs/views.md › Preview host): the host
/// program compiled with the previews of a target, and the functions that give each `#Preview`
/// block of a file, with the map of their lines to the project's file.
public enum PreviewHostSource {
    /// The name of the host's file in a build.
    public static let hostFileName = "__HephaestusPreviewHost.swift"

    /// The host: the windows of the previews, their images and the events they receive, read on
    /// standard input and written on standard output, one JSON object per line. It is compiled in
    /// the target's module (Swift package) or in a module of its own (Xcode project), in Swift 5 or
    /// 6 language mode, so that every name it declares starts with `__HephaestusPreview`.
    static let support = #"""
import AppKit
import Foundation
import SwiftUI

/// What a `#Preview` block gives: a SwiftUI view, an AppKit view or view controller, or nothing on
/// this platform.
enum __HephaestusPreviewContent {
    case swiftUI(AnyView)
    case appKit(NSView)
    case controller(NSViewController)
    case unavailable

    @MainActor static func make<Content: SwiftUI.View>(@SwiftUI.ViewBuilder _ content: () -> Content) -> __HephaestusPreviewContent {
        .swiftUI(AnyView(content()))
    }

    @MainActor static func make(_ content: () -> NSView) -> __HephaestusPreviewContent {
        .appKit(content())
    }

    @MainActor static func make(_ content: () -> NSViewController) -> __HephaestusPreviewContent {
        .controller(content())
    }
}

/// A window of a preview: out of every display, never shown to the user.
fileprivate final class __HephaestusPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The settings of a preview window.
fileprivate struct __HephaestusPreviewSettings {
    var width: CGFloat = 400
    var height: CGFloat = 300
    var dark = false
    var dynamicTypeSize: DynamicTypeSize = .large

    init(_ command: [String: Any]) {
        if let value = command["width"] as? Double { width = CGFloat(value) }
        if let value = command["height"] as? Double { height = CGFloat(value) }
        dark = (command["appearance"] as? String) == "dark"
        let sizes: [String: DynamicTypeSize] = [
            "xSmall": .xSmall, "small": .small, "medium": .medium, "large": .large, "xLarge": .xLarge,
            "xxLarge": .xxLarge, "xxxLarge": .xxxLarge, "accessibility1": .accessibility1,
            "accessibility2": .accessibility2, "accessibility3": .accessibility3, "accessibility4": .accessibility4,
            "accessibility5": .accessibility5,
        ]
        if let name = command["dynamicTypeSize"] as? String, let size = sizes[name] { dynamicTypeSize = size }
    }
}

/// One preview shown: its window and what it draws.
@MainActor fileprivate final class __HephaestusPreviewEntry {
    let key: String
    let window: __HephaestusPreviewWindow
    var settings: __HephaestusPreviewSettings
    var swiftUIContent: AnyView?
    var hosting: NSHostingView<AnyView>?
    var controller: NSViewController?
    var lastPixels: Data?
    var lastActivity = Date()

    init(key: String, window: __HephaestusPreviewWindow, settings: __HephaestusPreviewSettings) {
        self.key = key
        self.window = window
        self.settings = settings
    }

    func rootView() -> AnyView? {
        swiftUIContent.map { AnyView($0.environment(\.dynamicTypeSize, settings.dynamicTypeSize)) }
    }
}

/// The preview host: reads its commands on standard input, one JSON object per line, and writes
/// its messages on standard output, one JSON object per line (docs/views.md › Preview host).
@MainActor fileprivate final class __HephaestusPreviewHost {
    static let shared = __HephaestusPreviewHost()

    var registry: [String: @MainActor () -> __HephaestusPreviewContent] = [:]
    var entries: [String: __HephaestusPreviewEntry] = [:]
    weak var keyEntry: __HephaestusPreviewEntry?
    var ticks = 0
    var eventNumber = 0

    func run(registry: [String: @MainActor () -> __HephaestusPreviewContent]) {
        self.registry = registry
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        installMenu()
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            // A menu of a view would block the host: it closes at once.
            if let menu = note.object as? NSMenu {
                menu.perform(#selector(NSMenu.cancelTrackingWithoutAnimation), with: nil, afterDelay: 0.15, inModes: [.common])
            }
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { __HephaestusPreviewHost.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = FileHandle.standardInput.availableData
                if chunk.isEmpty { exit(0) }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { __HephaestusPreviewHost.shared.handle(line) }
                    }
                }
            }
        }
        send(["type": "ready"])
        app.run()
    }

    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }

    // MARK: Messages

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    func handle(_ line: Data) {
        guard let command = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = command["type"] as? String, let key = command["window"] as? String else { return }
        switch type {
        case "open":
            open(key: key, preview: command["preview"] as? String ?? "", settings: __HephaestusPreviewSettings(command))
        case "update":
            if let entry = entries[key] { update(entry, settings: __HephaestusPreviewSettings(command)) }
        case "close":
            if let entry = entries.removeValue(forKey: key) {
                entry.window.orderOut(nil)
                entry.window.close()
            }
        case "mouse":
            if let entry = entries[key] { mouse(entry, command) }
        case "scroll":
            if let entry = entries[key] { scroll(entry, command) }
        case "key":
            if let entry = entries[key] { keyboard(entry, command) }
        default:
            break
        }
    }

    // MARK: Windows

    func open(key: String, preview: String, settings: __HephaestusPreviewSettings) {
        if let old = entries.removeValue(forKey: key) {
            old.window.orderOut(nil)
            old.window.close()
        }
        let left = (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 1000 + CGFloat(entries.count) * 40
        let window = __HephaestusPreviewWindow(contentRect: NSRect(x: left, y: 0, width: settings.width, height: settings.height),
                                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        let entry = __HephaestusPreviewEntry(key: key, window: window, settings: settings)
        let content: __HephaestusPreviewContent
        if let make = registry[preview] {
            content = make()
        } else {
            content = .unavailable
        }
        let bounds = NSRect(x: 0, y: 0, width: settings.width, height: settings.height)
        switch content {
        case .swiftUI(let view):
            entry.swiftUIContent = view
        case .unavailable:
            entry.swiftUIContent = AnyView(Text("This preview does not build for macOS.").foregroundStyle(.secondary))
        case .appKit(let view):
            let container = NSView(frame: bounds)
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            window.contentView = container
        case .controller(let controller):
            let container = NSView(frame: bounds)
            controller.view.frame = bounds
            controller.view.autoresizingMask = [.width, .height]
            container.addSubview(controller.view)
            entry.controller = controller
            window.contentView = container
        }
        if let root = entry.rootView() {
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            hosting.frame = bounds
            entry.hosting = hosting
            window.contentView = hosting
        }
        window.appearance = NSAppearance(named: settings.dark ? .darkAqua : .aqua)
        entries[key] = entry
        window.orderFrontRegardless()
    }

    func update(_ entry: __HephaestusPreviewEntry, settings: __HephaestusPreviewSettings) {
        entry.settings = settings
        var frame = entry.window.frame
        frame.size = NSSize(width: settings.width, height: settings.height)
        entry.window.setFrame(frame, display: true)
        entry.window.appearance = NSAppearance(named: settings.dark ? .darkAqua : .aqua)
        if let root = entry.rootView() {
            entry.hosting?.rootView = root
        }
        entry.lastActivity = Date()
    }

    // MARK: Images

    func tick() {
        ticks += 1
        let now = Date()
        for entry in entries.values where now.timeIntervalSince(entry.lastActivity) < 1 || ticks % 5 == 0 {
            capture(entry)
        }
    }

    func capture(_ entry: __HephaestusPreviewEntry) {
        guard let content = entry.window.contentView else { return }
        let view = content.superview ?? content
        let bounds = view.bounds
        let width = Int(bounds.width * 2), height = Int(bounds.height * 2)
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let pixels = bitmap.bitmapData else { return }
        let data = Data(bytes: pixels, count: bitmap.bytesPerRow * height)
        if data == entry.lastPixels { return }
        entry.lastPixels = data
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        send(["type": "frame", "window": entry.key, "width": width, "height": height, "png": png.base64EncodedString()])
    }

    // MARK: Events

    func makeKey(_ entry: __HephaestusPreviewEntry) {
        entry.lastActivity = Date()
        guard keyEntry !== entry || !entry.window.isKeyWindow else { return }
        keyEntry?.window.resignKey()
        entry.window.makeKey()
        if !entry.window.isKeyWindow { entry.window.becomeKey() }
        keyEntry = entry
    }

    func modifiers(_ command: [String: Any]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in command["modifiers"] as? [String] ?? [] {
            switch name {
            case "shift": flags.insert(.shift)
            case "control": flags.insert(.control)
            case "option": flags.insert(.option)
            case "command": flags.insert(.command)
            case "capsLock": flags.insert(.capsLock)
            case "function": flags.insert(.function)
            default: break
            }
        }
        return flags
    }

    func location(_ entry: __HephaestusPreviewEntry, _ command: [String: Any]) -> NSPoint {
        let x = command["x"] as? Double ?? 0, y = command["y"] as? Double ?? 0
        return NSPoint(x: x, y: entry.window.frame.height - y)
    }

    func mouse(_ entry: __HephaestusPreviewEntry, _ command: [String: Any]) {
        makeKey(entry)
        let right = (command["button"] as? String) == "right"
        let type: NSEvent.EventType
        switch command["kind"] as? String {
        case "mouseDown": type = right ? .rightMouseDown : .leftMouseDown
        case "mouseUp": type = right ? .rightMouseUp : .leftMouseUp
        case "mouseDragged": type = right ? .rightMouseDragged : .leftMouseDragged
        default: type = .mouseMoved
        }
        eventNumber += 1
        let down = type == .leftMouseDown || type == .rightMouseDown || type == .leftMouseDragged || type == .rightMouseDragged
        guard let event = NSEvent.mouseEvent(with: type, location: location(entry, command), modifierFlags: modifiers(command),
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: entry.window.windowNumber,
                                             context: nil, eventNumber: eventNumber,
                                             clickCount: type == .mouseMoved ? 0 : (command["clickCount"] as? Int ?? 1),
                                             pressure: down ? 1 : 0) else { return }
        NSApplication.shared.postEvent(event, atStart: false)
    }

    /// Scrolls the innermost scroll view under the point that can move, then the ones around it:
    /// wheel events do not reach a window out of every display.
    func scroll(_ entry: __HephaestusPreviewEntry, _ command: [String: Any]) {
        entry.lastActivity = Date()
        guard let content = entry.window.contentView else { return }
        let point = content.superview?.convert(location(entry, command), from: nil) ?? location(entry, command)
        let deltaX = CGFloat(command["deltaX"] as? Double ?? 0), deltaY = CGFloat(command["deltaY"] as? Double ?? 0)
        let hit = content.hitTest(point)
        var scrollView = (hit as? NSScrollView) ?? hit?.enclosingScrollView
        var remainingX = deltaX, remainingY = deltaY
        while let current = scrollView, remainingX != 0 || remainingY != 0 {
            let clip = current.contentView
            let flipped = current.documentView?.isFlipped ?? true
            var origin = clip.bounds.origin
            let before = origin
            origin.x -= remainingX
            origin.y += flipped ? -remainingY : remainingY
            let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
            if constrained != before {
                clip.scroll(to: constrained)
                current.reflectScrolledClipView(clip)
                remainingX = constrained.x == before.x ? remainingX : 0
                remainingY = constrained.y == before.y ? remainingY : 0
            }
            scrollView = current.superview?.enclosingScrollView
        }
    }

    func keyboard(_ entry: __HephaestusPreviewEntry, _ command: [String: Any]) {
        makeKey(entry)
        let type: NSEvent.EventType = (command["kind"] as? String) == "keyUp" ? .keyUp : .keyDown
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers(command),
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: entry.window.windowNumber,
                                           context: nil, characters: command["characters"] as? String ?? "",
                                           charactersIgnoringModifiers: command["charactersIgnoringModifiers"] as? String ?? "",
                                           isARepeat: false, keyCode: UInt16(command["keyCode"] as? Int ?? 0)) else { return }
        NSApplication.shared.postEvent(event, atStart: false)
    }
}
"""#

    /// The host's file: for iOS the iOS host, else the Mac host (docs/views.md › Preview host),
    /// each with the registry of the previews by key and its entry point, so that the same file
    /// builds for both platforms.
    public static func hostFile(entries: [(key: String, function: String)]) -> String {
        var registry = "@MainActor fileprivate func __hephaestusPreviewRegistry() -> [String: @MainActor () -> __HephaestusPreviewContent] {\n"
        if entries.isEmpty {
            registry += "    [:]\n"
        } else {
            registry += "    [\n"
            for entry in entries {
                registry += "        \(swiftStringLiteral(entry.key)): \(entry.function),\n"
            }
            registry += "    ]\n"
        }
        registry += "}\n\n"
        let macMain = """
        @main
        fileprivate enum __HephaestusPreviewHostMain {
            @MainActor static func main() {
                __HephaestusPreviewHost.shared.run(registry: __hephaestusPreviewRegistry())
            }
        }

        """
        return "#if os(iOS)\n" + iOSSupport + "\n\n" + registry + iOSMain + "#else\n" + support + "\n\n" + registry + macMain + "#endif\n"
    }

    /// The key of a preview block in the registry: the absolute path of its file and its rank among
    /// the file's blocks.
    public static func registryKey(path: String, block: Int) -> String {
        "\(path)#\(block)"
    }

    static func functionName(file: Int, block: Int) -> String {
        "__hephaestusPreview_\(file)_\(block)"
    }

    /// The functions of the preview blocks of a file, numbered `file`, with their registry entries
    /// and the lines of the code that come from the file. Each body keeps its text, its lines and
    /// its columns; the lines that start with `@Previewable` become the properties of a view that
    /// holds the body. A block inside `#if` blocks gives `.unavailable` when their conditions do
    /// not hold.
    public static func previewFunctions(file: Int, scan: SwiftFileScan, text: String, path: String)
        -> (code: String, entries: [(key: String, function: String)], segments: [PreviewSourceMap.Segment]) {
        let bytes = Array(text.utf8)
        var code = ""
        var line = 1
        var segments: [PreviewSourceMap.Segment] = []
        var entries: [(key: String, function: String)] = []
        func append(_ text: String) {
            code += text
            line += text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        func appendSource(_ text: String, from original: Int) {
            let count = text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
            segments.append(PreviewSourceMap.Segment(line: line, original: original, count: count))
            append(text + "\n")
        }
        for (index, block) in scan.previews.enumerated() {
            let name = functionName(file: file, block: index)
            entries.append((registryKey(path: path, block: index), name))
            append("\n@MainActor func \(name)() -> __HephaestusPreviewContent {\n")
            let conditions = block.conditions.filter { $0 != "true" }
            if !conditions.isEmpty {
                append("#if " + conditions.map { "(\($0))" }.joined(separator: " && ") + "\n")
            }
            var body = Array(bytes[block.bodyRange])
            for previewable in block.previewables {
                blank(&body, range: (previewable.range.lowerBound - block.bodyRange.lowerBound)..<(previewable.range.upperBound - block.bodyRange.lowerBound))
            }
            let bodyText = String(repeating: " ", count: column(of: block.bodyRange.lowerBound, in: bytes)) + String(decoding: body, as: UTF8.self)
            if block.previewables.isEmpty {
                append("    return __HephaestusPreviewContent.make {\n")
                appendSource(bodyText, from: block.bodyLine)
                append("    }\n")
            } else {
                append("    struct __HephaestusPreviewBody: SwiftUI.View {\n")
                for previewable in block.previewables {
                    var statement = Array(bytes[previewable.range])
                    let attribute = Array("@Previewable".utf8)
                    for i in 0..<min(attribute.count, statement.count) { statement[i] = 0x20 }
                    appendSource(String(repeating: " ", count: column(of: previewable.range.lowerBound, in: bytes))
                                    + String(decoding: statement, as: UTF8.self), from: previewable.line)
                }
                append("        var body: some SwiftUI.View {\n")
                appendSource(bodyText, from: block.bodyLine)
                append("        }\n")
                append("    }\n")
                append("    return __HephaestusPreviewContent.make { __HephaestusPreviewBody() }\n")
            }
            if !conditions.isEmpty {
                append("#else\n    return .unavailable\n#endif\n")
            }
            append("}\n")
        }
        return (code, entries, segments)
    }

    /// Spaces in place of the bytes of `range`, line breaks kept.
    static func blank(_ bytes: inout [UInt8], range: Range<Int>) {
        for i in range where i >= 0 && i < bytes.count && bytes[i] != 0x0A {
            bytes[i] = 0x20
        }
    }

    /// The column of a UTF-8 offset, from 0: the bytes since the start of its line.
    static func column(of offset: Int, in bytes: [UInt8]) -> Int {
        var start = min(offset, bytes.count)
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        return offset - start
    }

    /// `text` as a Swift string literal.
    public static func swiftStringLiteral(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

/// How the lines of a file that a build compiles come from a file of the project: the lines of a
/// copy, and the bodies of its preview blocks after it, so that the compiler's errors name the
/// project's own file, line and column (docs/views.md › Build rules).
public struct PreviewSourceMap: Sendable, Hashable {
    /// Lines `line` to `line + count - 1` of the compiled file are the lines from `original` of the
    /// project's file.
    public struct Segment: Sendable, Hashable {
        public var line: Int
        public var original: Int
        public var count: Int
    }

    /// The absolute path of the project's file.
    public var path: String
    public var segments: [Segment]

    /// The line of the project's file of a line of the compiled file; nil for the code the build
    /// adds.
    public func originalLine(_ line: Int) -> Int? {
        for segment in segments where line >= segment.line && line < segment.line + segment.count {
            return segment.original + line - segment.line
        }
        return nil
    }
}
