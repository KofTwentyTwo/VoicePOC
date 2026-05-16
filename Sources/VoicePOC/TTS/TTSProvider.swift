import Foundation

/// Common interface for tier-1 (AVSpeech) and tier-2 (Orpheus) TTS implementations.
///
/// A `TTSProvider` speaks `text` and resolves when audio playback completes.
/// Streaming providers should resolve only after the final audio chunk has flushed.
public protocol TTSProvider: Sendable {
    func speak(_ text: String) async throws
}
