import Foundation
import Observation

/// Observable state that drives the JARVIS HUD + Status views.
///
/// `mode` mirrors `ConversationCoordinator.State`. `intensity` is a 0..1
/// "mouth open" value pumped by AVSpeechTTS per-word callbacks. `micRMS`
/// and `vadProbability` are live audio meters. `lastUtterance` and
/// `lastResponse` populate the on-screen captions.
@MainActor
@Observable
public final class JarvisHUDState {
    public enum Mode: String, Sendable {
        case idle, listening, thinking, speaking
    }

    public var mode: Mode = .idle
    public var intensity: Double = 0           // 0..1, animated by TTS callbacks
    public var micRMS: Double = 0              // live RMS from AudioCapture (0..~0.3)
    public var vadProbability: Float = 0       // live Silero VAD probability (0..1)
    public var streamingTokenCount: Int = 0    // current LLM streaming chunk count
    public var lastUtterance: String = ""
    public var lastResponse: String = ""
    public var listeningElapsed: Double = 0

    public init() {}

    public func setMode(_ m: Mode) {
        self.mode = m
        if m != .speaking {
            self.intensity = 0
        }
        if m == .idle || m == .listening {
            self.streamingTokenCount = 0
        }
    }
}
