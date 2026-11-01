import Darwin
import Foundation

/// The Claude process of each chat: delivery of user messages, launch, output mapping, the
/// control protocol, permission prompts, turns, Stop, idle termination, exits and the app quit
/// (docs/chats.md › Chat process, › Control protocol, › Output mapping, › Permission prompts).
extension Engine {
    // MARK: Delivery

    /// Delivers a user message line: written at once to the live process (during a turn the CLI
    /// runs it after the current turn), otherwise kept for a new process, launched now or when
    /// the ending process has exited (docs/chats.md › Chat states).
    func deliverChatMessage(_ chatID: ChatID, line: Data) {
        let runtime = chats.runtime(chatID)
        runtime.idleTask?.cancel()
        runtime.idleTask = nil
        runtime.error = false
        runtime.turnInProgress = true
        if let process = runtime.liveProcess, !process.handle.hasExited {
            process.handle.write(line)
            if !process.sawInit { process.messagesBeforeInit.append(line) }
            return
        }
        runtime.pendingMessages.append(line)
        runtime.starting = true
        if runtime.process == nil, !runtime.launching, !runtime.cleaningUp {
            startChatLaunch(chatID)
        }
    }

    private func startChatLaunch(_ chatID: ChatID) {
        let runtime = chats.runtime(chatID)
        runtime.launching = true
        Task { await self.launchChatProcess(chatID) }
    }

    // MARK: Launch

