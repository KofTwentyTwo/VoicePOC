import Foundation
import Observation
import AppKit

/// Observable state that drives the JARVIS HUD view.
///
/// `state` mirrors `ConversationCoordinator.State`. `intensity` is a 0..1
/// "mouth open" value pumped by AVSpeechTTS while it's speaking — used by the
/// HUD view's orb-pulse animation. `lastTranscript` and `lastResponse` are
/// short text snippets for the caption display.
@MainActor
@Observable
public final class JarvisHUDState {
    public enum Mode: String, Sendable {
        case idle, listening, thinking, speaking
    }

    public var mode: Mode = .idle
    public var intensity: Double = 0          // 0..1, animated by TTS callbacks
    public var lastUtterance: String = ""      // what the user said (transcript)
    public var lastResponse: String = ""       // what JARVIS replied
    public var listeningElapsed: Double = 0

    public init() {}

    public func setMode(_ m: Mode) {
        self.mode = m
        if m != .speaking {
            self.intensity = 0
        }
    }
}
