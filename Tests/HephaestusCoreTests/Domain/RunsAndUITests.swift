import Foundation
import Testing
@testable import HephaestusCore

/// projects.run, projects.stopRun, the run events and ui.open through `LocalEngineConnection`
/// (docs/engine-api.md › projects.run, › UI navigation; docs/projects.md › Run commands).
@Suite("Runs and ui.open")
struct RunsAndUITests {
    /// Creates the project HEPH with the given commands.
    static func project(_ h: DomainHarness, build: String? = nil, run: String? = nil, test: String? = nil) async throws {
        try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
        _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", commands: ProjectCommands(build: build, run: run, test: test)))
    }

    @Test("A waited run returns its exit code and output tail; stdout and stderr are merged; the events follow")
    func waitedRun() async throws {
        try await withDomainEngine { h in
            try await Self.project(h, build: "echo out; echo err >&2; pwd; env | grep -c '^HEPHAESTUS_'; exit 3")
            let events = await DomainEventRecorder.make(h)
            let result = try await h.connection.call(ProjectsRun.self, .init(projectID: "HEPH", kind: .build, wait: true))
            #expect(result.exitCode == 3)
            #expect(result.run.kind == .build && result.run.projectID == "HEPH" && result.run.command == result.run.command)
            let realRoot = Engine.realPath(h.path("Heph"))!
            #expect(result.outputTail == "out\nerr\n\(realRoot)\n0\n" || result.outputTail == "out\nerr\n\(h.path("Heph"))\n0\n")
            await events.wait(for: RunFinishedEvent.name)
            #expect(events.names.first == "run.started")
            #expect(events.names.last == "run.finished")
            #expect(events.all.first?.origin == .user(deviceID: h.engine.deviceID))
            #expect(events.all.last?.origin == .system)
            let output = try events.all.filter { $0.name == RunOutputEvent.name }.map { try $0.payload(RunOutputEvent.self).text }.joined()
            #expect(output == result.outputTail)
            #expect(try events.all.last!.payload(RunFinishedEvent.self) == .init(runID: result.run.runID, projectID: "HEPH", exitCode: 3))
            #expect(try await h.connection.call(SnapshotGet.self).runs.isEmpty)
        }
    }

