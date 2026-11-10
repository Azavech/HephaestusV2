import AppKit
import ApplicationServices
import Foundation

/// The method `uiTree`: the Accessibility tree of an app (docs/virtual-machines.md › Methods).
enum AgentAccessibility {
    /// The tree stops at this many elements.
    static let maximumElements = 5_000
    /// A `value` is cut at this many characters.
    static let maximumValueLength = 2_000
    /// How long an app may take to answer for one element, in seconds. Set on the system-wide
    /// element, it holds for every element of the process; set on an app's element, it would
    /// hold for that element alone and leave its windows and controls the default.
    private static let messagingTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 5)
    }()
    /// The attributes read of each element, in this order.
    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
        kAXIdentifierAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXChildrenAttribute,
    ]

    static func tree(_ params: AgentParams) throws -> AgentResult {
        guard AXIsProcessTrusted() else { throw AgentError(AgentInput.permissionMessage) }
        let maximumDepth = try params.integer("maxDepth", default: 40, in: 1...200)
        let application = try application(named: try params.optionalString("app"))
        let element = AXUIElementCreateApplication(application.processIdentifier)
        _ = messagingTimeout
        var remaining = maximumElements
        let scale = AgentScreen.scale()
        let origin = CGDisplayBounds(CGMainDisplayID()).origin
        let tree = describe(element, depth: 1, maximumDepth: maximumDepth, remaining: &remaining, scale: scale, origin: origin)
        return AgentResult(json: [
            "app": clean(application.localizedName ?? ""),
            "bundleID": clean(application.bundleIdentifier ?? ""),
            "pid": Int(application.processIdentifier),
            "tree": tree,
        ])
    }

    /// The frontmost app, or the running app with this bundle identifier or name. NSWorkspace
    /// renews its lists of apps only when the main run loop turns, so they are read on the main
    /// queue: read on the thread of the connection, they could be those of an earlier request.
    private static func application(named name: String?) throws -> NSRunningApplication {
        let lookup = { () -> NSRunningApplication? in
            guard let name, !name.isEmpty else { return NSWorkspace.shared.frontmostApplication }
            let running = NSWorkspace.shared.runningApplications
            return running.first { $0.bundleIdentifier == name }
                ?? running.first { $0.localizedName == name }
                ?? running.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
        }
        let match = Thread.isMainThread ? lookup() : DispatchQueue.main.sync(execute: lookup)
        guard let match else {
            if let name, !name.isEmpty { throw AgentError("No running app named \(name).") }
            throw AgentError("No app is frontmost.")
        }
        return match
    }

    /// A string as JSON carries it: an unpaired surrogate, which a string of an app may hold,
    /// becomes U+FFFD.
    static func clean(_ text: String) -> String {
        var cleaned = String()
        cleaned.unicodeScalars.append(contentsOf: text.unicodeScalars)
        return cleaned
    }

    /// A length or a coordinate in screenshot pixels; nil for a number that is not finite or is
    /// beyond an integer, which an app may report.
    static func pixels(_ points: CGFloat, scale: Double) -> Int? {
        Int(exactly: (Double(points) * scale).rounded())
    }

    private static func describe(_ element: AXUIElement, depth: Int, maximumDepth: Int, remaining: inout Int, scale: Double,
                                 origin: CGPoint) -> [String: Any] {
        remaining -= 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values) == .success,
              let list = values as? [Any], list.count == attributes.count else {
            return [:]
        }
        func value(_ index: Int) -> Any? {
            let value = list[index]
            // A missing attribute is an AXValue holding its error.
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
        var node: [String: Any] = [:]
        for (index, key) in ["role", "subrole", "title", nil, "description", "identifier"].enumerated() {
            if let key, let text = value(index) as? String, !text.isEmpty {
                node[key] = clean(text)
            }
        }
        if let raw = value(3) {
            if let text = raw as? String {
                node["value"] = clean(text.count > maximumValueLength ? String(text.prefix(maximumValueLength)) : text)
            } else if let number = raw as? NSNumber {
                node["value"] = number.stringValue
            }
        }
        if let enabled = value(6) as? Bool { node["enabled"] = enabled }
        if let focused = value(7) as? Bool, focused { node["focused"] = true }
        if let positionValue = value(8), let sizeValue = value(9),
           CFGetTypeID(positionValue as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID() {
            var position = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(positionValue as! AXValue, .cgPoint, &position), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
               let x = pixels(position.x - origin.x, scale: scale), let y = pixels(position.y - origin.y, scale: scale),
               let width = pixels(size.width, scale: scale), let height = pixels(size.height, scale: scale) {
                node["frame"] = ["x": x, "y": y, "width": width, "height": height]
            }
        }
        if depth < maximumDepth, let children = value(10) as? [AXUIElement], !children.isEmpty {
            var described: [[String: Any]] = []
            for child in children where remaining > 0 {
                described.append(describe(child, depth: depth + 1, maximumDepth: maximumDepth, remaining: &remaining, scale: scale,
                                          origin: origin))
            }
            if !described.isEmpty {
                node["children"] = described
            }
        }
        return node
    }
}
