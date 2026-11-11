import Foundation

extension PreviewHostSource {
    /// The iOS host (docs/views.md › Preview host, Device preview behaviour): an app that the
    /// engine launches in a simulator device with `--hephaestus-port <port> --hephaestus-token
    /// <token>`. It connects to the engine on `127.0.0.1`, sends the token as its first line, then
    /// reads its commands and writes its messages on the connection, one JSON object per line, the
    /// lines of its standard error included. Each preview on each device is a window of its own,
    /// with the device's size and traits; the clicks become touches, sent as HID events.
    static let iOSSupport = #"""
import Darwin
import Foundation
import SwiftUI
import UIKit

/// What a `#Preview` block gives: a SwiftUI view, a UIKit view or view controller, or nothing on
/// this platform.
enum __HephaestusPreviewContent {
    case swiftUI(AnyView)
    case uiKit(UIView)
    case controller(UIViewController)
    case unavailable

    @MainActor static func make<Content: SwiftUI.View>(@SwiftUI.ViewBuilder _ content: () -> Content) -> __HephaestusPreviewContent {
        .swiftUI(AnyView(content()))
    }

    @MainActor static func make(_ content: () -> UIView) -> __HephaestusPreviewContent {
        .uiKit(content())
    }

    @MainActor static func make(_ content: () -> UIViewController) -> __HephaestusPreviewContent {
        .controller(content())
    }
}

/// The settings of a preview window: the device's size in the orientation chosen and its traits.
fileprivate struct __HephaestusPreviewSettings {
    var width: CGFloat = 390
    var height: CGFloat = 844
    var dark = false
    var category: UIContentSizeCategory = .large
    var horizontal: UIUserInterfaceSizeClass = .compact
    var vertical: UIUserInterfaceSizeClass = .regular
    var idiom: UIUserInterfaceIdiom = .phone
    var scale: CGFloat = 3

    init(_ command: [String: Any]) {
        if let value = command["width"] as? Double { width = CGFloat(value) }
        if let value = command["height"] as? Double { height = CGFloat(value) }
        dark = (command["appearance"] as? String) == "dark"
        let categories: [String: UIContentSizeCategory] = [
            "xSmall": .extraSmall, "small": .small, "medium": .medium, "large": .large, "xLarge": .extraLarge,
            "xxLarge": .extraExtraLarge, "xxxLarge": .extraExtraExtraLarge, "accessibility1": .accessibilityMedium,
            "accessibility2": .accessibilityLarge, "accessibility3": .accessibilityExtraLarge,
            "accessibility4": .accessibilityExtraExtraLarge, "accessibility5": .accessibilityExtraExtraExtraLarge,
        ]
        if let name = command["dynamicTypeSize"] as? String, let category = categories[name] { self.category = category }
        horizontal = (command["horizontalSizeClass"] as? String) == "regular" ? .regular : .compact
        vertical = (command["verticalSizeClass"] as? String) == "compact" ? .compact : .regular
        idiom = (command["idiom"] as? String) == "pad" ? .pad : .phone
        if let value = command["scale"] as? Double { scale = CGFloat(value) }
    }
}

/// The root of a preview window: it holds the preview's view controller, gives it the device's
/// traits and takes the screen's safe areas away from it.
fileprivate final class __HephaestusPreviewContainer: UIViewController {
    var child: UIViewController?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    func embed(_ controller: UIViewController) {
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        child = controller
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard let child else { return }
        let insets = view.safeAreaInsets
        child.additionalSafeAreaInsets = UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right)
    }

    func apply(_ settings: __HephaestusPreviewSettings) {
        guard let child else { return }
        if #available(iOS 17.0, *) {
            child.traitOverrides.horizontalSizeClass = settings.horizontal
            child.traitOverrides.verticalSizeClass = settings.vertical
            child.traitOverrides.userInterfaceIdiom = settings.idiom
            child.traitOverrides.preferredContentSizeCategory = settings.category
            child.traitOverrides.userInterfaceStyle = settings.dark ? .dark : .light
            child.traitOverrides.displayScale = settings.scale
        } else {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(horizontalSizeClass: settings.horizontal), UITraitCollection(verticalSizeClass: settings.vertical),
                UITraitCollection(preferredContentSizeCategory: settings.category),
                UITraitCollection(userInterfaceStyle: settings.dark ? .dark : .light),
            ])
            setOverrideTraitCollection(traits, forChild: child)
        }
    }
}

