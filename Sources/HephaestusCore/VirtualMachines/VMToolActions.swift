import Foundation

/// The key of `vm_key` (docs/mcp.md › vm_key): the shortcut notation of docs/chats.md › Shortcut
/// notation, read as the key and the modifiers of the agent's `key` request.
enum VMKeyNotation {
    /// The agent's names of the keys the notation writes with a symbol or a word.
    static let namedKeys: [String: String] = [
        "↩": "return", "⌤": "enter", "⎋": "escape", "⇥": "tab", KeyShortcut.space: "space", "⌫": "delete", "⌦": "forwardDelete",
        "←": "left", "→": "right", "↑": "up", "↓": "down", "↖": "home", "↘": "end", "⇞": "pageUp", "⇟": "pageDown",
    ]

    static let modifierNames: [KeyShortcut.Modifier: String] = [.control: "control", .option: "option", .shift: "shift", .command: "command"]

    /// The key and the modifiers of a notation, a lowercase letter read as its uppercase; nil for
    /// any other text.
    static func agentKey(_ notation: String) -> (key: String, modifiers: [String])? {
        var shortcut = KeyShortcut(notation)
        if shortcut == nil, let last = notation.last, last.isLowercase {
            shortcut = KeyShortcut(String(notation.dropLast()) + last.uppercased())
        }
        guard let shortcut else { return nil }
        let key = namedKeys[shortcut.key] ?? shortcut.key.lowercased()
        return (key, shortcut.modifiers.compactMap { modifierNames[$0] })
    }

    static let invalidMessage = "key: use the macOS menu notation, for example ⇧⌘K."
}

/// A path in the guest for the commands of `exec`: quoted for `/bin/zsh`, a leading `~/` read as
/// the account's home folder.
enum GuestShell {
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func path(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return quote(path) }
        return "\"$HOME\"/" + quote(String(path.dropFirst(2)))
    }

    /// Absolute, or starting with `~/`.
    static func isGuestPath(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~/")
    }
}

extension JSONValue {
    /// An integer of a result of the agent, written as an integer or a number.
    var vmIntValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return value.isFinite ? Int(value) : nil
        default: return nil
        }
    }

    var vmBoolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

extension Engine {
    // MARK: vmTools.screenshot

    func vmToolScreenshot(_ params: VMToolMachineParams, _ actor: Actor) async throws -> VMScreenshot {
        _ = try vmToolChat(params.chatID, actor)
        let folder = dataDirectory.screenshotsFolder
        return try await runVMAction(params.vmID) { engine in
            let (machine, session) = try await engine.vmActionSession(params.vmID)
            let response = try await engine.vmAgentRequest(session, machine, "screenshot")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
            let file = folder.appendingPathComponent("vm-\(params.vmID.uuidString)-\(formatter.string(from: Date())).png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try response.data.write(to: file, options: .atomic)
            } catch {
                throw EngineError(.internal, "The screenshot could not be written: \(Self.withoutFinalPeriod(error.localizedDescription)).")
            }
            return VMScreenshot(path: file.path, width: response.result["width"]?.vmIntValue ?? 0,
                                height: response.result["height"]?.vmIntValue ?? 0)
        }
    }

    // MARK: vmTools.click, drag, scroll, type, key

    func vmToolClick(_ params: VMToolsClick.Params, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        try Self.requirePoint(params.x, params.y)
        let button = params.button ?? "left"
        guard ["left", "right"].contains(button) else {
            throw EngineError.invalid("button", "use left or right")
        }
        let count = params.count ?? 1
        guard (1...3).contains(count) else {
            throw EngineError.invalid("count", "use a number from 1 to 3")
        }
        return try await simpleVMAction(params.vmID, "click",
                                        ["x": .int(params.x), "y": .int(params.y), "button": .string(button), "count": .int(count)])
    }

    func vmToolDrag(_ params: VMToolsDrag.Params, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        try Self.requirePoint(params.fromX, params.fromY, x: "fromX", y: "fromY")
        try Self.requirePoint(params.toX, params.toY, x: "toX", y: "toY")
        return try await simpleVMAction(params.vmID, "drag", ["fromX": .int(params.fromX), "fromY": .int(params.fromY),
                                                              "toX": .int(params.toX), "toY": .int(params.toY)])
    }

