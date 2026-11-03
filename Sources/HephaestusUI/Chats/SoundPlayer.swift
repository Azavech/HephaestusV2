// OWNER: ui-chats — the playback of the sounds of the sound card and of sound markers
// (docs/chats.md › Sound playback).
import AppKit
import HephaestusCore

/// Plays the sounds of a chat: the file read with `sounds.read` through the window's engine
/// connection, played with `NSSound`; one sound plays at a time in the app.
@MainActor
enum SoundPlayer {
    /// Data that `NSSound` cannot read.
    struct UnplayableSound: LocalizedError {
        var errorDescription: String? { "The sound cannot be played." }
    }

    private static var playing: NSSound?
    /// Incremented by each play, so that a sound read after a newer play started is not played.
    private static var generation = 0

    /// Reads the sound `name` of the project's catalogue and plays it, stopping the sound that
    /// plays.
    static func play(_ name: String, projectID: String, workspace: DeviceWorkspace) async throws {
        generation += 1
        let current = generation
        let content = try await workspace.call(SoundsRead.self, SoundsRead.Params(projectID: projectID, name: name))
        guard let data = Data(base64Encoded: content.dataBase64), let sound = NSSound(data: data) else {
            throw UnplayableSound()
        }
        guard current == generation else { return }
        playing?.stop()
        playing = sound
        sound.play()
    }
}