    /// docs/chats.md › Launch: settings, MCP configuration file and skills plugin, system prompt,
    /// spawn in the project root with the Claude environment, then the `initialize` request and
    /// the user messages without waiting; the state is starting until `system/init`.
    private func launchChatProcess(_ chatID: ChatID) async {
        let runtime = chats.runtime(chatID)
        var context: ClaudeLaunchContext?
        var unavailable: String?
        do {
            context = try await requireClaudeCLI()
        } catch {
            unavailable = (error as? EngineError)?.message ?? String(describing: error)
        }
        let mcpState = await mcpServer.state
        let token = context == nil ? nil : await tokens.issueChatToken(chatID: chatID)

        func abandon() async {
            if token != nil { await tokens.revokeChatToken(chatID: chatID) }
            runtime.launching = false
        }
        guard !chats.stopped, !chats.deleting.contains(chatID), chats.runtimes[chatID] === runtime else {
            await abandon()
            return
        }
        guard !runtime.pendingMessages.isEmpty else {
            await abandon()
            runtime.starting = false
            reportChatState(chatID)
            return
        }
        guard let context, let token else {
            await abandon()
            launchFailed(chatID, "Claude failed to start: \(unavailable ?? "the Claude CLI is not available")")
            return
        }
        guard let meta = domain.chat(chatID), let root = domain.projectRoot(meta.projectID), let project = domain.project(meta.projectID) else {
            await abandon()
            launchFailed(chatID, "Claude failed to start: the chat's project is not loaded.")
            return
        }
        runtime.projectID = meta.projectID
        let items = (try? loadTranscript(chatID)) ?? []

        let port: Int
        if case .listening(let listening) = mcpState { port = listening } else { port = effectiveMCPPort }
        let configURL = dataDirectory.mcpConfigFile(chatID: chatID)
        do {
            try AtomicFile.write(ClaudeCommandLine.mcpConfiguration(port: port, token: token), to: configURL,
                                 newFileMode: AtomicFile.privateMode)
        } catch {
            await abandon()
            launchFailed(chatID, "Claude failed to start: \(error)")
            return
        }
        var pluginDirectory: String?
        do {
            let folder = try skillsPlugins.preparePlugin(projectID: project.id, skills: project.skills, library: skillsLibraryFolder,
                                                         dataDirectory: dataDirectory)
            if FileManager.default.fileExists(atPath: folder.path) { pluginDirectory = folder.path }
        } catch {
            addSystemItem("Skills could not be prepared: \(Engine.message(of: error))", level: .warning, chatID: chatID)
        }
        if case .failed(let message) = mcpState {
            addSystemItem("Hephaestus MCP server unavailable: \(message)", level: .warning, chatID: chatID)
        }
        let systemPrompt = chatSystemPrompt(meta: meta, project: project, root: root, items: items)
        let argv = ClaudeCommandLine.chat(cliPath: context.path, chatID: chatID, sessionStarted: meta.sessionStarted, settings: meta.settings,
                                          mcpConfigPath: configURL.path, systemPrompt: systemPrompt, pluginDirectory: pluginDirectory)
        let logFile = AppendFile(url: dataDirectory.claudeLogFile(chatID: chatID), emptyAbove: AppendFile.rotationSize)
        logFile.appendLine(ClaudeCommandLine.launchLogLine(argv: argv, date: Date()))
        let request = ChildProcessRequest(executable: argv[0], arguments: Array(argv.dropFirst()), environment: context.environment,
                                          currentDirectory: root.path)
        let handle: any ClaudeProcess
        do {
            handle = try configuration.claudeLauncher.start(request)
        } catch {
            logFile.appendLine("launch failed: \(error)")
            logFile.close()
            try? FileManager.default.removeItem(at: configURL)
            await abandon()
            launchFailed(chatID, "Claude failed to start: \(error)")
            return
        }

        chats.nextGeneration += 1
        let capture = configuration.debugTools ? AppendFile(url: dataDirectory.claudeStdoutCaptureFile(chatID: chatID)) : nil
        let process = ChatProcess(handle: handle, generation: chats.nextGeneration, resumed: meta.sessionStarted, mcpPort: port,
                                  mapper: StreamMapper(settings: meta.settings, models: claudeCLI.cachedModels),
                                  log: logFile, stdoutCapture: capture)
        runtime.process = process
        runtime.launching = false
        runtime.starting = true
        log.info(.claude, "chat \(chatID.uuidString): Claude started (\(meta.sessionStarted ? "resume" : "new session"))")
        sendControlRequest(.initialize, chatID: chatID, process: process) { ControlLines.request(id: $0, subtype: "initialize") }
        for line in runtime.pendingMessages { handle.write(line) }
        process.messagesBeforeInit = runtime.pendingMessages
        runtime.pendingMessages = []
        startChatReaders(chatID, process)
        let generation = process.generation
        let startTimeout = chats.timings.startTimeout
        process.initTimer = Task {
            try? await Task.sleep(for: startTimeout)
            guard !Task.isCancelled else { return }
            self.chatStartTimedOut(chatID, generation: generation)
        }
        reportChatState(chatID)
    }

    /// The spawn failed (Launch, step 8): the error item, state error.
    private func launchFailed(_ chatID: ChatID, _ text: String) {
        let runtime = chats.runtime(chatID)
        runtime.pendingMessages = []
        runtime.starting = false
        runtime.turnInProgress = false
        runtime.error = true
        log.warn(.claude, "chat \(chatID.uuidString): \(text)")
        addSystemItem(text, level: .error, chatID: chatID)
        reportChatState(chatID)
    }

    static func message(of error: Error) -> String {
        if let error = error as? EngineError { return error.message }
        if let error = error as? StorageError { return error.description }
        return error.localizedDescription
    }

    private func startChatReaders(_ chatID: ChatID, _ process: ChatProcess) {
        let handle = process.handle
        let generation = process.generation
        let stderr = process.stderr
        let logFile = process.log
        Task.detached {
            for await chunk in handle.errorOutput {
                logFile.append(chunk)
                stderr.append(chunk)
            }
            stderr.finished.open()
        }
        let stdoutFinished = process.stdoutFinished
        Task {
            for await line in handle.outputLines {
                self.chatOutputLine(chatID, generation: generation, line)
            }
            stdoutFinished.open()
        }
        let grace = chats.timings.outputGrace
        Task {
            let termination = await handle.waitForExit()
            await stdoutFinished.wait(atMost: grace)
            await stderr.finished.wait(atMost: grace)
            await self.chatProcessExited(chatID, generation: generation, termination: termination)
        }
    }

