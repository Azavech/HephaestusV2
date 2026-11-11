import Foundation

// docs/views.md › Device previews, docs/data-model.md › Devices file: the iPhone and iPad devices of
// the device previews, in `devices.json` and in the preview settings.

/// The families of the devices (docs/engine-api.md › PreviewDeviceFamily).
public enum PreviewDeviceFamily: String, Codable, Sendable, Hashable, CaseIterable {
    case iPhone
    case iPad

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// The size classes of UIKit and SwiftUI (docs/engine-api.md › PreviewSizeClass).
public enum PreviewSizeClass: String, Codable, Sendable, Hashable, CaseIterable {
    case compact
    case regular

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }

    /// `C` or `R`, as the devices popover writes them.
    public var letter: String {
        self == .compact ? "C" : "R"
    }

    /// `Compact` or `Regular`.
    public var title: String {
        self == .compact ? "Compact" : "Regular"
    }
}

/// The size classes of a device in one orientation (docs/engine-api.md › PreviewSizeClasses).
public struct PreviewSizeClasses: Codable, Sendable, Hashable {
    public var horizontal: PreviewSizeClass
    public var vertical: PreviewSizeClass

    public init(horizontal: PreviewSizeClass, vertical: PreviewSizeClass) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// `wC hR` (docs/views.md › Devices popover).
    public var notation: String {
        "w\(horizontal.letter) h\(vertical.letter)"
    }
}

/// The orientations of the device previews (docs/engine-api.md › PreviewOrientation).
public enum PreviewOrientation: String, Codable, Sendable, Hashable, CaseIterable {
    case portrait
    case landscape

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// An iPhone or iPad device of the device previews (docs/data-model.md › Preview device).
public struct PreviewDevice: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var family: PreviewDeviceFamily
    /// Points in portrait, 50 to 2000.
    public var width: Int
    /// Points in portrait, 50 to 2000.
    public var height: Int
    /// Pixels per point, 1 to 3.
    public var scale: Int
    public var portrait: PreviewSizeClasses
    public var landscape: PreviewSizeClasses

    public var id: String { name }

    /// The range of the width and the height.
    public static let sizeRange = 50...2000
    /// The range of the scale.
    public static let scaleRange = 1...3
    /// The longest name, in characters.
    public static let maximumNameLength = 100

    public init(name: String, family: PreviewDeviceFamily, width: Int, height: Int, scale: Int, portrait: PreviewSizeClasses,
                landscape: PreviewSizeClasses) {
        self.name = name
        self.family = family
        self.width = width
        self.height = height
        self.scale = scale
        self.portrait = portrait
        self.landscape = landscape
    }

    /// Its size in points in an orientation: landscape swaps the width and the height
    /// (docs/views.md › Device rows).
    public func size(in orientation: PreviewOrientation) -> (width: Int, height: Int) {
        orientation == .portrait ? (width, height) : (height, width)
    }

    public func sizeClasses(in orientation: PreviewOrientation) -> PreviewSizeClasses {
        orientation == .portrait ? portrait : landscape
    }

    /// `402 × 874 pt · 1206 × 2622 px` (docs/views.md › Devices popover).
    public func resolution(in orientation: PreviewOrientation) -> String {
        let size = size(in: orientation)
        return "\(size.width) × \(size.height) pt · \(size.width * scale) × \(size.height * scale) px"
    }

    /// The rule of docs/data-model.md › Preview device that it breaks, as `<key>: <reason>`; nil
    /// when it breaks none.
    public var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed != name || name.count > Self.maximumNameLength || name.contains(where: \.isNewline) {
            return "name: use 1 to \(Self.maximumNameLength) characters on one line"
        }
        if !Self.sizeRange.contains(width) { return "width: use 50 to 2000 points" }
        if !Self.sizeRange.contains(height) { return "height: use 50 to 2000 points" }
        if !Self.scaleRange.contains(scale) { return "scale: use 1 to 3" }
        return nil
    }
}