    func vmToolScroll(_ params: VMToolsScroll.Params, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        try Self.requirePoint(params.x, params.y)
        return try await simpleVMAction(params.vmID, "scroll", ["x": .int(params.x), "y": .int(params.y),
                                                                "deltaX": .int(params.deltaX ?? 0), "deltaY": .int(params.deltaY ?? 0)])
    }

    func vmToolType(_ params: VMToolsType.Params, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        return try await simpleVMAction(params.vmID, "type", ["text": .string(params.text)])
    }

    func vmToolKey(_ params: VMToolsKey.Params, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        guard let key = VMKeyNotation.agentKey(params.key) else {
            throw EngineError(.invalid, VMKeyNotation.invalidMessage)
        }
        return try await simpleVMAction(params.vmID, "key", ["key": .string(key.key), "modifiers": .array(key.modifiers.map { .string($0) })])
    }

    /// Coordinates are pixels of the screenshot, from 0.
    private static func requirePoint(_ xValue: Int, _ yValue: Int, x: String = "x", y: String = "y") throws {
        guard xValue >= 0 else { throw EngineError.invalid(x, "use a number of at least 0") }
        guard yValue >= 0 else { throw EngineError.invalid(y, "use a number of at least 0") }
    }

    /// An action of one request whose result is `{}`.
    private func simpleVMAction(_ vmID: UUID, _ method: String, _ requestParams: [String: JSONValue]) async throws -> Empty {
        try await runVMAction(vmID) { engine in
            let (machine, session) = try await engine.vmActionSession(vmID)
            _ = try await engine.vmAgentRequest(session, machine, method, params: requestParams)
            return Empty()
        }
    }

    // MARK: vmTools.uiTree, vmTools.shell

    func vmToolUITree(_ params: VMToolsUITree.Params, _ actor: Actor) async throws -> JSONValue {
        _ = try vmToolChat(params.chatID, actor)
        var requestParams: [String: JSONValue] = [:]
        if let app = params.app {
            requestParams["app"] = .string(app)
        }
        if let maxDepth = params.maxDepth {
            guard (1...100).contains(maxDepth) else {
                throw EngineError.invalid("maxDepth", "use a number from 1 to 100")
            }
            requestParams["maxDepth"] = .int(maxDepth)
        }
        let timeout = vmTools.timings.requestTimeout * 2
        let request = requestParams
        return try await runVMAction(params.vmID) { engine in
            let (machine, session) = try await engine.vmActionSession(params.vmID)
            let response = try await engine.vmAgentRequest(session, machine, "uiTree", params: request, timeout: timeout)
            return .object(response.result)
        }
    }

    func vmToolShell(_ params: VMToolsShell.Params, _ actor: Actor) async throws -> VMShellResult {
        _ = try vmToolChat(params.chatID, actor)
        let timeout = params.timeout ?? 60
        guard (1...1800).contains(timeout) else {
            throw EngineError.invalid("timeout", "use a number from 1 to 1800")
        }
        let margin = vmTools.timings.execMargin
        return try await runVMAction(params.vmID) { engine in
            let (machine, session) = try await engine.vmActionSession(params.vmID)
            return try await engine.vmExec(session, machine, params.command, asRoot: params.asRoot ?? false, timeout: timeout,
                                           margin: margin)
        }
    }

    /// The agent's `exec`, its result read as a `VMShellResult`.
    func vmExec(_ session: VMSession, _ machine: VirtualMachine, _ command: String, asRoot: Bool = false, timeout: Int = 60,
                margin: Duration) async throws -> VMShellResult {
        let response = try await vmAgentRequest(session, machine, "exec",
                                                params: ["command": .string(command), "asRoot": .bool(asRoot), "timeout": .int(timeout)],
                                                timeout: .seconds(timeout) + margin)
        let result = response.result
        return VMShellResult(exitStatus: result["exitStatus"]?.vmIntValue ?? -1, timedOut: result["timedOut"]?.vmBoolValue ?? false,
                             stdout: result["stdout"]?.stringValue ?? "", stderr: result["stderr"]?.stringValue ?? "",
                             truncated: result["truncated"]?.vmBoolValue ?? false)
    }

    // MARK: vmTools.copyIn, vmTools.copyOut (docs/mcp.md › vm_copy_in, › vm_copy_out)