    /// No `system/init` within 60 s (Launch, step 7): SIGTERM, SIGKILL 5 s later, the error item,
    /// state error.
    private func chatStartTimedOut(_ chatID: ChatID, generation: Int) {
        guard let runtime = chats.runtimes[chatID], let process = runtime.process, process.generation == generation,
              !process.sawInit, !process.exited
        else { return }
        log.warn(.claude, "chat \(chatID.uuidString): no system/init within the start timeout")
        terminateChatProcess(process)
        addSystemItem("Claude did not start within 60 seconds.", level: .error, chatID: chatID)
        runtime.error = true
        runtime.starting = false
        runtime.turnInProgress = false
        reportChatState(chatID)
    }

    // MARK: Output

    /// One stdout line of a chat process (docs/chats.md › Output mapping). Lines of a process that
    /// is no longer the chat's, or of a chat being deleted, are ignored.
    private func chatOutputLine(_ chatID: ChatID, generation: Int, _ line: ClaudeOutputLine) {
        guard !chats.deleting.contains(chatID), let runtime = chats.runtimes[chatID], let process = runtime.process,
              process.generation == generation, !process.exited
        else { return }
        switch line {
        case .tooLong(let length):
            process.log.appendLine("skipped a stdout line of \(length) bytes")
            log.warn(.claude, "chat \(chatID.uuidString): skipped a stdout line of \(length) bytes")
        case .line(let data):
            if let capture = process.stdoutCapture {
                capture.append(data + Data([0x0A]))
            }
            for output in process.mapper.map(data) {
                handleChatOutput(output, chatID: chatID, runtime: runtime, process: process)
            }
        }
    }

    private func handleChatOutput(_ output: MapperOutput, chatID: ChatID, runtime: ChatRuntime, process: ChatProcess) {
        switch output {
        case .item(let item):
            appendChatItemLogging(item, chatID: chatID)
        case .toolResult(var item, let images):
            if !images.isEmpty, let meta = domain.chat(chatID), let folder = try? chatFolder(meta) {
                for (offset, image) in images.enumerated() {
                    guard let data = Data(base64Encoded: image.base64) else {
                        log.warn(.claude, "chat \(chatID.uuidString): a tool result image is not valid base64")
                        continue
                    }
                    let name = "image-\(offset + 1).\(ChatAttachments.imageExtension(image.mediaType))"
                    do {
                        item.images.append(try ChatAttachments.store(name: name, contentType: image.mediaType, data: data, chatID: chatID,
                                                                     folder: folder, ownWrites: ownWrites))
                    } catch {
                        log.error(.claude, "chat \(chatID.uuidString): a tool result image cannot be stored: \(error)")
                    }
                }
            }
            appendChatItemLogging(.toolResult(item), chatID: chatID)
        case .sessionStarted:
            process.sawInit = true
            process.initTimer?.cancel()
            process.messagesBeforeInit = []
            runtime.starting = false
            runtime.sessionRetried = false
            if var meta = domain.chat(chatID), !meta.sessionStarted {
                meta.sessionStarted = true
                saveChatMetaLogging(meta, origin: .system)
            } else {
                reportChatState(chatID)
            }
        case .permissionModeReported(let mode):
            applyCLIPermissionMode(mode, chatID: chatID, process: process)
        case .delta(let itemID, let kind, let text):
            runtime.deltas.append(itemID: itemID, kind: kind, text: text)
            scheduleDeltaFlush(chatID)
        case .permissionRequest(let item, let suggestions):
            guard process.permissions[item.requestID] == nil else { return }
            process.permissions[item.requestID] = PendingPermission(item: item, suggestions: suggestions)
            process.permissionOrder.append(item.requestID)
            appendChatItemLogging(.permissionRequest(item), chatID: chatID)
            reportChatState(chatID)
        case .unsupportedControlRequest(let requestID, let subtype):
            process.log.appendLine("unsupported control request \(subtype)")
            process.handle.write(ControlLines.unsupportedAnswer(requestID: requestID, subtype: subtype))
        case .controlResponse(let requestID, let success, let response, let error):
            controlResponseReceived(requestID: requestID, success: success, response: response, error: error, chatID: chatID, process: process)
        case .cancelRequest(let requestID):
            guard let pending = process.permissions[requestID] else { return }
            resolvePermission(pending, decision: .deny, decidedBy: nil, chatID: chatID, process: process, origin: .system)
            reportChatState(chatID)
        case .result(let item, let endsTurn):
            clearDeltas(runtime)
            appendChatItemLogging(.result(item), chatID: chatID)
            if endsTurn { chatTurnEnded(chatID, runtime: runtime, process: process) }
        case .ignored(let text):
            process.log.appendLine(text)
        case .invalid(let reason):
            process.log.appendLine("skipped a stdout line: \(reason)")
        }
    }

