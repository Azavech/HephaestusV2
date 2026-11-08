// OWNER: ui-chats — loading the transcripts of the chats shown in views and following their states
// (docs/chats.md › UI state, › Streaming bubbles, › Chat states; docs/ui.md › DeviceWorkspace).
import Foundation
import HephaestusCore
import Observation

/// Keeps `DeviceWorkspace.transcripts` for the chats shown in views: opening a chat calls
/// `chats.get` under the replay rule, a reconnect loads it again, and the state is dropped when
/// the last view of the chat closes. It also records when this client saw each chat become
/// running and each compaction start (the `m:ss` of the status line) and removes the streaming
/// bubbles when a chat becomes idle, waitingAnswers or error.
@MainActor @Observable
final class ChatTranscriptStore {
    static let shared = ChatTranscriptStore()

    struct Key: Hashable {
        var workspace: ObjectIdentifier
        var chatID: String
    }

    /// The loading state of a shown chat's transcript.
    enum Phase: Equatable {
        case loading
        case loaded
        /// `chats.get` failed with this message; `notFound` when the chat does not exist.
        case failed(message: String, notFound: Bool)
    }

    private(set) var phases: [Key: Phase] = [:]
    /// When this client saw each chat become running.
    private(set) var runningSince: [Key: Date] = [:]
    /// When this client saw the running compaction of each chat start (docs/chats.md › Chat
    /// states), by the chat's `compactingSince`.
    private(set) var compactionsSeen: [Key: (compactingSince: Date, seen: Date)] = [:]

    @ObservationIgnored private var viewers: [Key: Int] = [:]
    @ObservationIgnored private var loadedGenerations: [Key: Int] = [:]
    @ObservationIgnored private var lastStates: [Key: ChatState] = [:]
    @ObservationIgnored private var subscriptions: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var transcriptGeneration = 0

    private func key(_ chatID: String, _ workspace: DeviceWorkspace) -> Key {
        Key(workspace: ObjectIdentifier(workspace), chatID: chatID)
    }

    func phase(of chatID: String, in workspace: DeviceWorkspace) -> Phase? {
        phases[key(chatID, workspace)]
    }

    func runningSince(_ chatID: String, in workspace: DeviceWorkspace) -> Date? {
        runningSince[key(chatID, workspace)]
    }

    /// When this client saw the compaction `compactingSince` of the chat start; nil when it has
    /// not seen that compaction yet.
    func compactionSeen(_ chatID: String, compactingSince: Date, in workspace: DeviceWorkspace) -> Date? {
        guard let entry = compactionsSeen[key(chatID, workspace)], entry.compactingSince == compactingSince else { return nil }
        return entry.seen
    }

    // MARK: Views

    /// A view starts showing the chat.
    func open(_ chatID: String, in workspace: DeviceWorkspace) {
        subscribe(to: workspace)
        let key = key(chatID, workspace)
        viewers[key, default: 0] += 1
        if let meta = workspace.chats[chatID] {
            observe(meta, key: key, workspace: workspace)
        }
        ensureLoaded(chatID, in: workspace)
    }

    /// A view stops showing the chat; the last one drops its transcript state.
    func close(_ chatID: String, in workspace: DeviceWorkspace) {
        let key = key(chatID, workspace)
        guard let count = viewers[key] else { return }
        if count > 1 {
            viewers[key] = count - 1
            return
        }
        viewers[key] = nil
        phases[key] = nil
        loadedGenerations[key] = nil
        workspace.transcripts[chatID] = nil
    }

    /// Loads the transcript when it is not loaded for the workspace's current connection, or
    /// again when `force` is set (Try Again).
    func ensureLoaded(_ chatID: String, in workspace: DeviceWorkspace, force: Bool = false) {
        let key = key(chatID, workspace)
        guard viewers[key] != nil, phases[key] != .loading else { return }
        let generation = workspace.connectionGeneration
        if !force, phases[key] == .loaded, loadedGenerations[key] == generation, workspace.transcripts[chatID] != nil {
            return
        }
        guard let uuid = UUID(uuidString: chatID) else {
            phases[key] = .failed(message: "\(chatID) is not a chat id.", notFound: true)
            return
        }
        phases[key] = .loading
        Task {
            await load(chatID, uuid: uuid, key: key, generation: generation, in: workspace)
        }
    }

