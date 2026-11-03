// OWNER: ui-chats — the transcript state of a chat shown in a view (docs/chats.md › UI state,
// › Streaming bubbles).
import Foundation
import HephaestusCore

/// One per chat shown in a view of a device (`DeviceWorkspace.transcripts`): the items in
/// transcript order and the streaming buffers. Pending permission requests and the incomplete
/// question set are read from the items.
struct TranscriptState {
    /// A streaming bubble: the kind and the text appended by `chat.delta`.
    struct StreamingBuffer: Hashable {
        var kind: ChatDeltaEvent.Payload.Kind
        var text: String
        /// Incremented by every append, so that views redraw only the bubbles that changed.
        var revision = 0
    }

    /// A `toolInput` bubble shows the last 300 characters of the partial JSON
    /// (docs/chats.md › Streaming bubbles); its buffer keeps no more than that.
    static let toolInputTail = 300

    /// The items in transcript order.
    private(set) var items: [ChatItem] = []
    /// Streaming buffers by item id.
    private(set) var streams: [String: StreamingBuffer] = [:]
    /// The item ids of `streams` in the order their first delta arrived.
    private(set) var streamOrder: [String] = []
    /// Incremented each time `chats.get` replaces the state, so that a web view resets its page.
    var generation = 0
    /// Per item id, incremented each time the item is added or replaced.
    private(set) var itemRevisions: [String: Int] = [:]

    private var indexByID: [String: Int] = [:]
    /// The id of the `toolResult` item of each `toolUseID`.
    private var resultIDByToolUseID: [String: String] = [:]
    /// The number of items whose `parentToolUseID` is a given `toolUseID`.
    private var stepCounts: [String: Int] = [:]
    /// The `toolUseID`s of the `toolUse` items.
    private var toolUseIDs: Set<String> = []

    init(items: [ChatItem] = [], generation: Int = 0) {
        self.generation = generation
        for item in items {
            upsert(item)
        }
    }

    /// `chat.item`: adds the item, or replaces the item with the same `id`; the item ends its
    /// streaming bubble.
    mutating func upsert(_ item: ChatItem) {
        if let index = indexByID[item.id] {
            unindex(items[index])
            items[index] = item
        } else {
            indexByID[item.id] = items.count
            items.append(item)
        }
        index(item)
        itemRevisions[item.id, default: 0] += 1
        if streams.removeValue(forKey: item.id) != nil {
            streamOrder.removeAll { $0 == item.id }
        }
    }

    /// `chat.delta`: appends the text to the streaming buffer of `itemID`. The first delta of an
    /// item id without an item creates the buffer; a delta for an item that already has its final
    /// item, and an empty delta, change nothing.
    mutating func append(_ delta: ChatDeltaEvent.Payload) {
        guard !delta.append.isEmpty, indexByID[delta.itemID] == nil else { return }
        if streams[delta.itemID] == nil {
            streams[delta.itemID] = StreamingBuffer(kind: delta.kind, text: "")
            streamOrder.append(delta.itemID)
        }
        streams[delta.itemID]?.text += delta.append
        if delta.kind == .toolInput, let text = streams[delta.itemID]?.text, text.count > Self.toolInputTail {
            streams[delta.itemID]?.text = String(text.suffix(Self.toolInputTail))
        }
        streams[delta.itemID]?.revision += 1
    }

    /// Removes every streaming bubble: `chat.updated` reported the state idle, waitingAnswers or
    /// error (docs/chats.md › Streaming bubbles).
    mutating func clearStreams() {
        guard !streams.isEmpty else { return }
        streams.removeAll()
        streamOrder.removeAll()
    }

    // MARK: Lookups

    /// The item with this id.
    func item(_ id: String) -> ChatItem? {
        indexByID[id].map { items[$0] }
    }

    /// The `toolResult` item of a tool call.
    func result(forToolUseID toolUseID: String) -> ToolResultItem? {
        guard let id = resultIDByToolUseID[toolUseID], case .toolResult(let result)? = item(id) else { return nil }
        return result
    }