    // MARK: Streaming

    /// docs/chats.md › Streaming, flush: at most every 50 ms per chat, one `chat.delta` with the
    /// pending text of the block whose buffer is the oldest.
    private func scheduleDeltaFlush(_ chatID: ChatID) {
        guard let runtime = chats.runtimes[chatID], runtime.deltaTask == nil, !runtime.deltas.isEmpty else { return }
        let now = ContinuousClock.now
        let earliest = runtime.lastDeltaFlush.map { $0 + chats.timings.deltaInterval } ?? now
        if earliest <= now {
            flushDelta(chatID)
            return
        }
        runtime.deltaTask = Task {
            try? await Task.sleep(until: earliest, clock: .continuous)
            guard !Task.isCancelled else { return }
            runtime.deltaTask = nil
            self.flushDelta(chatID)
        }
    }

    private func flushDelta(_ chatID: ChatID) {
        guard !chats.deleting.contains(chatID), let runtime = chats.runtimes[chatID], let pending = runtime.deltas.takeOldest() else { return }
        runtime.lastDeltaFlush = .now
        emit(ChatDeltaEvent.self, .init(chatID: chatID, itemID: pending.itemID, kind: pending.kind, append: pending.text), origin: .system)
        scheduleDeltaFlush(chatID)
    }

    private func clearDeltas(_ runtime: ChatRuntime) {
        runtime.deltaTask?.cancel()
        runtime.deltaTask = nil
        runtime.deltas = DeltaBuffer()
    }

    // MARK: Turns

    /// A `result` with `queued_turn_count` 0 or absent ends the turn: the metadata is written, the
    /// idle timer starts, or the process ends when an `mcpPort` change waits for the turn.
    private func chatTurnEnded(_ chatID: ChatID, runtime: ChatRuntime, process: ChatProcess) {
        runtime.turnInProgress = false
        runtime.starting = false
        process.stopRequested = false
        process.stopTask?.cancel()
        process.stopTask = nil
        if let meta = domain.chat(chatID) {
            saveChatMetaLogging(meta, origin: .system)
        }
        if process.terminateAfterTurn {
            terminateChatProcess(process)
        } else {
            startIdleTimer(chatID, process: process)
        }
    }

