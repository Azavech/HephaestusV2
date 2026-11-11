import Foundation
import Testing
@testable import HephaestusCore

/// docs/views.md › Devices file, Built-in devices, Devices popover, Custom size;
/// docs/data-model.md › Devices file.
@Suite("Devices file")
struct PreviewDeviceCatalogTests {
    /// A temporary folder with the path of its `devices.json`.
    static func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("devices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(PreviewDeviceCatalog.fileName)
    }

    @Test("A missing file is written with the built-in devices: the iPhone models, the iPad models and the iPad windows")
    func writesMissingFile() throws {
        let url = try Self.file()
        #expect(PreviewDeviceCatalog.read(url) == .missing)
        #expect(try PreviewDeviceCatalog.writeBuiltInIfMissing(url))
        let devices = PreviewDeviceCatalog.read(url).devices
        #expect(devices == PreviewDeviceCatalog.builtIn)
        #expect(devices.first?.name == "iPhone 18 Pro")
        #expect(devices.contains { $0.family == .iPad && $0.portrait.horizontal == .regular })
        let windows = devices.filter { $0.name.hasSuffix("window") }
        #expect(windows.count == 6)
        #expect(windows.allSatisfy { $0.family == .iPad && $0.portrait.horizontal == .compact && $0.landscape.horizontal == .compact })
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"schema\": 1,\n  \"devices\": [\n    {\"name\": \"iPhone 18 Pro\", \"family\": \"iPhone\", \"width\": 402,"))
        #expect(text.hasSuffix("\n  ]\n}\n"))
    }

    @Test("An existing file, valid or not, is never written over")
    func keepsExistingFile() throws {
        for content in [#"{"schema": 1, "devices": []}"#, "not json", ""] {
            let url = try Self.file()
            try Data(content.utf8).write(to: url)
            #expect(try !PreviewDeviceCatalog.writeBuiltInIfMissing(url))
            #expect(try String(contentsOf: url, encoding: .utf8) == content)
        }
    }

    @Test("Reading: an invalid file gives no device and its reason; a device that breaks a rule or repeats a name is left out")
    func reading() {
        #expect(PreviewDeviceCatalog.parse(Data("[]".utf8)) == .invalid("it is not a JSON object"))
        #expect(PreviewDeviceCatalog.parse(Data("{".utf8)) == .invalid("it is not valid JSON"))
        #expect(PreviewDeviceCatalog.parse(Data(#"{"schema": 2}"#.utf8)) == .invalid("its schema is not 1"))
        #expect(PreviewDeviceCatalog.parse(Data(#"{"devices": 3}"#.utf8)) == .invalid("devices is not a list of devices"))
        #expect(PreviewDeviceCatalog.parse(Data("{}".utf8)) == .devices([]))
        let json = """
        {"schema": 1, "extra": true, "devices": [
          {"name": "Phone", "family": "iPhone", "width": 400, "height": 800, "scale": 3,
           "portrait": {"horizontal": "compact", "vertical": "regular"}, "landscape": {"horizontal": "regular", "vertical": "compact"}},
          {"name": "Phone", "family": "iPad", "width": 600, "height": 800, "scale": 2,
           "portrait": {"horizontal": "regular", "vertical": "regular"}, "landscape": {"horizontal": "regular", "vertical": "regular"}},
          {"name": "Wide", "family": "iPhone", "width": 4000, "height": 800, "scale": 3,
           "portrait": {"horizontal": "compact", "vertical": "regular"}, "landscape": {"horizontal": "compact", "vertical": "compact"}},
          {"name": "Watch", "family": "watch", "width": 200, "height": 240, "scale": 2,
           "portrait": {"horizontal": "compact", "vertical": "compact"}, "landscape": {"horizontal": "compact", "vertical": "compact"}},
          {"name": "Tablet", "family": "iPad", "width": 700, "height": 900, "scale": 2, "colour": "red",
           "portrait": {"horizontal": "regular", "vertical": "regular"}, "landscape": {"horizontal": "regular", "vertical": "regular"}}
        ]}
        """
        #expect(PreviewDeviceCatalog.parse(Data(json.utf8)).devices.map(\.name) == ["Phone", "Tablet"])
    }

    @Test("A device added by hand is read")
    func deviceAddedByHand() throws {
        let url = try Self.file()
        try PreviewDeviceCatalog.writeBuiltInIfMissing(url)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\n  ]\n}", with: """
        ,
            {"name": "Studio Display Phone", "family": "iPhone", "width": 500, "height": 900, "scale": 2, "portrait": {"horizontal": "compact", "vertical": "regular"}, "landscape": {"horizontal": "regular", "vertical": "compact"}}
          ]
        }
        """)
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(PreviewDeviceCatalog.read(url).devices.last?.name == "Studio Display Phone")
    }

    @Test("A custom size is added after the devices with its name, family, size, scale and size classes; the rest of the file is kept")
    func customSize() throws {
        let url = try Self.file()
        let json = """
        {"schema": 1, "note": "mine", "devices": [
          {"name": "Custom 400 × 800", "family": "iPhone", "width": 400, "height": 800, "scale": 3, "tag": 7,
           "portrait": {"horizontal": "compact", "vertical": "regular"}, "landscape": {"horizontal": "compact", "vertical": "compact"}},
          {"name": "Broken"}
        ]}
        """
        try Data(json.utf8).write(to: url)
        let added = try PreviewDeviceCatalog.add(family: .iPad, width: 400, height: 800, horizontal: .regular, vertical: .compact, to: url)
        #expect(added.name == "Custom 400 × 800 (2)")
        #expect(added.scale == 2)
        #expect(added.portrait == PreviewSizeClasses(horizontal: .regular, vertical: .compact))
        #expect(added.landscape == added.portrait)
        let devices = PreviewDeviceCatalog.read(url).devices
        #expect(devices.map(\.name) == ["Custom 400 × 800", "Custom 400 × 800 (2)"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["note"] as? String == "mine")
        let list = try #require(object["devices"] as? [[String: Any]])
        #expect(list.count == 3)
        #expect(list[0]["tag"] as? Int == 7)
        #expect(list[1]["name"] as? String == "Broken")

        let phone = try PreviewDeviceCatalog.add(family: .iPhone, width: 390, height: 844, horizontal: .compact, vertical: .regular, to: url)
        #expect(phone.name == "Custom 390 × 844" && phone.scale == 3)
    }

    @Test("A custom size is refused when the file cannot be read or is invalid")
    func customSizeFailures() throws {
        let missing = try Self.file()
        #expect(throws: PreviewDeviceCatalog.WriteError.self) {
            try PreviewDeviceCatalog.add(family: .iPhone, width: 400, height: 800, horizontal: .compact, vertical: .regular, to: missing)
        }
        let invalid = try Self.file()
        try Data("[]".utf8).write(to: invalid)
        #expect(throws: PreviewDeviceCatalog.WriteError(reason: "it is not a JSON object")) {
            try PreviewDeviceCatalog.add(family: .iPhone, width: 400, height: 800, horizontal: .compact, vertical: .regular, to: invalid)
        }
        #expect(try String(contentsOf: invalid, encoding: .utf8) == "[]")
    }

    @Test("The devices are grouped by family, iPhone then iPad, each in the order of the file")
    func grouping() {
        let devices = [PreviewDeviceCatalog.builtIn[9], PreviewDeviceCatalog.builtIn[1], PreviewDeviceCatalog.builtIn[8], PreviewDeviceCatalog.builtIn[0]]
        let groups = PreviewDeviceCatalog.grouped(devices)
        #expect(groups.map(\.family) == [.iPhone, .iPad])
        #expect(groups[0].devices.map(\.name) == ["iPhone 18 Pro Max", "iPhone 18 Pro"])
        #expect(groups[1].devices.map(\.name) == ["iPad Pro 11-inch (M5)", "iPad Pro 13-inch (M5)"])
        #expect(PreviewDeviceCatalog.grouped(Array(devices.prefix(2))).count == 2)
        #expect(PreviewDeviceCatalog.grouped([PreviewDeviceCatalog.builtIn[0]]).map(\.family) == [.iPhone])
    }

    @Test("A device's size, size classes and resolution in each orientation")
    func orientations() throws {
        let phone = try #require(PreviewDeviceCatalog.builtIn.first { $0.name == "iPhone 18 Pro" })
        #expect(phone.size(in: .portrait) == (402, 874))
        #expect(phone.size(in: .landscape) == (874, 402))
        #expect(phone.sizeClasses(in: .portrait).notation == "wC hR")
        #expect(phone.sizeClasses(in: .landscape).notation == "wC hC")
        #expect(phone.resolution(in: .portrait) == "402 × 874 pt · 1206 × 2622 px")
        #expect(phone.resolution(in: .landscape) == "874 × 402 pt · 2622 × 1206 px")
        let max = try #require(PreviewDeviceCatalog.builtIn.first { $0.name == "iPhone 18 Pro Max" })
        #expect(max.sizeClasses(in: .landscape).notation == "wR hC")
        let pad = try #require(PreviewDeviceCatalog.builtIn.first { $0.name == "iPad Pro 13-inch (M5)" })
        #expect(pad.sizeClasses(in: .landscape).notation == "wR hR")
        #expect(pad.resolution(in: .portrait) == "1032 × 1376 pt · 2064 × 2752 px")
    }

    @Test("Every built-in device follows the rules and has a name of its own")
    func builtInRules() {
        #expect(PreviewDeviceCatalog.builtIn.allSatisfy { $0.problem == nil })
        #expect(Set(PreviewDeviceCatalog.builtIn.map(\.name)).count == PreviewDeviceCatalog.builtIn.count)
        #expect(PreviewDeviceCatalog.builtIn.filter { $0.family == .iPhone }.allSatisfy {
            $0.landscape.horizontal == ($0.width >= 414 ? .regular : .compact) && $0.landscape.vertical == .compact
        })
    }
}