/// `<data dir>/devices.json` (docs/data-model.md › Devices file).
public struct PreviewDevicesFile: Codable, Sendable, Hashable {
    public var schema: Int
    public var devices: [PreviewDevice]

    public init(schema: Int = 1, devices: [PreviewDevice] = []) {
        self.schema = schema
        self.devices = devices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        devices = try c.decodeIfPresent([PreviewDevice].self, forKey: .devices) ?? []
    }
}

/// The devices file: its built-in list, its reading, the write of a missing file and the custom
/// sizes (docs/views.md › Devices file, Built-in devices, Custom size).
public enum PreviewDeviceCatalog {
    /// The file name in the data directory.
    public static let fileName = "devices.json"

    /// `<data dir>/devices.json`.
    public static func file(in dataDirectory: DataDirectory) -> URL {
        dataDirectory.url.appendingPathComponent(fileName)
    }

    /// What a read of the file gives.
    public enum Contents: Sendable, Hashable {
        case missing
        case devices([PreviewDevice])
        /// The file cannot be read or is not a valid devices file: the reason.
        case invalid(String)

        /// Its devices; none for a missing or invalid file.
        public var devices: [PreviewDevice] {
            if case .devices(let devices) = self { return devices }
            return []
        }
    }

    /// A failure of `add(_:to:)`.
    public struct WriteError: Error, Sendable, Hashable, CustomStringConvertible {
        public var reason: String
        public var description: String { reason }
    }

    // MARK: Built-in devices

    private static func device(_ name: String, _ family: PreviewDeviceFamily, _ width: Int, _ height: Int, _ scale: Int,
                               _ portrait: (PreviewSizeClass, PreviewSizeClass),
                               _ landscape: (PreviewSizeClass, PreviewSizeClass)) -> PreviewDevice {
        PreviewDevice(name: name, family: family, width: width, height: height, scale: scale,
                      portrait: PreviewSizeClasses(horizontal: portrait.0, vertical: portrait.1),
                      landscape: PreviewSizeClasses(horizontal: landscape.0, vertical: landscape.1))
    }

    /// The built-in devices, in their order (docs/views.md › Built-in devices).
    public static let builtIn: [PreviewDevice] = [
        device("iPhone 18 Pro", .iPhone, 402, 874, 3, (.compact, .regular), (.compact, .compact)),
        device("iPhone 18 Pro Max", .iPhone, 440, 956, 3, (.compact, .regular), (.regular, .compact)),
        device("iPhone Air", .iPhone, 420, 912, 3, (.compact, .regular), (.regular, .compact)),
        device("iPhone 17", .iPhone, 402, 874, 3, (.compact, .regular), (.compact, .compact)),
        device("iPhone 17e", .iPhone, 390, 844, 3, (.compact, .regular), (.compact, .compact)),
        device("iPhone 16 Plus", .iPhone, 430, 932, 3, (.compact, .regular), (.regular, .compact)),
        device("iPhone 13 mini", .iPhone, 360, 780, 3, (.compact, .regular), (.compact, .compact)),
        device("iPhone SE (3rd generation)", .iPhone, 375, 667, 2, (.compact, .regular), (.compact, .compact)),
        device("iPad Pro 13-inch (M5)", .iPad, 1032, 1376, 2, (.regular, .regular), (.regular, .regular)),
        device("iPad Pro 11-inch (M5)", .iPad, 834, 1210, 2, (.regular, .regular), (.regular, .regular)),
        device("iPad Air 13-inch (M4)", .iPad, 1024, 1366, 2, (.regular, .regular), (.regular, .regular)),
        device("iPad Air 11-inch (M4)", .iPad, 820, 1180, 2, (.regular, .regular), (.regular, .regular)),
        device("iPad (A16)", .iPad, 820, 1180, 2, (.regular, .regular), (.regular, .regular)),
        device("iPad mini (A20 Pro)", .iPad, 756, 1158, 2, (.regular, .regular), (.regular, .regular)),
        device("iPad Pro 13-inch (M5) · 1/3 window", .iPad, 375, 1032, 2, (.compact, .regular), (.compact, .regular)),
        device("iPad Pro 11-inch (M5) · 1/3 window", .iPad, 375, 834, 2, (.compact, .regular), (.compact, .regular)),
        device("iPad Pro 11-inch (M5) · 1/2 window", .iPad, 600, 834, 2, (.compact, .regular), (.compact, .regular)),
        device("iPad Air 11-inch (M4) · 1/2 window", .iPad, 585, 820, 2, (.compact, .regular), (.compact, .regular)),
        device("iPad mini (A20 Pro) · 1/3 window", .iPad, 320, 756, 2, (.compact, .regular), (.compact, .regular)),
        device("iPad mini (A20 Pro) · 1/2 window", .iPad, 574, 756, 2, (.compact, .regular), (.compact, .regular)),
    ]