    /// Whether a `toolUse` item has this `toolUseID`.
    func hasToolUse(_ toolUseID: String) -> Bool {
        toolUseIDs.contains(toolUseID)
    }

    /// The number of steps of a tool card: the items whose `parentToolUseID` is its `toolUseID`.
    func stepCount(ofToolUseID toolUseID: String) -> Int {
        stepCounts[toolUseID] ?? 0
    }

    /// The pending permission requests, oldest first: `permissionRequest` items without decision.
    var pendingPermissionRequests: [PermissionRequestItem] {
        items.compactMap { item in
            if case .permissionRequest(let request) = item, request.decision == nil { return request }
            return nil
        }
    }

    /// The question set that is not completed; a chat has at most one.
    var incompleteQuestionSet: QuestionsItem? {
        for item in items {
            if case .questions(let set) = item, !set.completed { return set }
        }
        return nil
    }

    /// The symbol request without answer; a chat has at most one.
    var waitingSymbolRequest: SymbolItem? {
        for item in items {
            if case .symbol(let request) = item, request.answer == nil { return request }
        }
        return nil
    }

    /// The color request without answer; a chat has at most one.
    var waitingColorRequest: ColorItem? {
        for item in items {
            if case .color(let request) = item, request.answer == nil { return request }
        }
        return nil
    }

    /// The sound request without answer; a chat has at most one.
    var waitingSoundRequest: SoundItem? {
        for item in items {
            if case .sound(let request) = item, request.answer == nil { return request }
        }
        return nil
    }

    /// The shortcut request without answer; a chat has at most one.
    var waitingShortcutRequest: ShortcutItem? {
        for item in items {
            if case .shortcut(let request) = item, request.answer == nil { return request }
        }
        return nil
    }

    /// The font request without answer; a chat has at most one.
    var waitingFontRequest: FontItem? {
        for item in items {
            if case .font(let request) = item, request.answer == nil { return request }
        }
        return nil
    }

    /// Every image of the chat's items in transcript order: user attachments and tool-result
    /// images.
    var images: [Attachment] {
        items.flatMap { item -> [Attachment] in
            switch item {
            case .user(let user): return user.attachments.filter { ChatAttachmentKind.isImage($0.contentType) }
            case .toolResult(let result): return result.images
            default: return []
            }
        }
    }

    /// The stored attachment of a user item or a tool result with this data path.
    func attachment(atPath path: String) -> Attachment? {
        for item in items {
            switch item {
            case .user(let user):
                if let attachment = user.attachments.first(where: { $0.path == path }) { return attachment }
            case .toolResult(let result):
                if let attachment = result.images.first(where: { $0.path == path }) { return attachment }
            default:
                break
            }
        }
        return nil
    }

    // MARK: Indexes

    private mutating func index(_ item: ChatItem) {
        switch item {
        case .toolUse(let use):
            toolUseIDs.insert(use.toolUseID)
            if let parent = use.parentToolUseID { stepCounts[parent, default: 0] += 1 }
        case .assistant(let assistant):
            if let parent = assistant.parentToolUseID { stepCounts[parent, default: 0] += 1 }
        case .thinking(let thinking):
            if let parent = thinking.parentToolUseID { stepCounts[parent, default: 0] += 1 }
        case .toolResult(let result):
            resultIDByToolUseID[result.toolUseID] = result.id
        default:
            break
        }
    }

    private mutating func unindex(_ item: ChatItem) {
        switch item {
        case .toolUse(let use):
            toolUseIDs.remove(use.toolUseID)
            if let parent = use.parentToolUseID { stepCounts[parent, default: 1] -= 1 }
        case .assistant(let assistant):
            if let parent = assistant.parentToolUseID { stepCounts[parent, default: 1] -= 1 }
        case .thinking(let thinking):
            if let parent = thinking.parentToolUseID { stepCounts[parent, default: 1] -= 1 }
        case .toolResult(let result):
            if resultIDByToolUseID[result.toolUseID] == result.id { resultIDByToolUseID[result.toolUseID] = nil }
        default:
            break
        }
    }
}