/// A UIKit view shown as the view of a view controller.
fileprivate final class __HephaestusPreviewViewController: UIViewController {
    let content: UIView

    init(content: UIView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground
        content.frame = root.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(content)
        view = root
    }
}

/// One preview shown: its window and what it draws.
@MainActor fileprivate final class __HephaestusPreviewEntry {
    let key: String
    let window: UIWindow
    let container: __HephaestusPreviewContainer
    var settings: __HephaestusPreviewSettings
    var lastPixels: Data?
    var lastActivity = Date()
    var fresh = true
    /// The offset of the window while a touch lasts, so that the touch is on the screen.
    var touchOffset: CGPoint?

    init(key: String, window: UIWindow, container: __HephaestusPreviewContainer, settings: __HephaestusPreviewSettings) {
        self.key = key
        self.window = window
        self.container = container
        self.settings = settings
    }
}

/// Touches as HID events, the way the system sends them, through private symbols that the
/// simulator's frameworks have; without them, touches do nothing.
@MainActor fileprivate enum __HephaestusPreviewTouches {
    typealias Event = OpaquePointer
    typealias CreateDigitizer = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32, Double, Double, Double,
                                                Double, Double, Bool, Bool, UInt32) -> Event?
    typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double,
                                             Bool, Bool, UInt32) -> Event?
    typealias Append = @convention(c) (Event, Event, UInt32) -> Void
    typealias SetInteger = @convention(c) (Event, UInt32, Int) -> Void
    typealias SetFloat = @convention(c) (Event, UInt32, Double) -> Void
    typealias SetSender = @convention(c) (Event, UInt64) -> Void
    typealias SetDigitizerInfo = @convention(c) (Event, UInt32, Bool, Bool, CFString?, Double, Float) -> Void
    typealias Enqueue = @convention(c) (AnyObject, Selector, Event) -> Void

    struct Symbols {
        var createDigitizer: CreateDigitizer
        var createFinger: CreateFinger
        var append: Append
        var setInteger: SetInteger
        var setFloat: SetFloat
        var setSender: SetSender
        var setDigitizerInfo: SetDigitizerInfo
    }

    static let symbols: Symbols? = {
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        let backBoard = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW)
        func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let createDigitizer = symbol(iokit, "IOHIDEventCreateDigitizerEvent", CreateDigitizer.self),
              let createFinger = symbol(iokit, "IOHIDEventCreateDigitizerFingerEvent", CreateFinger.self),
              let append = symbol(iokit, "IOHIDEventAppendEvent", Append.self),
              let setInteger = symbol(iokit, "IOHIDEventSetIntegerValue", SetInteger.self),
              let setFloat = symbol(iokit, "IOHIDEventSetFloatValue", SetFloat.self),
              let setSender = symbol(iokit, "IOHIDEventSetSenderID", SetSender.self),
              let setDigitizerInfo = symbol(backBoard, "BKSHIDEventSetDigitizerInfo", SetDigitizerInfo.self) else {
            FileHandle.standardError.write(Data("HephaestusV2 preview host: touches are not available.\n".utf8))
            return nil
        }
        return Symbols(createDigitizer: createDigitizer, createFinger: createFinger, append: append, setInteger: setInteger,
                       setFloat: setFloat, setSender: setSender, setDigitizerInfo: setDigitizerInfo)
    }()

    /// Sends one touch event at a point of the screen: `down` while the finger touches it,
    /// `moved` for a move of a touching finger.
    static func send(window: UIWindow, at point: CGPoint, down: Bool, moved: Bool) {
        guard let symbols else { return }
        // Range and touch for a change of contact, position for a move.
        let mask: UInt32 = moved ? 0x4 : 0x3
        let time = mach_absolute_time()
        guard let hand = symbols.createDigitizer(kCFAllocatorDefault, time, 3, 0, 0, mask, 0, 0, 0, 0, 0, 0, down, down, 0),
              let finger = symbols.createFinger(kCFAllocatorDefault, time, 1, 2, mask, Double(point.x), Double(point.y), 0,
                                                down ? 1 : 0, 0, down, down, 0) else { return }
        // kIOHIDEventFieldDigitizerIsDisplayIntegrated, MajorRadius and MinorRadius.
        symbols.setInteger(hand, 0xB0019, 1)
        symbols.setFloat(finger, 0xB0014, 0.04)
        symbols.setFloat(finger, 0xB0015, 0.04)
        symbols.append(hand, finger, 0)
        symbols.setSender(hand, 0x0000_0001_0000_027F)
        let context = (window.value(forKey: "_contextId") as? NSNumber)?.uint32Value ?? 0
        symbols.setDigitizerInfo(hand, context, false, false, nil, 0, 0)
        let application = UIApplication.shared
        let selector = NSSelectorFromString("_enqueueHIDEvent:")
        guard application.responds(to: selector), let method = application.method(for: selector) else { return }
        unsafeBitCast(method, to: Enqueue.self)(application, selector, hand)
    }
}

