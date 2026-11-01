import Foundation
import Testing
@testable import HephaestusCore

@Suite("File tools")
struct FileToolsTests {
    @Test("The first executable file of PATH is found; relative entries and other files are skipped")
    func pathLookup() throws {
        try withTemporaryDirectory { folder in
            let first = folder.appendingPathComponent("first")
            let second = folder.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try Data().write(to: first.appendingPathComponent("gofmt"))
            try FileManager.default.createDirectory(at: first.appendingPathComponent("git"), withIntermediateDirectories: true)
            let gofmt = try writeScript(second.appendingPathComponent("gofmt"), "cat")
            let git = try writeScript(second.appendingPathComponent("git"), "exit 0")
            let path = ["relative", "", first.path, second.path].joined(separator: ":")
            #expect(FileTools.executable(named: "gofmt", inPATH: path) == gofmt)
            #expect(FileTools.executable(named: "git", inPATH: path) == git)
            #expect(FileTools.executable(named: "swift-format", inPATH: path) == nil)
            #expect(FileTools.executable(named: "gofmt", inPATH: nil) == nil)
        }
    }

    @Test("The lookup uses the captured PATH, then xcrun for swift-format")
    func lookUp() async throws {
        try await withTemporaryDirectory { folder in
            let bin = folder.appendingPathComponent("bin")
            let gofmt = try writeScript(bin.appendingPathComponent("gofmt"), "cat")
            let git = try writeScript(bin.appendingPathComponent("git"), "exit 0")
            let swiftFormat = try writeScript(folder.appendingPathComponent("toolchain/swift-format"), "cat")
            let xcrun = try writeScript(folder.appendingPathComponent("xcrun"), "echo \"$1 $2\" >&2\necho\necho '\(swiftFormat)'")
            let failingXcrun = try writeScript(folder.appendingPathComponent("xcrun-failing"), "exit 1")

            let environment = ["PATH": bin.path, "HEPHAESTUS_DATA_DIR": "/tmp/x"]
            let tools = await FileTools.lookUp(environment: environment, xcrun: xcrun)
            #expect(tools.gofmt == gofmt)
            #expect(tools.git == git)
            #expect(tools.swiftFormat == swiftFormat)
            #expect(tools.environment == ["PATH": bin.path])

            let none = await FileTools.lookUp(environment: ["PATH": folder.appendingPathComponent("empty").path], xcrun: failingXcrun)
            #expect(none.gofmt == nil)
            #expect(none.git == nil)
            #expect(none.swiftFormat == nil)
        }
    }

    @Test("git at /usr/bin/git is not used when xcode-select -p fails")
    func appleGit() async throws {
        try await withTemporaryDirectory { folder in
            let failing = try writeScript(folder.appendingPathComponent("xcode-select"), "exit 2")
            let succeeding = try writeScript(folder.appendingPathComponent("xcode-select-ok"), "echo /Applications/Xcode.app/Contents/Developer")
            let noXcrun = try writeScript(folder.appendingPathComponent("xcrun"), "exit 1")
            guard FileTools.isExecutableFile("/usr/bin/git") else { return }
            let without = await FileTools.lookUp(environment: ["PATH": "/usr/bin"], xcrun: noXcrun, xcodeSelect: failing)
            #expect(without.git == nil)
            let with = await FileTools.lookUp(environment: ["PATH": "/usr/bin"], xcrun: noXcrun, xcodeSelect: succeeding)
            #expect(with.git == "/usr/bin/git")
        }
    }

    @Test("Only .go and .swift files are formatted, each with its setting and tool")
    func formatterChoice() {
        let tools = FileTools(environment: [:], gofmt: "/bin/gofmt", swiftFormat: "/bin/swift-format")
        var settings = HostSettings()
        #expect(tools.formatter(forFile: "/p/main.go", settings: settings)?.executable == "/bin/gofmt")
        #expect(tools.formatter(forFile: "/p/MAIN.GO", settings: settings)?.arguments == [])
        #expect(tools.formatter(forFile: "/p/App.swift", settings: settings) == nil)
        settings.formatSwiftOnSave = true
        #expect(tools.formatter(forFile: "/p/App.swift", settings: settings)?.arguments == ["format", "--assume-filename", "/p/App.swift"])
        settings.formatGoOnSave = false
        #expect(tools.formatter(forFile: "/p/main.go", settings: settings) == nil)
        #expect(tools.formatter(forFile: "/p/go", settings: settings) == nil)
        #expect(FileTools(environment: [:]).formatter(forFile: "/p/App.swift", settings: settings) == nil)
    }
}

