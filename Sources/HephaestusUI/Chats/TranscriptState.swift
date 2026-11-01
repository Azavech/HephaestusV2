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
    }

    var items: [ChatItem] = []
    /// Streaming buffers by item id.
    var streams: [String: StreamingBuffer] = [:]

    /// `chat.item`: adds the item, or replaces the item with the same `id`; the item ends its
    /// streaming bubble.
    // STUB: ui-chats — the rest of docs/chats.md › Streaming bubbles and › Size limits.
    mutating func upsert(_ item: ChatItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        streams[item.id] = nil
    }

    /// `chat.delta`: appends the text to the streaming buffer of `itemID`.
    mutating func append(_ delta: ChatDeltaEvent.Payload) {
        streams[delta.itemID, default: StreamingBuffer(kind: delta.kind, text: "")].text += delta.append
    }
}