    @Test("A run that is not waited returns at once; a second run of the kind conflicts; stopRun sends SIGINT")
    func stopRun() async throws {
        try await withDomainEngine { h in
            try await Self.project(h, run: "sleep 30", test: "true")
            let events = await DomainEventRecorder.make(h)
            let started = try await h.connection.call(ProjectsRun.self, .init(projectID: "HEPH", kind: .run, wait: false))
            #expect(started.exitCode == nil && started.outputTail == "")
            #expect(try await h.connection.call(SnapshotGet.self).runs == [started.run])
            #expect(await engineError { try await h.connection.call(ProjectsRun.self, .init(projectID: "HEPH", kind: .run, wait: false)) }
                == EngineError(.conflict, "A run of HEPH is already running."))
            let test = try await h.call(ProjectsRun.self, .init(projectID: "HEPH", kind: .test, wait: true), as: h.claude)
            #expect(test.exitCode == 0)
            _ = try await h.connection.call(ProjectsStopRun.self, .init(runID: started.run.runID))
            await events.wait(for: RunFinishedEvent.name, count: 2)
            let finished = try events.all.filter { $0.name == RunFinishedEvent.name }.map { try $0.payload(RunFinishedEvent.self) }
            #expect(finished.contains(.init(runID: started.run.runID, projectID: "HEPH", exitCode: 130)))
            #expect(await engineError { try await h.connection.call(ProjectsStopRun.self, .init(runID: started.run.runID)) }
                == EngineError(.notFound, "Run \(started.run.runID.uuidString) not found."))
        }
    }

    @Test("The wait ends at the timeout while the run continues")
    func timeout() async throws {
        try await withDomainEngine { h in
            try await Self.project(h, build: "echo begin; sleep 30")
            let result = try await h.connection.call(ProjectsRun.self, .init(projectID: "HEPH", kind: .build, wait: true, timeoutSeconds: 1))
            #expect(result.exitCode == nil)
            #expect(result.outputTail == "begin\n")
            #expect(try await h.connection.call(SnapshotGet.self).runs.map(\.runID) == [result.run.runID])
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(ProjectsRemove.self, .init(projectID: "HEPH"))
            await events.wait(for: RunFinishedEvent.name)
            #expect(events.names.last == "run.finished")
        }
    }

    @Test("projects.run refuses a missing command, an invalid timeout and an unknown project")
    func runErrors() async throws {
        try await withDomainEngine { h in
            try await Self.project(h, build: "true")
            #expect(await engineError { try await h.connection.call(ProjectsRun.self, .init(projectID: "HEPH", kind: .test, wait: true)) }
                == EngineError(.invalid, "HEPH has no test command."))
            for timeout in [0, 1801] {
                #expect(await engineError {
                    try await h.connection.call(ProjectsRun.self, .init(projectID: "HEPH", kind: .build, wait: true, timeoutSeconds: timeout))
                }?.code == .invalid)
            }
            #expect(await engineError { try await h.connection.call(ProjectsRun.self, .init(projectID: "NONE", kind: .build, wait: true)) }?
                .code == .notFound)
            #expect(await engineError { try await h.connection.call(ProjectsStopRun.self, .init(runID: UUID())) }?.code == .notFound)
        }
    }

    @Test("A run killed by a signal exits with 128 + the signal number; output is decoded as UTF-8")
    func signalExit() async throws {
        try await withDomainEngine { h in
            try await Self.project(h, build: "printf 'caf\\303\\251 \\377\\n'; kill -TERM $$")
            let result = try await h.connection.call(ProjectsRun.self, .init(projectID: "HEPH", kind: .build, wait: true))
            #expect(result.exitCode == 143)
            #expect(result.outputTail == "café \u{FFFD}\n")
        }
    }

    @Test("Shutdown ends the running runs")
    func shutdown() async throws {
        try await withDomainEngine { h in
            try await Self.project(h, run: "sleep 30")
            _ = try await h.connection.call(ProjectsRun.self, .init(projectID: "HEPH", kind: .run, wait: false))
            let clock = ContinuousClock()
            let elapsed = await clock.measure { await h.engine.stopProjectRuns() }
            #expect(elapsed < .seconds(4))
        }
    }

    @Test("Output chunks are cut at complete UTF-8 sequences")
    func decoder() {
        var decoder = UTF8ChunkDecoder()
        let bytes = Array("é€😀".utf8)
        var text = ""
        for byte in bytes {
            text += decoder.decode(Data([byte]))
        }
        #expect(text == "é€😀")
        #expect(decoder.decode(Data([0xE2, 0x82])) == "")
        #expect(decoder.finish() == "\u{FFFD}")
        #expect(decoder.decode(Data([0x41, 0x80, 0x42])) == "A\u{FFFD}B")
    }

    @Test("The output tail keeps the last 200 lines and at most 20,000 characters")
    func tail() {
        var tail = OutputTail()
        tail.append((1...300).map { "line \($0)\n" }.joined())
        #expect(tail.text.hasPrefix("line 101\n"))
        #expect(tail.text.components(separatedBy: "\n").count == 201)
        tail.append("partial")
        #expect(tail.text.hasPrefix("line 102\n") && tail.text.hasSuffix("line 300\npartial"))
        var long = OutputTail()
        long.append(String(repeating: "x", count: 30_000))
        #expect(long.text.count == 20_000)
        var crlf = OutputTail()
        crlf.append((1...250).map { "l\($0)\r\n" }.joined())
        #expect(crlf.text.hasPrefix("l51\r\n"))
    }

    // MARK: ui.open

    @Test("ui.open checks the target and emits it for the requested device")
    func uiOpen() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            try writeFile("# Docs", to: h.projects.appendingPathComponent("Heph/docs/index.md"))
            try FileManager.default.createDirectory(at: h.projects.appendingPathComponent("Heph/Sources"), withIntermediateDirectories: true)
            let tab = try await h.connection.call(WebTabsOpen.self, .init(projectID: "HEPH", url: "https://example.com"))
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(UIOpen.self, .init(target: .ticket(ticketID: "heph-1"), deviceID: "D1"))
            await events.wait(for: UIOpenEvent.name)
            #expect(try events.all[0].payload(UIOpenEvent.self) == .init(target: .ticket(ticketID: "HEPH-1"), deviceID: "D1"))
            events.clear()
            _ = try await h.call(UIOpen.self, .init(target: .doc(projectID: "HEPH", path: "docs/index.md/"), deviceID: "D1"), as: h.claude)
            await events.wait(for: UIOpenEvent.name)
            #expect(try events.all[0].payload(UIOpenEvent.self) == .init(target: .doc(projectID: "HEPH", path: "docs/index.md")))
            events.clear()
            // The fragment is passed on unchecked.
            _ = try await h.call(UIOpen.self, .init(target: .doc(projectID: "heph", path: "docs/index.md", fragment: "über-uns")), as: h.claude)
            await events.wait(for: UIOpenEvent.name)
            #expect(try events.all[0].payload(UIOpenEvent.self)
                == .init(target: .doc(projectID: "HEPH", path: "docs/index.md", fragment: "über-uns")))

            let valid: [NavigationTarget] = [
                .project(projectID: "heph"), .file(projectID: "HEPH", path: "docs/index.md", line: 3),
                .webTab(projectID: "HEPH", tabID: tab.id), .section(projectID: "HEPH", section: .web),
            ]
            for target in valid {
                _ = try await h.connection.call(UIOpen.self, .init(target: target))
            }
            // A file target without line may name a folder, which the client reveals in the tree.
            _ = try await h.connection.call(UIOpen.self, .init(target: .file(projectID: "heph", path: "Sources/", line: nil)))
            let folder = UIOpenEvent.Payload(target: .file(projectID: "HEPH", path: "Sources", line: nil))
            let received = await events.wait { all in
                all.contains { $0.name == UIOpenEvent.name && (try? $0.payload(UIOpenEvent.self)) == folder }
            }
            #expect(received.contains { $0.name == UIOpenEvent.name && (try? $0.payload(UIOpenEvent.self)) == folder })
            func error(_ target: NavigationTarget) async -> EngineError? {
                await engineError { try await h.connection.call(UIOpen.self, .init(target: target)) }
            }
            #expect(await error(.ticket(ticketID: "HEPH-9")) == EngineError(.notFound, "Ticket HEPH-9 not found."))
            #expect(await error(.ticket(ticketID: "nine"))?.code == .invalid)
            #expect(await error(.bundle(bundleID: "HEPH-B1")) == EngineError(.notFound, "Bundle HEPH-B1 not found."))
            #expect(await error(.chat(chatID: UUID()))?.code == .notFound)
            #expect(await error(.project(projectID: "NONE")) == EngineError(.notFound, "Project NONE not found."))
            #expect(await error(.doc(projectID: "HEPH", path: "docs/missing.md")) == EngineError(.notFound, "Doc docs/missing.md not found."))
            #expect(await error(.doc(projectID: "HEPH", path: "docs/../x"))?.code == .invalid)
            #expect(await error(.file(projectID: "HEPH", path: "Sources", line: 1)) == EngineError(.notFound, "File Sources not found."))
            #expect(await error(.file(projectID: "HEPH", path: "Missing", line: nil)) == EngineError(.notFound, "File Missing not found."))
            #expect(await error(.doc(projectID: "HEPH", path: "docs")) == EngineError(.notFound, "Doc docs not found."))
            #expect(await error(.file(projectID: "HEPH", path: "/etc/hosts", line: nil))?.code == .invalid)
            #expect(await error(.file(projectID: "HEPH", path: "docs/index.md", line: 0))?.code == .invalid)
            #expect(await error(.skill(name: "Not A Skill"))?.code == .invalid)
            #expect(await error(.skill(name: "release-notes")) == EngineError(.notFound, "Skill release-notes not found."))
            #expect(await error(.webTab(projectID: "HEPH", tabID: UUID()))?.code == .notFound)

            let skills = DataDirectory(url: h.folder.appendingPathComponent("Data")).skillsFolder
            try writeFile("---\nname: release-notes\n---\n", to: skills.appendingPathComponent("release-notes/SKILL.md"))
            _ = try await h.connection.call(UIOpen.self, .init(target: .skill(name: "release-notes")))
        }
    }
}