    /// docs/chats.md › Idle termination: 20 minutes after a turn ends, standard input is closed,
    /// SIGTERM follows 5 s later when the process is alive, SIGKILL 5 s after that.
    private func startIdleTimer(_ chatID: ChatID, process: ChatProcess) {
        guard let runtime = chats.runtimes[chatID] else { return }
        runtime.idleTask?.cancel()
        let timeout = chats.timings.idleTimeout
        let grace = chats.timings.idleCloseGrace
        let generation = process.generation
        runtime.idleTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let current = self.chats.runtimes[chatID]?.process, current.generation == generation,
                  !current.exited, self.chats.runtimes[chatID]?.turnInProgress == false
            else { return }
            self.log.info(.claude, "chat \(chatID.uuidString): idle termination")
            current.terminatedByEngine = true
            let handle = current.handle
            handle.closeInput()
            current.terminationTask = Task.detached {
                try? await Task.sleep(for: grace)
                guard !handle.hasExited else { return }
                handle.signalGroup(SIGTERM)
                try? await Task.sleep(for: grace)
                guard !handle.hasExited else { return }
                handle.signalGroup(SIGKILL)
            }
        }
    }

    /// A termination by the engine: SIGTERM, SIGKILL `terminateGrace` later (docs/chats.md ›
    /// Signals). The exit adds no error item.
    func terminateChatProcess(_ process: ChatProcess) {
        process.terminatedByEngine = true
        let handle = process.handle
        guard !handle.hasExited else { return }
        handle.signalGroup(SIGTERM)
        let grace = chats.timings.terminateGrace
        process.terminationTask = Task.detached {
            try? await Task.sleep(for: grace)
            guard !handle.hasExited else { return }
            handle.signalGroup(SIGKILL)
        }
    }

    // MARK: Control protocol

    /// Writes a control request with the process's next id and forgets it after 30 s without an
    /// answer; for a setting, the warning item is added with the description `no answer`.
    private func sendControlRequest(_ purpose: ControlPurpose, chatID: ChatID, process: ChatProcess, line: (String) -> Data) {
        let id = process.takeRequestID()
        process.handle.write(line(id))
        let timeout = chats.timings.controlRequestTimeout
        let generation = process.generation
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.controlRequestTimedOut(id, chatID: chatID, generation: generation)
        }
        process.pendingControl[id] = (purpose, timer)
    }

    private func controlRequestTimedOut(_ requestID: String, chatID: ChatID, generation: Int) {
        guard let process = chats.runtimes[chatID]?.process, process.generation == generation, !process.exited,
              let entry = process.pendingControl.removeValue(forKey: requestID)
        else { return }
        process.log.appendLine("control request \(requestID) got no answer")
        log.warn(.claude, "chat \(chatID.uuidString): control request \(requestID) got no answer")
        if let name = entry.purpose.settingName {
            addSystemItem(Engine.refusedSettingText(name, "no answer"), level: .warning, chatID: chatID)
        }
    }

    static func refusedSettingText(_ setting: String, _ description: String) -> String {
        var description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        while description.hasSuffix(".") { description.removeLast() }
        return "Claude did not accept the new \(setting) setting now: \(description). It applies the next time Claude starts."
    }

    private func controlResponseReceived(requestID: String, success: Bool, response: JSONValue?, error: String?, chatID: ChatID,
                                         process: ChatProcess) {
        guard let entry = process.pendingControl.removeValue(forKey: requestID) else {
            process.log.appendLine("control response to an unknown request \(requestID)")
            return
        }
        entry.timer?.cancel()
        if success {
            if entry.purpose == .initialize, let models = CachedModel.parse(response?.objectValue?["models"]) {
                receivedInitializeModels(models)
                process.mapper.models = claudeCLI.cachedModels
            }
            return
        }
        let description = error ?? "unknown error"
        process.log.appendLine("control request \(requestID) failed: \(description)")
        if let name = entry.purpose.settingName {
            addSystemItem(Engine.refusedSettingText(name, description), level: .warning, chatID: chatID)
        } else {
            log.warn(.claude, "chat \(chatID.uuidString): control request \(requestID) failed")
        }
    }

    /// docs/chats.md › Changing settings: one control request per changed field while the chat
    /// has a live process, during a turn as well.
    func applyChatSettingsLive(_ chatID: ChatID, old: ChatSettings, new: ChatSettings) {
        guard let process = chats.runtimes[chatID]?.liveProcess else { return }
        process.mapper.settings = new
        if old.model != new.model {
            sendControlRequest(.model, chatID: chatID, process: process) { ControlLines.setModel(id: $0, model: new.model) }
        }
        if old.permissionMode != new.permissionMode {
            sendControlRequest(.permissionMode, chatID: chatID, process: process) {
                ControlLines.setPermissionMode(id: $0, mode: ControlLines.cliMode(new.permissionMode))
            }
        }
        if old.effort != new.effort {
            sendControlRequest(.effort, chatID: chatID, process: process) { ControlLines.applyEffort(id: $0, effort: new.effort) }
        }
        if old.ultracode != new.ultracode {
            sendControlRequest(.ultracode, chatID: chatID, process: process) { ControlLines.applyUltracode(id: $0, on: new.ultracode) }
        }
    }

    /// docs/chats.md › Mode changes made by the CLI: a mode that differs from the stored one is
    /// stored (`default` as `manual`) with `chat.updated`.
    private func applyCLIPermissionMode(_ cliValue: String, chatID: ChatID, process: ChatProcess) {
        guard let mode = ControlLines.storedMode(cliValue) else {
            process.log.appendLine("unknown permission mode \(cliValue)")
            return
        }
        guard var meta = domain.chat(chatID), meta.settings.permissionMode != mode else { return }
        meta.settings.permissionMode = mode
        process.mapper.settings.permissionMode = mode
        saveChatMetaLogging(meta, origin: .system)
    }

    // MARK: Permissions

    /// Records a decision: the item is replaced with `decision` and `decidedBy`, and the request
    /// is no longer pending.
    private func resolvePermission(_ pending: PendingPermission, decision: PermissionDecision, decidedBy: String?, chatID: ChatID,
                                   process: ChatProcess, origin: Actor) {
        var item = pending.item
        item.decision = decision
        item.decidedBy = decidedBy
        process.permissions[item.requestID] = nil
        process.permissionOrder.removeAll { $0 == item.requestID }
        appendChatItemLogging(.permissionRequest(item), chatID: chatID, op: .update, origin: origin)
    }

    /// docs/chats.md › Answer: writes the answer line and replaces the item; a request that is not
    /// pending fails with `conflict` when the transcript holds it, else `notFound`.
    func answerChatPermission(_ chatID: ChatID, requestID: String, decision: PermissionDecision, message: String?, deviceName: String,
                              origin: Actor) throws {
        if let process = chats.runtimes[chatID]?.process, !process.exited, let pending = process.permissions[requestID] {
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = trimmed.isEmpty ? "Permission denied by the user." : trimmed
            process.handle.write(ControlLines.permissionAnswer(requestID: requestID, decision: decision, input: pending.item.input,
                                                               suggestions: pending.suggestions, message: text))
            resolvePermission(pending, decision: decision, decidedBy: deviceName, chatID: chatID, process: process, origin: origin)
            if decision == .allowAlways, let suggestions = pending.suggestions?.arrayValue, !suggestions.isEmpty,
               let mode = suggestions.compactMap(\.objectValue).last(where: { $0["type"]?.stringValue == "setMode" })?["mode"]?.stringValue {
                applyCLIPermissionMode(mode, chatID: chatID, process: process)
            }
            emitChatUpdated(chatID, origin: origin)
            return
        }
        let items = try loadTranscript(chatID)
        let known = items.contains { item in
            if case .permissionRequest(let request) = item { return request.requestID == requestID }
            return false
        }
        if known {
            throw EngineError(.conflict, "This permission request was already answered.")
        }
        throw EngineError.notFound("Permission request", requestID)
    }

    // MARK: Stop

    /// docs/chats.md › Stopping a turn: pending requests denied with `The user stopped Claude.`,
    /// the `Stopped by` item, the `interrupt` request, then SIGINT, SIGTERM and SIGKILL 5 s apart
    /// while the turn goes on. Nothing happens in the states idle, waitingAnswers and error.
    func interruptChat(_ chatID: ChatID, deviceName: String, origin: Actor) {
        guard [.starting, .running, .waitingPermission].contains(chats.state(of: chatID)) else { return }
        let runtime = chats.runtime(chatID)
        if let process = runtime.process, !process.exited {
            for requestID in process.permissionOrder {
                guard let pending = process.permissions[requestID] else { continue }
                process.handle.write(ControlLines.permissionAnswer(requestID: requestID, decision: .deny, input: pending.item.input,
                                                                   suggestions: nil, message: "The user stopped Claude."))
                resolvePermission(pending, decision: .deny, decidedBy: deviceName, chatID: chatID, process: process, origin: origin)
            }
        }
        addSystemItem("Stopped by \(deviceName).", level: .info, chatID: chatID, origin: origin)
        if let process = runtime.liveProcess, !process.handle.hasExited {
            sendControlRequest(.interrupt, chatID: chatID, process: process) { ControlLines.request(id: $0, subtype: "interrupt") }
            process.stopRequested = true
            let handle = process.handle
            let step = chats.timings.stopStep
            process.stopTask?.cancel()
            process.stopTask = Task {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled, !handle.hasExited, runtime.process === process, runtime.turnInProgress || runtime.starting else {
                    return
                }
                handle.signalGroup(SIGINT)
                Task.detached {
                    try? await Task.sleep(for: step)
                    guard !handle.hasExited else { return }
                    handle.signalGroup(SIGTERM)
                    try? await Task.sleep(for: step)
                    guard !handle.hasExited else { return }
                    handle.signalGroup(SIGKILL)
                }
            }
        } else if runtime.process == nil {
            // DOC-GAP: docs/chats.md › Stopping a turn assumes a process; while the launch has not
            // started it yet, the messages waiting for it are dropped and the chat is idle.
            runtime.pendingMessages = []
            runtime.starting = false
            runtime.turnInProgress = false
        }
        emitChatUpdated(chatID, origin: origin)
    }

    // MARK: Exit

    /// docs/chats.md › Exit handling and logs: the open blocks are finalized, the pending
    /// permission requests cancelled, the error item added for an unexpected non-zero exit during
    /// a turn, the session retried once when it was not found, the token revoked and the MCP
    /// configuration file deleted. Messages delivered while the process ended start a new one.
    func chatProcessExited(_ chatID: ChatID, generation: Int, termination: ProcessTermination) async {
        guard let runtime = chats.runtimes[chatID], let process = runtime.process, process.generation == generation, !process.exited else {
            return
        }
        process.exited = true
        process.cancelTimers()
        runtime.idleTask?.cancel()
        runtime.idleTask = nil
        let deleting = chats.deleting.contains(chatID)
        log.info(.claude, "chat \(chatID.uuidString): Claude ended (\(termination))")
        if !deleting {
            for item in process.mapper.finalize() {
                appendChatItemLogging(item, chatID: chatID)
            }
            clearDeltas(runtime)
            for requestID in process.permissionOrder {
                if let pending = process.permissions[requestID] {
                    resolvePermission(pending, decision: .deny, decidedBy: nil, chatID: chatID, process: process, origin: .system)
                }
            }
            let duringTurn = runtime.starting || runtime.turnInProgress
            let causedByEngine = process.stopRequested || process.terminatedByEngine
            var retry = false
            if process.resumed, !process.sawInit, !causedByEngine, !runtime.sessionRetried, process.stderr.reportedMissingSession,
               var meta = domain.chat(chatID) {
                runtime.sessionRetried = true
                meta.sessionStarted = false
                saveChatMetaLogging(meta, origin: .system)
                addSystemItem("Claude's session for this chat was not found. A new session started; Claude does not remember the earlier "
                              + "messages of this chat.", level: .warning, chatID: chatID)
                runtime.pendingMessages = process.messagesBeforeInit + runtime.pendingMessages
                retry = true
            } else if duringTurn, !causedByEngine, termination != .exited(0) {
                addSystemItem(Engine.exitText(termination, lastLine: process.stderr.lastNonEmptyLine), level: .error, chatID: chatID)
                if runtime.pendingMessages.isEmpty { runtime.error = true }
            }
            if !retry, runtime.pendingMessages.isEmpty {
                runtime.starting = false
                runtime.turnInProgress = false
            }
        }
        runtime.process = nil
        runtime.cleaningUp = true
        if !deleting { reportChatState(chatID) }
        process.log.close()
        process.stdoutCapture?.close()
        await tokens.revokeChatToken(chatID: chatID)
        try? FileManager.default.removeItem(at: dataDirectory.mcpConfigFile(chatID: chatID))
        runtime.cleaningUp = false
        if !deleting, !chats.stopped, !runtime.pendingMessages.isEmpty, runtime.process == nil, !runtime.launching,
           chats.runtimes[chatID] === runtime {
            startChatLaunch(chatID)
        }
    }

    /// The error item of an unexpected exit (docs/chats.md › Exit handling and logs).
    static func exitText(_ termination: ProcessTermination, lastLine: String?) -> String {
        switch termination {
        case .exited(let code):
            if let lastLine, !lastLine.isEmpty { return "Claude exited with code \(code): \(lastLine)" }
            return "Claude exited with code \(code)."
        case .signaled(let signal):
            return "Claude was terminated by signal \(signal)."
        }
    }

    // MARK: Termination by the engine

    /// `projects.remove`, and a project unloaded after an external change: the chat processes of
    /// these projects are terminated, SIGTERM then SIGKILL 5 s later (docs/chats.md › Idle
    /// termination and quitting). Called after the projects left `domain`: the project of each
    /// chat is the one recorded at launch.
    func terminateChatProcesses(inProjects projectIDs: [ProjectID]) {
        let projectIDs = Set(projectIDs)
        for runtime in chats.runtimes.values {
            guard let projectID = runtime.projectID, projectIDs.contains(projectID) else { continue }
            runtime.pendingMessages = []
            if let process = runtime.process, !process.exited {
                terminateChatProcess(process)
            }
        }
    }

    /// `settings.update` moved the MCP server to another port: chat processes launched with the
    /// old port are terminated, at once when idle, otherwise when their turn ends
    /// (docs/mcp.md › Server lifecycle); the next message relaunches them with `--resume`.
    func mcpPortDidChange() async {
        let port = effectiveMCPPort
        for runtime in chats.runtimes.values {
            guard let process = runtime.liveProcess, process.mcpPort != port else { continue }
            if runtime.starting || runtime.turnInProgress {
                process.terminateAfterTurn = true
            } else {
                terminateChatProcess(process)
            }
        }
    }

    /// docs/architecture.md › Shutdown, step 1 for chat processes: every chat with a turn in
    /// progress gets the item `Stopped because HephaestusV2 quit.` and its pending permission
    /// requests are cancelled; then every process group gets SIGTERM, then SIGKILL 3 s later;
    /// returns once every process has ended.
    func stopChatProcesses() async {
        chats.stopped = true
        var ending: [(ChatID, ChatProcess)] = []
        for (chatID, runtime) in chats.runtimes {
            runtime.idleTask?.cancel()
            clearDeltas(runtime)
            let turn = runtime.starting || runtime.turnInProgress
            if turn, !chats.deleting.contains(chatID) {
                addSystemItem("Stopped because HephaestusV2 quit.", level: .warning, chatID: chatID)
                if let process = runtime.process, !process.exited {
                    for requestID in process.permissionOrder {
                        if let pending = process.permissions[requestID] {
                            resolvePermission(pending, decision: .deny, decidedBy: nil, chatID: chatID, process: process, origin: .system)
                        }
                    }
                }
            }
            runtime.pendingMessages = []
            if let process = runtime.process, !process.exited {
                process.terminatedByEngine = true
                process.cancelTimers()
                ending.append((chatID, process))
            }
        }
        await Engine.terminate(ending.map(\.1.handle), grace: chats.timings.shutdownGrace)
        for (chatID, process) in ending {
            let termination = await process.handle.waitForExit()
            await chatProcessExited(chatID, generation: process.generation, termination: termination)
        }
    }
}
