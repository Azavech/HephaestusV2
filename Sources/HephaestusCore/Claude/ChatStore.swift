import Foundation

/// The chat files of a project's `.hephaestus/chats/` folder: metadata, transcript and the
/// attachment folder (docs/chats.md › Persistence, docs/data-model.md › Chat metadata file,
/// › Chat transcript file).
extension Engine {
    // MARK: Metadata

    /// The chat's metadata with its computed `state`, or nil when no loaded project holds it.
    func chatMeta(_ chatID: ChatID) -> ChatMeta? {
        guard var meta = domain.chat(chatID) else { return nil }
        meta.state = chats.state(of: chatID)
        meta.backgroundWork = chats.backgroundWork(of: chatID)
        meta.costUSD = chats.costs[chatID]?.costUSD
        return meta
    }

    /// The chat's metadata, or `notFound` (`Chat <id> not found.`).
    func requireChat(_ chatID: ChatID) throws -> ChatMeta {
        guard let meta = chatMeta(chatID), !chats.deleting.contains(chatID) else {
            throw EngineError.notFound("Chat", chatID.uuidString)
        }
        return meta
    }

    /// The `.hephaestus/` folder of the chat's project.
    func chatFolder(_ meta: ChatMeta) throws -> ProjectFolder {
        guard let root = domain.projectRoot(meta.projectID) else {
            throw EngineError.notFound("Project", meta.projectID)
        }
        return ProjectFolder(root: root)
    }

