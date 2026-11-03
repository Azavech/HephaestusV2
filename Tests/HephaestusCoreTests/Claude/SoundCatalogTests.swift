import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Sound catalogue and › Sound search.
@Suite("Sound catalogue")
struct SoundCatalogTests {
    static func write(_ paths: [String], in folder: URL) throws {
        for path in paths {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
    }

    @Test("macOS sounds: the files directly in the folder with a sound extension, named macOS/<file>")
    func macOS() throws {
        try withTemporaryDirectory { folder in
            try Self.write(["Glass.aiff", "Basso.AIFF", "Tink.wav", "Pop.mp3", "Frog.caf", "readme.txt", ".Hidden.aiff", "Sub/Deep.aiff"],
                           in: folder)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Link.aiff"),
                                                       withDestinationURL: folder.appendingPathComponent("Glass.aiff"))
            let sounds = SoundCatalog.SystemSounds.read(macOSFolder: folder, runtimes: [])
            #expect(sounds.names == ["macOS/Basso.AIFF", "macOS/Frog.caf", "macOS/Glass.aiff", "macOS/Pop.mp3", "macOS/Tink.wav"])
            #expect(sounds.files["macOS/Glass.aiff"] == folder.appendingPathComponent("Glass.aiff"))
        }
    }

    @Test("Simulator runtime sounds: the files under System/Library/Audio/UISounds at any depth, named <runtime>/<path>")
    func runtimes() throws {
        try withTemporaryDirectory { folder in
            let iOS = folder.appendingPathComponent("iOS")
            let watchOS = folder.appendingPathComponent("watchOS")
            let other = folder.appendingPathComponent("Other")
            try Self.write(["System/Library/Audio/UISounds/sms-received1.caf", "System/Library/Audio/UISounds/New/Anticipate.caf",
                            "System/Library/Audio/UISounds/.hidden/x.caf", "System/Library/Audio/Other.caf"], in: iOS)
            try Self.write(["System/Library/Audio/UISounds/nano/Alert.caf"], in: watchOS)
            try Self.write(["System/Library/Audio/UISounds/second.caf"], in: other)
            let sounds = SoundCatalog.SystemSounds.read(macOSFolder: folder.appendingPathComponent("none"), runtimes: [
                SoundCatalog.Runtime(name: "watchOS 26.1", root: watchOS),
                SoundCatalog.Runtime(name: "iOS 26.1", root: iOS),
                SoundCatalog.Runtime(name: "iOS 26.1", root: other),
                SoundCatalog.Runtime(name: "iOS 18.0", root: folder.appendingPathComponent("missing")),
            ])
            #expect(sounds.names == ["iOS 26.1/New/Anticipate.caf", "iOS 26.1/sms-received1.caf", "watchOS 26.1/nano/Alert.caf"])
            #expect(sounds.files["iOS 26.1/sms-received1.caf"]
                == iOS.appendingPathComponent("System/Library/Audio/UISounds").appendingPathComponent("sms-received1.caf"))
        }
    }

    @Test("Project sounds: the listed files with a sound extension, named Project/<path>, after the system sounds")
    func project() throws {
        let root = URL(fileURLWithPath: "/Users/example/Developer/App", isDirectory: true)
        let system = SoundCatalog.SystemSounds(names: ["macOS/Glass.aiff"], files: ["macOS/Glass.aiff": URL(fileURLWithPath: "/x")],
                                               problems: [])
        let catalog = SoundCatalog(system: system, projectRoot: root, projectPaths: [
            "Sources/App.swift", "Sounds/b.wav", "Sounds/alert.caf", "Sounds/zap (2).caf", "Sounds/broken (.caf", "Sounds/close).caf",
            "Sounds/end.caf ", "Sounds/line\nbreak.caf",
        ])
        #expect(catalog.names == ["macOS/Glass.aiff", "Project/Sounds/alert.caf", "Project/Sounds/b.wav", "Project/Sounds/zap (2).caf"])
        #expect(catalog.contains("Project/Sounds/alert.caf") && catalog.contains("macOS/Glass.aiff"))
        #expect(!catalog.contains("Project/Sources/App.swift") && !catalog.contains("Project/Sounds/broken (.caf"))
        #expect(!catalog.contains("Sounds/alert.caf") && !catalog.contains("Project/../alert.caf"))
        #expect(catalog.file(for: "Project/Sounds/alert.caf") == root.appendingPathComponent("Sounds/alert.caf"))
    }

    @Test("A name splits at its first / into its source and its file")
    func sourceAndFile() {
        #expect(SoundCatalog.source(of: "iOS 26.1/New/Anticipate.caf") == "iOS 26.1")
        #expect(SoundCatalog.file(of: "iOS 26.1/New/Anticipate.caf") == "New/Anticipate.caf")
        #expect(SoundCatalog.source(of: "macOS/Glass.aiff") == "macOS")
        #expect(SoundCatalog.file(of: "Project/Sounds/alert.caf") == "Sounds/alert.caf")
    }

    @Test("Search: every word in the name, source included, in catalogue order, without the suggestions; nothing for an empty query")
    func search() {
        let names = ["macOS/Glass.aiff", "iOS 26.1/sms-received1.caf", "iOS 26.1/new-mail.caf", "watchOS 26.1/sms.caf",
                     "Project/Sounds/sms.caf"]
        #expect(SoundCatalog.search("  ", in: names).isEmpty)
        #expect(SoundCatalog.search("SMS", in: names) == ["iOS 26.1/sms-received1.caf", "watchOS 26.1/sms.caf", "Project/Sounds/sms.caf"])
        #expect(SoundCatalog.search("ios 26.1 sms", in: names) == ["iOS 26.1/sms-received1.caf"])
        #expect(SoundCatalog.search("project", in: names) == ["Project/Sounds/sms.caf"])
        #expect(SoundCatalog.search("sms", in: names, excluding: ["watchOS 26.1/sms.caf"])
            == ["iOS 26.1/sms-received1.caf", "Project/Sounds/sms.caf"])
    }

    @Test("Runtimes of xcrun simctl list runtimes --json: name and runtimeRoot of each entry; nil for other output")
    func simctl() {
        let json = #"""
        {"runtimes":[{"name":"iOS 26.1","platform":"iOS","version":"26.1","runtimeRoot":"/Library/Developer/CoreSimulator/Volumes/iOS_23B80/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.1.simruntime/Contents/Resources/RuntimeRoot"},{"name":"visionOS 26.1","runtimeRoot":"/V/RuntimeRoot"},{"name":"No root"},{"name":"bad/name","runtimeRoot":"/x"}]}
        """#
        let runtimes = SoundCatalog.runtimes(fromSimctlJSON: Data(json.utf8))
        #expect(runtimes?.map(\.name) == ["iOS 26.1", "visionOS 26.1"])
        #expect(runtimes?.last?.root.path == "/V/RuntimeRoot")
        #expect(SoundCatalog.runtimes(fromSimctlJSON: Data("xcrun: error".utf8)) == nil)
    }
}