    func vmToolCopyIn(_ params: VMToolCopyParams, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        guard params.source.hasPrefix("/") else {
            throw EngineError.invalid("source", "use an absolute path or a path starting with ~/")
        }
        guard GuestShell.isGuestPath(params.destination) else {
            throw EngineError.invalid("destination", "use an absolute path or a path starting with ~/")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: params.source, isDirectory: &isDirectory) else {
            throw EngineError(.notFound, "File \(params.source) not found.")
        }
        let folder = isDirectory.boolValue
        let margin = vmTools.timings.execMargin
        return try await runVMAction(params.vmID) { engine in
            let (machine, session) = try await engine.vmActionSession(params.vmID)
            if folder {
                try await engine.copyFolderIn(params.source, to: params.destination, session, machine, margin: margin)
            } else {
                try await engine.copyFileIn(URL(fileURLWithPath: params.source), to: params.destination, session, machine)
            }
            return Empty()
        }
    }

    func vmToolCopyOut(_ params: VMToolCopyParams, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        guard GuestShell.isGuestPath(params.source) else {
            throw EngineError.invalid("source", "use an absolute path or a path starting with ~/")
        }
        guard params.destination.hasPrefix("/") else {
            throw EngineError.invalid("destination", "use an absolute path or a path starting with ~/")
        }
        let margin = vmTools.timings.execMargin
        return try await runVMAction(params.vmID) { engine in
            let (machine, session) = try await engine.vmActionSession(params.vmID)
            let stat = try await engine.vmAgentRequest(session, machine, "stat", params: ["path": .string(params.source)]).result
            guard stat["exists"]?.vmBoolValue == true else {
                throw EngineError(.notFound, "\(params.source) does not exist in the guest.")
            }
            let destination = URL(fileURLWithPath: params.destination)
            if stat["isDirectory"]?.vmBoolValue == true {
                try await engine.copyFolderOut(params.source, to: destination, session, machine, margin: margin)
            } else {
                try await engine.copyFileOut(params.source, to: destination, mode: stat["mode"]?.vmIntValue, session, machine)
            }
            return Empty()
        }
    }