/// The connection to the engine: a TCP socket on 127.0.0.1.
fileprivate final class __HephaestusPreviewLink: @unchecked Sendable {
    static let shared = __HephaestusPreviewLink()
    private let lock = NSLock()
    private var socket: Int32 = -1

    /// Connects with the port and the token of the launch arguments, then reads the commands on
    /// a thread of its own; the host ends when the engine closes the connection.
    func connect(onCommand: @escaping @Sendable (Data) -> Void) {
        let arguments = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let portText = value("--hephaestus-port"), let port = UInt16(portText), let token = value("--hephaestus-token") else {
            FileHandle.standardError.write(Data("HephaestusV2 preview host: no port.\n".utf8))
            exit(64)
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            FileHandle.standardError.write(Data("HephaestusV2 preview host: cannot connect.\n".utf8))
            exit(69)
        }
        lock.withLock { socket = descriptor }
        write(Data((token + "\n").utf8))
        relayStandardError()
        Thread.detachNewThread {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { exit(0) }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    onCommand(line)
                }
            }
        }
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        write(data)
    }

    private func write(_ data: Data) {
        lock.withLock {
            guard socket >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(socket, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    /// The lines of the standard error go to the engine too.
    private func relayStandardError() {
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { return }
        dup2(pipe[1], STDERR_FILENO)
        close(pipe[1])
        let reading = pipe[0]
        Thread.detachNewThread { [self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(reading, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    send(["type": "stderr", "line": line])
                }
            }
        }
    }
}

@objc(__HephaestusPreviewAppDelegate)
final class __HephaestusPreviewAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        __HephaestusPreviewLink.shared.connect { line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { __HephaestusPreviewHost.shared.handle(line) }
            }
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = __HephaestusPreviewSceneDelegate.self
        return configuration
    }
}

@objc(__HephaestusPreviewSceneDelegate)
final class __HephaestusPreviewSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated { __HephaestusPreviewHost.shared.connected(scene) }
    }
}

