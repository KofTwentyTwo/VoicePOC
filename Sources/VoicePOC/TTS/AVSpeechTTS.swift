import Foundation
import AVFoundation

/// Tier-1 TTS via `AVSpeechSynthesizer`.
///
/// Voice selection priority on initialization:
///   1. Any installed **Premium** English voice (Zoe, Ava, etc.) — most natural
///   2. Any installed **Enhanced** English voice — decent quality
///   3. The default system voice (Samantha on en-US) — adequate
///
/// Premium voices are installed via System Settings → Accessibility →
/// Spoken Content → System Voice → Manage Voices. Not present by default.
public final class AVSpeechTTS: NSObject, TTSProvider, @preconcurrency AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?
    public let voice: AVSpeechSynthesisVoice

    /// Called on each spoken-word delegate callback while TTS is active.
    /// Used by the HUD to animate mouth/orb intensity in sync with speech.
    /// Callback runs on the main thread.
    public var onSpeakingPulse: (@MainActor @Sendable () -> Void)?

    /// Called when an utterance begins. Useful for HUD state to enter "speaking".
    public var onSpeakingStart: (@MainActor @Sendable () -> Void)?

    /// Called when an utterance finishes (normally or via cancel).
    public var onSpeakingEnd: (@MainActor @Sendable () -> Void)?

    public override init() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let premium = voices.first { $0.language.hasPrefix("en") && $0.quality == .premium }
        let enhanced = voices.first { $0.language.hasPrefix("en") && $0.quality == .enhanced }
        self.voice = premium ?? enhanced ?? AVSpeechSynthesisVoice(language: "en-US")!
        super.init()
        synth.delegate = self
        let qualityStr = voice.quality.rawValue == 3 ? "premium"
            : voice.quality.rawValue == 2 ? "enhanced" : "default"
        Log.audio.info("AVSpeechTTS: voice='\(voice.name)' quality=\(qualityStr)")
        if voice.quality != .premium {
            Log.audio.warning("no Premium voice installed; for best quality install one via System Settings → Accessibility → Spoken Content → System Voice → Manage Voices")
        }
    }

    public func speak(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            self.synth.speak(utterance)
        }
    }

    /// Cancel any in-progress speech. The pending `speak(_:)` task will throw `CancellationError`.
    public func cancel() {
        synth.stopSpeaking(at: .immediate)
    }

    // MARK: AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        if let cb = onSpeakingStart {
            Task { @MainActor in cb() }
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  willSpeakRangeOfSpeechString characterRange: NSRange,
                                  utterance: AVSpeechUtterance) {
        // Fires for each word boundary — perfect mouth/orb pulse driver.
        if let cb = onSpeakingPulse {
            Task { @MainActor in cb() }
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if let cb = onSpeakingEnd {
            Task { @MainActor in cb() }
        }
        continuation?.resume(returning: ())
        continuation = nil
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if let cb = onSpeakingEnd {
            Task { @MainActor in cb() }
        }
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