    /// Writes a file of this Mac to `destination` in the guest, 8 MiB at a time, with its
    /// permission bits.
    private func copyFileIn(_ source: URL, to destination: String, _ session: VMSession, _ machine: VirtualMachine) async throws {
        let handle: FileHandle
        let mode: Int?
        do {
            handle = try FileHandle(forReadingFrom: source)
            mode = (try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue
        } catch {
            throw EngineError(.internal, "\(source.path) cannot be read: \(Self.withoutFinalPeriod(error.localizedDescription)).")
        }
        defer { try? handle.close() }
        var offset = 0
        repeat {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: VMToolService.chunkSize) ?? Data()
            } catch {
                throw EngineError(.internal, "\(source.path) cannot be read: \(Self.withoutFinalPeriod(error.localizedDescription)).")
            }
            if chunk.isEmpty, offset > 0 { break }
            var requestParams: [String: JSONValue] = ["path": .string(destination), "offset": .int(offset)]
            if offset == 0 {
                requestParams["truncate"] = .bool(true)
                if let mode {
                    requestParams["mode"] = .int(mode & 0o7777)
                }
            }
            _ = try await vmAgentRequest(session, machine, "writeFile", params: requestParams, data: chunk)
            offset += chunk.count
            if chunk.count < VMToolService.chunkSize { break }
        } while true
    }

    /// Copies the content of a folder of this Mac into the folder `destination` of the guest,
    /// through a tar archive.
    private func copyFolderIn(_ source: String, to destination: String, _ session: VMSession, _ machine: VirtualMachine,
                              margin: Duration) async throws {
        let archive = try Self.localArchiveFile()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        try await runLocalTar(["-c", "-f", archive.path, "-C", source, "."])
        let guestArchive = "/tmp/hephaestus-copy-\(UUID().uuidString).tar"
        try await copyFileIn(archive, to: guestArchive, session, machine)
        let target = GuestShell.path(destination)
        let command = "/bin/mkdir -p \(target) && /usr/bin/tar -x -p -f \(GuestShell.quote(guestArchive)) -C \(target); "
            + "status=$?; /bin/rm -f \(GuestShell.quote(guestArchive)); exit $status"
        let result = try await vmExec(session, machine, command, timeout: 1800, margin: margin)
        try Self.requireTarSuccess(result)
    }

    /// Reads a file of the guest into `destination` on this Mac, 8 MiB at a time, through a file
    /// beside it that then takes its place.
    private func copyFileOut(_ source: String, to destination: URL, mode: Int?, _ session: VMSession,
                             _ machine: VirtualMachine) async throws {
        let manager = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: partial)
        } catch {
            throw Self.cannotWrite(destination, error)
        }
        var completed = false
        defer {
            if !completed { try? manager.removeItem(at: partial) }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            throw Self.cannotWrite(destination, error)
        }
        defer { try? handle.close() }
        var offset = 0
        while true {
            let response = try await vmAgentRequest(session, machine, "readFile",
                                                    params: ["path": .string(source), "offset": .int(offset), "length": .int(VMToolService.chunkSize)])
            do {
                try handle.write(contentsOf: response.data)
            } catch {
                throw Self.cannotWrite(destination, error)
            }
            offset += response.data.count
            if response.result["eof"]?.vmBoolValue != false || response.data.isEmpty { break }
        }
        do {
            try handle.close()
            if let mode {
                try manager.setAttributes([.posixPermissions: mode & 0o7777], ofItemAtPath: partial.path)
            }
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try manager.moveItem(at: partial, to: destination)
            }
            completed = true
        } catch {
            throw Self.cannotWrite(destination, error)
        }
    }

    /// Copies the content of a folder of the guest into the folder `destination` of this Mac,
    /// through a tar archive.
    private func copyFolderOut(_ source: String, to destination: URL, _ session: VMSession, _ machine: VirtualMachine,
                               margin: Duration) async throws {
        let guestArchive = "/tmp/hephaestus-copy-\(UUID().uuidString).tar"
        let quoted = GuestShell.quote(guestArchive)
        let create = "/usr/bin/tar -c -f \(quoted) -C \(GuestShell.path(source)) .; status=$?; "
            + "[ $status -eq 0 ] || /bin/rm -f \(quoted); exit $status"
        try Self.requireTarSuccess(try await vmExec(session, machine, create, timeout: 1800, margin: margin))
        let archive = try Self.localArchiveFile()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        do {
            try await copyFileOut(guestArchive, to: archive, mode: nil, session, machine)
        } catch {
            _ = try? await vmExec(session, machine, "/bin/rm -f \(quoted)", margin: margin)
            throw error
        }
        _ = try await vmExec(session, machine, "/bin/rm -f \(quoted)", margin: margin)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw Self.cannotWrite(destination, error)
        }
        try await runLocalTar(["-x", "-p", "-f", archive.path, "-C", destination.path])
    }

    /// A new file name for an archive, in a folder of its own under the temporary folder.
    private static func localArchiveFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephaestusV2/VMCopies/\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw cannotWrite(folder, error)
        }
        return folder.appendingPathComponent("copy.tar")
    }

    /// `/usr/bin/tar` on this Mac, with the environment of the child processes and a timeout of
    /// 30 minutes (docs/architecture.md › Child processes); a non-zero exit fails with
    /// `unavailable`.
    private func runLocalTar(_ arguments: [String]) async throws {
        let request = ChildProcessRequest(executable: "/usr/bin/tar", arguments: arguments, environment: await childProcessEnvironment())
        let result: ProcessResult
        do {
            result = try await ChildProcessRunner.run(request, timeout: .seconds(1800))
        } catch {
            throw EngineError(.internal, "tar could not be started: \(error).")
        }
        let status: Int
        switch result.termination {
        case .exited(let code): status = Int(code)
        case .signaled(let signal): status = 128 + Int(signal)
        }
        try Self.requireTarSuccess(VMShellResult(exitStatus: status, timedOut: false, stdout: result.standardOutputText,
                                            stderr: result.standardErrorText, truncated: false))
    }

    /// `tar exited with code <n>: <standard error>.` for a tar that failed.
    private static func requireTarSuccess(_ result: VMShellResult) throws {
        guard result.exitStatus != 0 else { return }
        let errors = withoutFinalPeriod(result.stderr.split(whereSeparator: \.isNewline).joined(separator: " "))
        throw EngineError(.unavailable, errors.isEmpty ? "tar exited with code \(result.exitStatus)."
                                                       : "tar exited with code \(result.exitStatus): \(errors).")
    }

    private static func cannotWrite(_ url: URL, _ error: Error) -> EngineError {
        EngineError(.internal, "\(url.path) cannot be written: \(withoutFinalPeriod(error.localizedDescription)).")
    }
}