    /// Writes the metadata file atomically with `updated` set to now, keeps it in memory and
    /// emits `chat.updated` (docs/chats.md › Persistence).
    @discardableResult
    func saveChatMeta(_ meta: ChatMeta, origin: Actor) throws -> ChatMeta {
        var meta = meta
        meta.updated = ISODate.now()
        let folder = try chatFolder(meta)
        do {
            let digest = try ProjectFileStore.write(meta, to: folder)
            ownWrites.recordWrite(path: folder.chatMetaFile(meta.id).path, sha256: digest)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        meta.state = chats.state(of: meta.id)
        meta.backgroundWork = chats.backgroundWork(of: meta.id)
        meta.costUSD = chats.costs[meta.id]?.costUSD
        domain.upsertChat(meta)
        recordReportedState(meta)
        emit(ChatUpdatedEvent.self, meta, origin: origin)
        return meta
    }

    /// Saves the metadata from a background step; a failure is logged.
    func saveChatMetaLogging(_ meta: ChatMeta, origin: Actor) {
        do {
            try saveChatMeta(meta, origin: origin)
        } catch {
            log.error(.claude, "chat \(meta.id.uuidString): the metadata cannot be written: \(error)")
        }
    }

    /// Emits `chat.updated` when the chat's state or `backgroundWork` differs from the last one
    /// reported.
    func reportChatState(_ chatID: ChatID, origin: Actor = .system) {
        guard !chats.deleting.contains(chatID), let meta = chatMeta(chatID) else { return }
        guard chats.reportedStates[chatID] != meta.state || chats.reportedBackgroundWork[chatID, default: false] != meta.backgroundWork
        else { return }
        recordReportedState(meta)
        emit(ChatUpdatedEvent.self, meta, origin: origin)
    }

    /// Emits `chat.updated` with the current metadata and state.
    func emitChatUpdated(_ chatID: ChatID, origin: Actor) {
        guard let meta = chatMeta(chatID) else { return }
        recordReportedState(meta)
        emit(ChatUpdatedEvent.self, meta, origin: origin)
    }

    // MARK: Transcript

    /// Appends an `add` or `update` line and emits `chat.item` (docs/data-model.md › Transcript
    /// writes); the streamed text of the item is dropped.
    func appendChatItem(_ item: ChatItem, chatID: ChatID, op: TranscriptOp = .add, origin: Actor) throws {
        guard !chats.deleting.contains(chatID), let meta = domain.chat(chatID) else { return }
        let url = try chatFolder(meta).transcriptFile(chatID)
        do {
            try chats.transcripts.append(TranscriptLine(op: op, item: item), to: url)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        chats.runtimes[chatID]?.deltas.drop(item.id)
        chats.runtimes[chatID]?.turnReport.record(item)
        emit(ChatItemEvent.self, .init(chatID: chatID, item: item), origin: origin)
        // A chat that is not scanned yet gets its cost from the whole transcript when it is.
        if op == .add, case .result(let result) = item, let cost = result.costUSD, chats.scannedChats.contains(chatID) {
            chats.costs[chatID, default: ChatCost()].add(cost)
            emitChatCostChanged(chatID, origin: origin)
        }
    }

    /// Appends an item from a background step; a failure is logged.
    func appendChatItemLogging(_ item: ChatItem, chatID: ChatID, op: TranscriptOp = .add, origin: Actor = .system) {
        do {
            try appendChatItem(item, chatID: chatID, op: op, origin: origin)
        } catch {
            log.error(.claude, "chat \(chatID.uuidString): an item cannot be written: \(error)")
        }
    }

    /// Adds a `system` item.
    func addSystemItem(_ text: String, level: SystemLevel, chatID: ChatID, origin: Actor = .system) {
        appendChatItemLogging(.system(SystemItem(id: RandomIDs.uuidString(), created: ISODate.now(), text: text, level: level)),
                              chatID: chatID, origin: origin)
    }

    /// Replays the chat's transcript (docs/data-model.md › Replay). While the chat has no live
    /// process, every pending `permissionRequest` item is cancelled: `decision` `deny`,
    /// `decidedBy` null (docs/chats.md › Cancellation). The question set that is not completed is
    /// recorded.
    func loadTranscript(_ chatID: ChatID) throws -> [ChatItem] {
        let meta = try requireChat(chatID)
        let url = try chatFolder(meta).transcriptFile(chatID)
        var items: [ChatItem]
        do {
            items = try TranscriptReplay.replay(fileAt: url, log: log)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        if chats.runtimes[chatID]?.process == nil {
            for (index, item) in items.enumerated() {
                guard case .permissionRequest(var request) = item, request.decision == nil else { continue }
                request.decision = .deny
                request.decidedBy = nil
                items[index] = .permissionRequest(request)
                appendChatItemLogging(.permissionRequest(request), chatID: chatID, op: .update)
            }
        }
        if recordScan(chatID, items: items) {
            emitChatCostChanged(chatID, origin: .system)
        }
        return items
    }

    /// Records the question set that is not completed, the symbol, color, sound, shortcut, font and
    /// animation requests without answer, whether a user message has text and the chat's cost;
    /// returns whether the cost changed.
    @discardableResult
    private func recordScan(_ chatID: ChatID, items: [ChatItem]) -> Bool {
        chats.scannedChats.insert(chatID)
        let cost = ChatCost(items: items)
        let costChanged = chats.costs[chatID]?.costUSD != cost.costUSD
        chats.costs[chatID] = cost
        var open: QuestionsItem?
        var openSymbol: SymbolItem?
        var openColor: ColorItem?
        var openSound: SoundItem?
        var openShortcut: ShortcutItem?
        var openFont: FontItem?
        var openAnimation: AnimationItem?
        var hasText = false
        for item in items {
            switch item {
            case .questions(let set) where !set.completed: open = set
            case .symbol(let request) where request.answer == nil: openSymbol = request
            case .color(let request) where request.answer == nil: openColor = request
            case .sound(let request) where request.answer == nil: openSound = request
            case .shortcut(let request) where request.answer == nil: openShortcut = request
            case .font(let request) where request.answer == nil: openFont = request
            case .animation(let request) where request.answer == nil: openAnimation = request
            case .user(let user) where !user.text.isEmpty: hasText = true
            default: break
            }
        }
        chats.openQuestionSets[chatID] = open
        chats.openSymbolRequests[chatID] = openSymbol
        chats.openColorRequests[chatID] = openColor
        chats.openSoundRequests[chatID] = openSound
        chats.openShortcutRequests[chatID] = openShortcut
        chats.openFontRequests[chatID] = openFont
        chats.openAnimationRequests[chatID] = openAnimation
        chats.hasTextMessage[chatID] = hasText
        return costChanged
    }

    /// Replays the transcript once when the engine has not done it since it started.
    func ensureChatScanned(_ chatID: ChatID) throws {
        guard !chats.scannedChats.contains(chatID) else { return }
        _ = try loadTranscript(chatID)
    }

    /// docs/data-model.md › Loading, step 4: the transcript of every chat of the loaded projects
    /// is replayed once, in a child task, to find a question set that is not completed (the
    /// state becomes waitingAnswers, with `chat.updated`) and to cancel the pending permission
    /// requests.
    func scanChatTranscriptsOfLoadedProjects() {
        for projectID in domain.loadedProjectIDs() {
            scanChatTranscripts(of: projectID)
        }
    }

    /// Scans the chats of a project that the engine has not scanned yet: called at startup, and
    /// for a project loaded later (`projects.open`, `projects.create`, a reload).
    func scanChatTranscripts(of projectID: ProjectID) {
        guard let root = domain.projectRoot(projectID) else { return }
        let folder = ProjectFolder(root: root)
        for meta in domain.chats(of: projectID) where !chats.scannedChats.contains(meta.id) {
            let url = folder.transcriptFile(meta.id)
            let chatID = meta.id
            let log = self.log
            Task {
                let items = await Task.detached { (try? TranscriptReplay.replay(fileAt: url, log: log)) ?? [] }.value
                self.applyStartupScan(chatID, items: items)
            }
        }
    }

    private func applyStartupScan(_ chatID: ChatID, items: [ChatItem]) {
        guard !chats.scannedChats.contains(chatID), !chats.deleting.contains(chatID), domain.chat(chatID) != nil else { return }
        var items = items
        if chats.runtimes[chatID]?.process == nil {
            for (index, item) in items.enumerated() {
                guard case .permissionRequest(var request) = item, request.decision == nil else { continue }
                request.decision = .deny
                request.decidedBy = nil
                items[index] = .permissionRequest(request)
                appendChatItemLogging(.permissionRequest(request), chatID: chatID, op: .update)
            }
        }
        if recordScan(chatID, items: items) {
            emitChatCostChanged(chatID, origin: .system)
        } else {
            reportChatState(chatID)
        }
    }

    // MARK: Trash

    /// Moves a chat file or folder to the Trash; a missing item is skipped. Failure:
    /// `unavailable` `<path> cannot be moved to the Trash: <reason>.`
    func moveChatItemToTrash(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try moveItemToTrash(url, path: url.path)
        ownWrites.recordRemoval(path: url.path)
    }
}