/// The preview host: its windows, their images and the events they receive.
@MainActor fileprivate final class __HephaestusPreviewHost {
    static let shared = __HephaestusPreviewHost()

    var registry: [String: @MainActor () -> __HephaestusPreviewContent] = [:]
    var entries: [String: __HephaestusPreviewEntry] = [:]
    var scene: UIWindowScene?
    var waiting: [Data] = []
    var ticks = 0

    func connected(_ scene: UIWindowScene) {
        self.scene = scene
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { __HephaestusPreviewHost.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        let lines = waiting
        waiting = []
        lines.forEach(handle)
        __HephaestusPreviewLink.shared.send(["type": "ready"])
    }

    func handle(_ line: Data) {
        guard scene != nil else {
            waiting.append(line)
            return
        }
        guard let command = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = command["type"] as? String, let key = command["window"] as? String else { return }
        switch type {
        case "open":
            open(key: key, preview: command["preview"] as? String ?? "", settings: __HephaestusPreviewSettings(command))
        case "update":
            if let entry = entries[key] { update(entry, settings: __HephaestusPreviewSettings(command)) }
        case "close":
            if let entry = entries.removeValue(forKey: key) {
                entry.window.isHidden = true
                entry.window.rootViewController = nil
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
            old.window.isHidden = true
            old.window.rootViewController = nil
        }
        guard let scene else { return }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: settings.width, height: settings.height)
        window.windowLevel = .normal
        let container = __HephaestusPreviewContainer()
        let content = registry[preview].map { $0() } ?? .unavailable
        let controller: UIViewController
        switch content {
        case .swiftUI(let view):
            controller = Self.hosting(view)
        case .unavailable:
            controller = Self.hosting(AnyView(Text("This preview does not build for iOS.").foregroundColor(.secondary)))
        case .uiKit(let view):
            controller = __HephaestusPreviewViewController(content: view)
        case .controller(let viewController):
            controller = viewController
        }
        container.loadViewIfNeeded()
        container.embed(controller)
        container.apply(settings)
        window.rootViewController = container
        window.overrideUserInterfaceStyle = settings.dark ? .dark : .light
        window.isHidden = false
        entries[key] = __HephaestusPreviewEntry(key: key, window: window, container: container, settings: settings)
    }

    static func hosting(_ view: AnyView) -> UIViewController {
        if #available(iOS 16.4, *) {
            let hosting = UIHostingController(rootView: view)
            hosting.safeAreaRegions = []
            return hosting
        }
        return UIHostingController(rootView: AnyView(view.edgesIgnoringSafeArea(.all)))
    }

    func update(_ entry: __HephaestusPreviewEntry, settings: __HephaestusPreviewSettings) {
        entry.settings = settings
        var frame = entry.window.frame
        frame.size = CGSize(width: settings.width, height: settings.height)
        entry.window.frame = frame
        entry.window.overrideUserInterfaceStyle = settings.dark ? .dark : .light
        entry.container.apply(settings)
        entry.lastActivity = Date()
        entry.fresh = true
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
        let window = entry.window
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let fresh = entry.fresh
        entry.fresh = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            UIColor.systemBackground.resolvedColor(with: window.traitCollection).setFill()
            context.fill(bounds)
            window.drawHierarchy(in: bounds, afterScreenUpdates: fresh)
        }
        guard let cgImage = image.cgImage, let pixels = cgImage.dataProvider?.data as Data? else { return }
        if pixels == entry.lastPixels { return }
        entry.lastPixels = pixels
        guard let png = image.pngData() else { return }
        __HephaestusPreviewLink.shared.send(["type": "frame", "window": entry.key, "width": cgImage.width, "height": cgImage.height,
                                             "png": png.base64EncodedString()])
    }

    // MARK: Events

    func point(_ command: [String: Any]) -> CGPoint {
        CGPoint(x: command["x"] as? Double ?? 0, y: command["y"] as? Double ?? 0)
    }

    /// A click is a touch: the window comes in front of the others, moved while the touch lasts
    /// when the point is out of the screen.
    func mouse(_ entry: __HephaestusPreviewEntry, _ command: [String: Any]) {
        guard (command["button"] as? String ?? "left") == "left", let scene else { return }
        entry.lastActivity = Date()
        let location = point(command)
        let screen = scene.screen.bounds
        switch command["kind"] as? String {
        case "mouseDown":
            for other in entries.values where other !== entry { other.window.windowLevel = .normal }
            entry.window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            entry.window.makeKey()
            var offset = CGPoint.zero
            if location.x >= screen.width - 1 { offset.x = screen.width - 40 - location.x }
            if location.y >= screen.height - 1 { offset.y = screen.height - 40 - location.y }
            entry.touchOffset = offset
            entry.window.frame.origin = offset
            __HephaestusPreviewTouches.send(window: entry.window, at: Self.onScreen(location, offset, screen), down: true, moved: false)
        case "mouseDragged":
            guard let offset = entry.touchOffset else { return }
            __HephaestusPreviewTouches.send(window: entry.window, at: Self.onScreen(location, offset, screen), down: true, moved: true)
        case "mouseUp":
            guard let offset = entry.touchOffset else { return }
            entry.touchOffset = nil
            __HephaestusPreviewTouches.send(window: entry.window, at: Self.onScreen(location, offset, screen), down: false, moved: false)
            if offset != .zero {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if entry.touchOffset == nil { entry.window.frame.origin = .zero }
                }
            }
        default:
            break
        }
    }

    static func onScreen(_ location: CGPoint, _ offset: CGPoint, _ screen: CGRect) -> CGPoint {
        CGPoint(x: min(max(location.x + offset.x, 0), screen.width - 1), y: min(max(location.y + offset.y, 0), screen.height - 1))
    }

    /// Scrolls the innermost scroll view under the point that can move, then the ones around it.
    func scroll(_ entry: __HephaestusPreviewEntry, _ command: [String: Any]) {
        entry.lastActivity = Date()
        var remainingX = CGFloat(command["deltaX"] as? Double ?? 0), remainingY = CGFloat(command["deltaY"] as? Double ?? 0)
        var view = entry.window.hitTest(point(command), with: nil)
        while let current = view, remainingX != 0 || remainingY != 0 {
            if let scrollView = current as? UIScrollView {
                let insets = scrollView.adjustedContentInset
                let minimum = CGPoint(x: -insets.left, y: -insets.top)
                let maximum = CGPoint(x: max(minimum.x, scrollView.contentSize.width + insets.right - scrollView.bounds.width),
                                      y: max(minimum.y, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height))
                let before = scrollView.contentOffset
                let after = CGPoint(x: min(max(before.x - remainingX, minimum.x), maximum.x),
                                    y: min(max(before.y - remainingY, minimum.y), maximum.y))
                if after != before {
                    scrollView.setContentOffset(after, animated: false)
                    if after.x != before.x { remainingX = 0 }
                    if after.y != before.y { remainingY = 0 }
                }
            }
            view = current.superview
        }
    }

    func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }

    /// The keys go to the text input that has the focus.
    func keyboard(_ entry: __HephaestusPreviewEntry, _ command: [String: Any]) {
        guard (command["kind"] as? String) == "keyDown", let responder = firstResponder(in: entry.window) else { return }
        entry.lastActivity = Date()
        let modifiers = Set(command["modifiers"] as? [String] ?? [])
        let keyCode = command["keyCode"] as? Int ?? -1
        let characters = command["characters"] as? String ?? ""
        let bare = (command["charactersIgnoringModifiers"] as? String ?? characters).lowercased()
        let input = responder as? UIKeyInput
        let text = responder as? UITextInput
        if modifiers.contains("command") {
            let actions: [String: Selector] = [
                "c": #selector(UIResponderStandardEditActions.copy(_:)), "x": #selector(UIResponderStandardEditActions.cut(_:)),
                "v": #selector(UIResponderStandardEditActions.paste(_:)), "a": #selector(UIResponderStandardEditActions.selectAll(_:)),
            ]
            if let action = actions[bare] {
                UIApplication.shared.sendAction(action, to: responder, from: nil, for: nil)
            } else if bare == "z" {
                if modifiers.contains("shift") { responder.undoManager?.redo() } else { responder.undoManager?.undo() }
            }
            return
        }
        switch keyCode {
        case 51:
            input?.deleteBackward()
        case 117:
            if let text, let range = text.selectedTextRange {
                if range.isEmpty, let end = text.position(from: range.start, offset: 1) {
                    text.selectedTextRange = text.textRange(from: range.start, to: end)
                }
                input?.deleteBackward()
            }
        case 36, 76:
            input?.insertText("\n")
        case 123, 124, 125, 126:
            guard let text, let range = text.selectedTextRange else { return }
            let direction: UITextLayoutDirection = [123: .left, 124: .right, 125: .down, 126: .up][keyCode] ?? .right
            let from = direction == .left || direction == .up ? range.start : range.end
            if range.isEmpty || direction == .up || direction == .down {
                if let position = text.position(from: from, in: direction, offset: 1) {
                    text.selectedTextRange = text.textRange(from: position, to: position)
                }
            } else {
                text.selectedTextRange = text.textRange(from: from, to: from)
            }
        case 48, 53:
            break
        default:
            guard !modifiers.contains("control"), !characters.isEmpty,
                  !characters.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return }
            input?.insertText(characters)
        }
    }
}
"""#

    /// The `@main` of the iOS host: UIKit's application with its delegate.
    static let iOSMain = """
    @main
    fileprivate enum __HephaestusPreviewHostMain {
        @MainActor static func main() {
            __HephaestusPreviewHost.shared.registry = __hephaestusPreviewRegistry()
            _ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, "__HephaestusPreviewAppDelegate")
        }
    }

    """
}