    // MARK: Reading

    /// Reads the file: a file that is not a JSON object, whose `schema` is not 1 or whose
    /// `devices` is not an array of objects is invalid; a device that breaks a rule, or that has
    /// the name of an earlier device, is left out (docs/data-model.md › Devices file).
    public static func read(_ url: URL) -> Contents {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .invalid(error.localizedDescription)
        }
        return parse(data)
    }

    /// The devices of the file's content.
    public static func parse(_ data: Data) -> Contents {
        let object: [String: Any]
        switch topLevel(data) {
        case .success(let value): object = value
        case .failure(let error): return .invalid(error.reason)
        }
        guard let elements = object["devices"] as? [Any] ?? (object["devices"] == nil || object["devices"] is NSNull ? [] : nil),
              elements.allSatisfy({ $0 is [String: Any] }) else {
            return .invalid("devices is not a list of devices")
        }
        var devices: [PreviewDevice] = []
        var names: Set<String> = []
        for element in elements {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let device = try? JSONDecoder().decode(PreviewDevice.self, from: elementData),
                  device.problem == nil, !names.contains(device.name) else { continue }
            names.insert(device.name)
            devices.append(device)
        }
        return .devices(devices)
    }

    /// The file's object, its `schema` checked.
    private static func topLevel(_ data: Data) -> Result<[String: Any], WriteError> {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(WriteError(reason: "it is not valid JSON"))
        }
        guard let object = parsed as? [String: Any] else {
            return .failure(WriteError(reason: "it is not a JSON object"))
        }
        if let schema = object["schema"], !(schema is NSNull) {
            guard let number = schema as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == 1 else {
                return .failure(WriteError(reason: "its schema is not 1"))
            }
        }
        return .success(object)
    }

    /// The devices grouped by family, iPhone then iPad, each in the order of the file; a family
    /// without device is left out (docs/views.md › Devices popover).
    public static func grouped(_ devices: [PreviewDevice]) -> [(family: PreviewDeviceFamily, devices: [PreviewDevice])] {
        PreviewDeviceFamily.allCases.compactMap { family in
            let members = devices.filter { $0.family == family }
            return members.isEmpty ? nil : (family, members)
        }
    }

    // MARK: Writing

    /// Writes the built-in devices when the file is missing, never over an existing file, valid or
    /// not; true when it wrote the file (docs/views.md › Devices file).
    @discardableResult
    public static func writeBuiltInIfMissing(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 { return false }
        let data = encode(devicesFile: ["schema": 1, "devices": builtIn.map(object(of:))])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        try data.write(to: temporary)
        defer { unlink(temporary.path) }
        // link(2) fails when the file appeared meanwhile: an existing file is never replaced.
        if link(temporary.path, url.path) != 0 {
            if errno == EEXIST { return false }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path,
                                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
        return true
    }

    /// A custom size with its name: `Custom <width> × <height>`, then ` (2)`, ` (3)`… when a device
    /// of the file has that name (docs/views.md › Custom size).
    public static func customDevice(family: PreviewDeviceFamily, width: Int, height: Int, horizontal: PreviewSizeClass,
                                    vertical: PreviewSizeClass, existingNames: Set<String>) -> PreviewDevice {
        let base = "Custom \(width) × \(height)"
        var name = base
        var number = 2
        while existingNames.contains(name) {
            name = "\(base) (\(number))"
            number += 1
        }
        let classes = PreviewSizeClasses(horizontal: horizontal, vertical: vertical)
        return PreviewDevice(name: name, family: family, width: width, height: height, scale: family == .iPhone ? 3 : 2,
                             portrait: classes, landscape: classes)
    }

    /// Reads the file again and writes it with the custom size after its devices, every other key
    /// kept; the device added, with its name.
    @discardableResult
    public static func add(family: PreviewDeviceFamily, width: Int, height: Int, horizontal: PreviewSizeClass,
                           vertical: PreviewSizeClass, to url: URL) throws -> PreviewDevice {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WriteError(reason: error.localizedDescription)
        }
        var object: [String: Any]
        switch topLevel(data) {
        case .success(let value): object = value
        case .failure(let error): throw error
        }
        var elements: [Any] = []
        if let existing = object["devices"], !(existing is NSNull) {
            guard let list = existing as? [Any] else { throw WriteError(reason: "devices is not a list of devices") }
            elements = list
        }
        let names = Set(elements.compactMap { ($0 as? [String: Any])?["name"] as? String })
        let device = customDevice(family: family, width: width, height: height, horizontal: horizontal, vertical: vertical,
                                  existingNames: names)
        guard device.problem == nil else { throw WriteError(reason: device.problem ?? "") }
        elements.append(Self.object(of: device))
        object["devices"] = elements
        if object["schema"] == nil || object["schema"] is NSNull { object["schema"] = 1 }
        do {
            try encode(devicesFile: object).write(to: url, options: .atomic)
        } catch {
            throw WriteError(reason: error.localizedDescription)
        }
        return device
    }

    /// A device as a JSON object.
    static func object(of device: PreviewDevice) -> [String: Any] {
        [
            "name": device.name, "family": device.family.rawValue, "width": device.width, "height": device.height,
            "scale": device.scale,
            "portrait": ["horizontal": device.portrait.horizontal.rawValue, "vertical": device.portrait.vertical.rawValue],
            "landscape": ["horizontal": device.landscape.horizontal.rawValue, "vertical": device.landscape.vertical.rawValue],
        ]
    }

    // MARK: Layout

    /// The order of the keys of a device, then of its size classes.
    private static let keyOrder = ["name", "family", "width", "height", "scale", "portrait", "landscape", "horizontal", "vertical"]

    /// The file's text: `schema`, then `devices` with one device per line, then the other keys in
    /// name order, two spaces of indentation and a final line break (docs/data-model.md › Devices
    /// file).
    static func encode(devicesFile object: [String: Any]) -> Data {
        var lines: [String] = ["{"]
        var members: [String] = []
        members.append("  \"schema\": \(inline(object["schema"] ?? 1))")
        let devices = object["devices"] as? [Any] ?? []
        if devices.isEmpty {
            members.append("  \"devices\": []")
        } else {
            members.append("  \"devices\": [\n" + devices.map { "    " + inline($0) }.joined(separator: ",\n") + "\n  ]")
        }
        for key in object.keys.sorted() where key != "schema" && key != "devices" {
            members.append("  \(string(key)): \(inline(object[key] ?? NSNull()))")
        }
        lines.append(members.joined(separator: ",\n"))
        lines.append("}")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// A JSON value on one line: the keys of an object in the order of a device, then the others
    /// in name order.
    private static func inline(_ value: Any) -> String {
        if let object = value as? [String: Any] {
            let known = keyOrder.filter { object[$0] != nil }
            let others = object.keys.filter { !keyOrder.contains($0) }.sorted()
            let members = (known + others).map { "\(string($0)): \(inline(object[$0] ?? NSNull()))" }
            return "{" + members.joined(separator: ", ") + "}"
        }
        if let array = value as? [Any] {
            return "[" + array.map(inline).joined(separator: ", ") + "]"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func string(_ text: String) -> String {
        inline(text)
    }
}