    /// `chats.get` under the replay rule: the result replaces the chat's metadata and its
    /// transcript state, then the state events recorded while it was in flight are applied in
    /// arrival order (docs/chats.md › UI state).
    private func load(_ chatID: String, uuid: UUID, key: Key, generation: Int, in workspace: DeviceWorkspace) async {
        do {
            try await workspace.seed({
                try await workspace.call(ChatsGet.self, ChatsGet.Params(chatID: uuid))
            }, replace: { transcript in
                guard self.viewers[key] != nil else { return }
                workspace.chats[chatID] = transcript.meta
                self.transcriptGeneration += 1
                workspace.transcripts[chatID] = TranscriptState(items: transcript.items, generation: self.transcriptGeneration)
            }, replay: { event in
                guard self.viewers[key] != nil else { return }
                switch event.event {
                case .chatItem(let payload) where payload.chatID == uuid:
                    workspace.transcripts[chatID]?.upsert(payload.item)
                case .chatUpdated(let meta) where meta.id == uuid:
                    workspace.chats[chatID] = meta
                case .chatDeleted(let payload) where payload.chatID == uuid:
                    workspace.transcripts[chatID] = nil
                default:
                    break
                }
            })
            guard viewers[key] != nil else { return }
            phases[key] = .loaded
            loadedGenerations[key] = generation
            if let meta = workspace.chats[chatID] {
                observe(meta, key: key, workspace: workspace)
            }
        } catch {
            guard viewers[key] != nil else { return }
            phases[key] = .failed(message: errorMessage(error), notFound: (error as? EngineError)?.code == .notFound)
        }
    }

    // MARK: Chat states

    private func subscribe(to workspace: DeviceWorkspace) {
        let id = ObjectIdentifier(workspace)
        guard subscriptions[id] == nil else { return }
        let events = workspace.events()
        subscriptions[id] = Task { [weak self, weak workspace] in
            for await event in events {
                guard let self, let workspace else { break }
                switch event.event {
                case .chatUpdated(let meta):
                    self.observe(meta, key: Key(workspace: id, chatID: meta.id.uuidString), workspace: workspace)
                case .chatDeleted(let payload):
                    let key = Key(workspace: id, chatID: payload.chatID.uuidString)
                    self.lastStates[key] = nil
                    self.runningSince[key] = nil
                    self.compactionsSeen[key] = nil
                default:
                    break
                }
            }
            self?.forget(workspace: id)
        }
    }

    private func forget(workspace id: ObjectIdentifier) {
        subscriptions[id] = nil
        for key in Array(lastStates.keys) where key.workspace == id {
            lastStates[key] = nil
            runningSince[key] = nil
            compactionsSeen[key] = nil
        }
    }

    /// Follows a chat's state: `m:ss` counts from the moment this client saw it become running,
    /// or saw its compaction start; idle, waitingAnswers and error remove every streaming bubble.
    private func observe(_ meta: ChatMeta, key: Key, workspace: DeviceWorkspace) {
        let previous = lastStates[key]
        lastStates[key] = meta.state
        if meta.state == .running, previous != .running {
            runningSince[key] = Date()
        } else if meta.state != .running, runningSince[key] != nil {
            runningSince[key] = nil
        }
        if let compactingSince = meta.compactingSince {
            if compactionsSeen[key]?.compactingSince != compactingSince {
                compactionsSeen[key] = (compactingSince, Date())
            }
        } else if compactionsSeen[key] != nil {
            compactionsSeen[key] = nil
        }
        switch meta.state {
        case .idle, .waitingAnswers, .error:
            if workspace.transcripts[key.chatID]?.streams.isEmpty == false {
                workspace.transcripts[key.chatID]?.clearStreams()
            }
        case .starting, .running, .waitingPermission:
            break
        }
    }
}