@Suite("Format on save")
struct FormatOnSaveTests {
    @Test("gofmt formats a .go file; the result carries the formatted text")
    func gofmt() async throws {
        try await withFileTestEngine { engine, connection, project in
            let gofmt = try writeScript(project.folder.appendingPathComponent("bin/gofmt"), "tr 'a-z' 'A-Z'")
            await engine.useFileTools(FileTools(environment: ["PATH": "/usr/bin:/bin"], gofmt: gofmt))
            let result = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "main.go", text: "package main\n"))
            #expect(result.text == "PACKAGE MAIN\n")
            #expect(try project.text("main.go") == "PACKAGE MAIN\n")
            let plain = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "notes.txt", text: "text\n"))
            #expect(plain.text == "text\n")

            _ = try await connection.call(SettingsUpdate.self, .init(formatGoOnSave: false))
            let unformatted = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "main.go", text: "package x\n"))
            #expect(unformatted.text == "package x\n")
        }
    }

    @Test("swift-format gets format --assume-filename and runs in the file's folder")
    func swiftFormat() async throws {
        try await withFileTestEngine(files: ["Sources/App/.keep": ""]) { engine, connection, project in
            let swiftFormat = try writeScript(project.folder.appendingPathComponent("bin/swift-format"),
                                              "printf '%s|' \"$@\"\npwd -P\ncat")
            await engine.useFileTools(FileTools(environment: ["PATH": "/usr/bin:/bin"], swiftFormat: swiftFormat))
            let path = "Sources/App/App.swift"
            let unformatted = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: path, text: "let x = 1\n"))
            #expect(unformatted.text == "let x = 1\n")

            _ = try await connection.call(SettingsUpdate.self, .init(formatSwiftOnSave: true))
            let result = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: path, text: "let x = 1\n"))
            let folder = FileSystemItems.resolvedPath(project.url("Sources/App").path)
            #expect(result.text == "format|--assume-filename|\(project.url(path).path)|\(folder)\nlet x = 1\n")
        }
    }

    @Test("A failing or slow formatter leaves the text unformatted")
    func failures() async throws {
        try await withFileTestEngine { engine, connection, project in
            let failing = try writeScript(project.folder.appendingPathComponent("bin/failing"), "echo broken\nexit 3")
            await engine.useFileTools(FileTools(environment: ["PATH": "/usr/bin:/bin"], gofmt: failing))
            let failed = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "a.go", text: "package a\n"))
            #expect(failed.text == "package a\n")
            #expect(try project.text("a.go") == "package a\n")

            let slow = try writeScript(project.folder.appendingPathComponent("bin/slow"), "sleep 30\ncat")
            await engine.useFileTools(FileTools(environment: ["PATH": "/usr/bin:/bin"], gofmt: slow))
            await engine.useFormatTimeout(.milliseconds(300))
            let start = ContinuousClock.now
            let timedOut = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "b.go", text: "package b\n"))
            #expect(timedOut.text == "package b\n")
            #expect(ContinuousClock.now - start < .seconds(20))

            let missing = project.folder.appendingPathComponent("bin/missing").path
            await engine.useFileTools(FileTools(environment: [:], gofmt: missing))
            let notStarted = try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "c.go", text: "package c\n"))
            #expect(notStarted.text == "package c\n")
        }
    }

    @Test("A change made on disk while the formatter runs is still a conflict")
    func conflictDuringFormat() async throws {
        try await withFileTestEngine(files: ["a.go": "package a\n"]) { engine, connection, project in
            let marker = project.folder.appendingPathComponent("formatting")
            let gofmt = try writeScript(project.folder.appendingPathComponent("bin/gofmt"),
                                        "touch '\(marker.path)'\nwhile [ -e '\(marker.path)' ]; do sleep 0.05; done\ncat")
            await engine.useFileTools(FileTools(environment: ["PATH": "/usr/bin:/bin"], gofmt: gofmt))
            let read = try await connection.call(FilesRead.self, .init(projectID: "TEST", path: "a.go"))
            async let write = engineError {
                try await connection.call(FilesWrite.self, .init(projectID: "TEST", path: "a.go", text: "package b\n", expectedModified: read.modified))
            }
            let deadline = ContinuousClock.now + .seconds(20)
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try project.write("a.go", "package other\n")
            try FileManager.default.setAttributes([.modificationDate: read.modified.addingTimeInterval(5)], ofItemAtPath: project.url("a.go").path)
            try FileManager.default.removeItem(at: marker)
            #expect(await write == EngineError(.conflict, "a.go changed on disk."))
            #expect(try project.text("a.go") == "package other\n")
        }
    }
}

@Suite("Ignored files")
struct IgnoredFilesTests {
    @Test("isIgnored is true for what git check-ignore reports, absent otherwise")
    func ignored() async throws {
        try await withFileTestEngine(files: ["a.log": "", "b.txt": "", "build/x": "", "src/c.log": ""]) { engine, connection, project in
            let git = try writeScript(project.folder.appendingPathComponent("bin/git"), """
            [ "$1" = "check-ignore" ] && [ "$2" = "-z" ] && [ "$3" = "--stdin" ] || exit 2
            tr '\\000' '\\n' | while IFS= read -r name; do
              case "$name" in *.log|build/) printf '%s\\000' "$name";; esac
            done
            exit 0
            """)
            await engine.useFileTools(FileTools(environment: ["PATH": "/usr/bin:/bin"], git: git))
            let entries = try await connection.call(FilesList.self, .init(projectID: "TEST", path: ""))
            let ignored = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.isIgnored) })
            #expect(ignored["a.log"] == .some(true))
            #expect(ignored["build"] == .some(true))
            #expect(ignored["b.txt"] == .some(nil))
            #expect(ignored["src"] == .some(nil))
            #expect(try await connection.call(FilesList.self, .init(projectID: "TEST", path: "src")).first?.isIgnored == true)
            let created = try await connection.call(FilesCreate.self, .init(projectID: "TEST", path: "src/new.log", isDirectory: false))
            #expect(created.isIgnored == true)
        }
    }

    @Test("Outside a git work tree isIgnored is absent")
    func notARepository() async throws {
        try await withFileTestEngine(files: ["a.log": ""]) { engine, connection, project in
            let git = try writeScript(project.folder.appendingPathComponent("bin/git"),
                                      "echo 'fatal: not a git repository' >&2\nexit 128")
            await engine.useFileTools(FileTools(environment: [:], git: git))
            let entries = try await connection.call(FilesList.self, .init(projectID: "TEST", path: ""))
            #expect(entries.allSatisfy { $0.isIgnored == nil })
        }
    }
}
