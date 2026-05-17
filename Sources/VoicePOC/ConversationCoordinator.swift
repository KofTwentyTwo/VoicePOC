import Foundation
import AVFoundation

/// Top-level conversation actor. Stitches together microphone capture,
/// WhisperKit STT, Silero VAD end-of-turn detection, Ollama LLM, and TTS
/// playback into a multi-turn voice conversation.
///
/// State machine:
///
///   idle ──toggle──▶ listening ──end-of-utterance──▶ thinking ──LLM done──▶ speaking ──tts done──▶ listening …
///         ▲                                                                                          │
///         └─────────── toggle / sessionIdleTimeout (no speech for N seconds) ─────────────────────────┘
///
/// All transitions log via `Log.state`. Transcript text is **redacted** before
/// logging — only `Log.redact(_:)` length descriptors leak.
public actor ConversationCoordinator {

    public enum State: String, Sendable {
        case idle
        case listening
        case thinking
        case speaking
    }

    // MARK: - Configuration

    private let capture: AudioCapture
    private let stt: WhisperKitSTT
    private let vad: SileroVAD
    private let ollama: OllamaClient
    private let tts: TTSProvider
    private let systemPrompt: String
    private let endOfTurnSilenceMs: Int
    private let sessionIdleTimeoutSec: Double

    // VAD frame math
    private let vadFrameSize = 512                       // samples
    private let vadFrameMs   = 32                        // ms per frame at 16 kHz

    // MARK: - State

    public private(set) var state: State = .idle
    private var history: [OllamaClient.Message] = []
    private var conversationTask: Task<Void, Never>?
    private var activeStateTokens: Int = 0               // for streamed-token status
    private var lastUtteranceTextLen: Int = 0
    private var lastUtteranceText: String = ""           // most recent transcript (HUD caption)
    private var lastResponseText: String = ""            // most recent JARVIS reply (HUD caption)
    private var listeningStartedAt: Date?                // for status line
    private var firstSpeechFrameAt: Date?                // for status line

    /// Most recent (user utterance, assistant response) pair — for HUD display.
    public func lastTexts() -> (String, String) {
        (lastUtteranceText, lastResponseText)
    }

    // MARK: - Init

    public init(
        capture: AudioCapture,
        stt: WhisperKitSTT,
        vad: SileroVAD,
        ollama: OllamaClient,
        tts: TTSProvider,
        systemPrompt: String = "You are JARVIS, a helpful and witty assistant. Reply in one to two short, conversational sentences.",
        endOfTurnSilenceMs: Int = 800,
        sessionIdleTimeoutSec: Double = 10
    ) {
        self.capture = capture
        self.stt = stt
        self.vad = vad
        self.ollama = ollama
        self.tts = tts
        self.systemPrompt = systemPrompt
        self.endOfTurnSilenceMs = endOfTurnSilenceMs
        self.sessionIdleTimeoutSec = sessionIdleTimeoutSec
    }

    // MARK: - Public API

    public func currentState() -> State { state }

    /// Snapshot for the status display.
    public func status() -> Status {
        Status(
            state: state,
            listeningElapsedSec: listeningStartedAt.map { Date().timeIntervalSince($0) },
            speechDetected: firstSpeechFrameAt != nil,
            streamedTokens: activeStateTokens,
            lastTranscriptLen: lastUtteranceTextLen
        )
    }

    public struct Status: Sendable {
        public let state: State
        public let listeningElapsedSec: Double?
        public let speechDetected: Bool
        public let streamedTokens: Int
        public let lastTranscriptLen: Int
    }

    /// Toggle the conversation. Hotkey calls this.
    public func toggle() async {
        switch state {
        case .idle:
            await startConversation()
        case .listening, .thinking, .speaking:
            await endConversation(reason: "toggle")
        }
    }

    // MARK: - Conversation lifecycle

    private func startConversation() async {
        guard state == .idle else { return }
        Log.state.info("state: idle → listening")
        history = [OllamaClient.Message(role: "system", content: systemPrompt)]
        vad.reset()
        transitionTo(.listening)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runConversation()
        }
        conversationTask = task
    }

    private func endConversation(reason: String) async {
        guard state != .idle else { return }
        Log.state.info("state: \(state.rawValue) → idle (reason: \(reason))")
        tts.cancel()
        conversationTask?.cancel()
        conversationTask = nil
        transitionTo(.idle)
    }

    private func transitionTo(_ next: State) {
        state = next
        activeStateTokens = 0
        if next == .listening {
            listeningStartedAt = Date()
            firstSpeechFrameAt = nil
        } else {
            listeningStartedAt = nil
            firstSpeechFrameAt = nil
        }
    }

    private func markSpeechStarted() {
        if firstSpeechFrameAt == nil { firstSpeechFrameAt = Date() }
    }

    private func setStreamedTokens(_ n: Int) { activeStateTokens = n }
    private func setLastTranscriptLen(_ n: Int) { lastUtteranceTextLen = n }

    // MARK: - Conversation main loop

    private func runConversation() async {
        // Each iteration is one turn: capture-with-VAD → STT → LLM → TTS.
        while !Task.isCancelled && state != .idle {
            // 1. Listen for an utterance.
            let utteranceSamples: [Float]
            do {
                guard let samples = try await captureUtterance() else {
                    // sessionIdleTimeout fired with no speech — end the session.
                    Log.state.info("conversation: idle timeout reached, ending session")
                    await endConversation(reason: "idle timeout")
                    return
                }
                utteranceSamples = samples
            } catch is CancellationError {
                return
            } catch {
                Log.state.error("conversation: capture failed: \(error.localizedDescription)")
                await endConversation(reason: "capture error")
                return
            }

            if Task.isCancelled || state == .idle { return }

            // 2. Transcribe.
            Log.state.info("state: listening → thinking")
            transitionTo(.thinking)

            let transcript: String
            do {
                let perfStart = Date()
                transcript = try await stt.transcribeSamplesPublic(utteranceSamples)
                let ms = Int(Date().timeIntervalSince(perfStart) * 1000)
                Log.perf.info("stt: \(ms) ms, \(Log.redact(transcript))")
            } catch is CancellationError {
                return
            } catch {
                Log.state.error("conversation: STT failed: \(error.localizedDescription)")
                transitionTo(.listening)
                continue
            }

            setLastTranscriptLen(transcript.count)
            lastUtteranceText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

            let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                Log.state.info("conversation: empty transcript — back to listening")
                transitionTo(.listening)
                continue
            }

            // 3. Ask Ollama.
            history.append(OllamaClient.Message(role: "user", content: cleaned))
            let response: String
            do {
                let perfStart = Date()
                var full = ""
                var tokenCount = 0
                for try await chunk in ollama.chatStream(messages: history) {
                    if Task.isCancelled || state == .idle { return }
                    full += chunk
                    tokenCount += 1
                    setStreamedTokens(tokenCount)
                }
                let ms = Int(Date().timeIntervalSince(perfStart) * 1000)
                response = full.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.perf.info("ollama: \(ms) ms, \(tokenCount) chunks, \(Log.redact(response))")
            } catch is CancellationError {
                return
            } catch {
                Log.state.error("conversation: Ollama failed: \(error.localizedDescription)")
                // Drop the user message so history doesn't grow malformed.
                _ = history.popLast()
                transitionTo(.listening)
                continue
            }

            if response.isEmpty {
                _ = history.popLast()
                Log.state.info("conversation: empty LLM response — back to listening")
                transitionTo(.listening)
                continue
            }
            history.append(OllamaClient.Message(role: "assistant", content: response))
            lastResponseText = response

            // 4. Speak.
            if Task.isCancelled || state == .idle { return }
            Log.state.info("state: thinking → speaking")
            transitionTo(.speaking)
            do {
                try await tts.speak(response)
            } catch is CancellationError {
                return
            } catch {
                Log.state.error("conversation: TTS failed: \(error.localizedDescription)")
            }

            if Task.isCancelled || state == .idle { return }
            Log.state.info("state: speaking → listening")
            transitionTo(.listening)
        }
    }

    // MARK: - Capture + VAD

    /// Consume audio buffers until VAD reports end-of-turn after detecting
    /// speech. Returns the accumulated 16 kHz Float32 samples for STT.
    ///
    /// Returns `nil` if `sessionIdleTimeoutSec` elapses with no speech detected
    /// (signals the caller to end the conversation).
    /// Throws `CancellationError` if the surrounding task is cancelled.
    private func captureUtterance() async throws -> [Float]? {
        var utterance: [Float] = []
        var vadPending: [Float] = []
        var heardSpeech = false
        var consecutiveSilenceFrames = 0
        let silenceFramesForEndOfTurn = max(1, endOfTurnSilenceMs / vadFrameMs)
        let utteranceStarted = Date()

        for await buffer in capture.buffers {
            if Task.isCancelled || state == .idle { throw CancellationError() }
            guard let ptr = buffer.floatChannelData?[0] else { continue }
            let n = Int(buffer.frameLength)
            if n == 0 { continue }

            let block = Array(UnsafeBufferPointer(start: ptr, count: n))
            utterance.append(contentsOf: block)
            vadPending.append(contentsOf: block)

            // Run VAD over as many 512-sample frames as we have buffered.
            while vadPending.count >= vadFrameSize {
                let frame = Array(vadPending.prefix(vadFrameSize))
                vadPending.removeFirst(vadFrameSize)
                let prob = (try? vad.probability(frame: frame)) ?? 0
                let isSpeech = prob >= 0.5
                if isSpeech {
                    if !heardSpeech {
                        heardSpeech = true
                        markSpeechStarted()
                        Log.audio.info("vad: speech detected (prob=\(String(format: "%.2f", prob)))")
                    }
                    consecutiveSilenceFrames = 0
                } else if heardSpeech {
                    consecutiveSilenceFrames += 1
                    if consecutiveSilenceFrames >= silenceFramesForEndOfTurn {
                        Log.audio.info("vad: end-of-turn (\(consecutiveSilenceFrames) silence frames, ~\(consecutiveSilenceFrames * vadFrameMs) ms)")
                        return utterance
                    }
                }
            }

            // Pre-speech idle timeout: no speech detected within N seconds.
            if !heardSpeech, Date().timeIntervalSince(utteranceStarted) >= sessionIdleTimeoutSec {
                return nil
            }
        }
        // Audio stream ended — treat as end-of-utterance if we heard anything.
        return heardSpeech ? utterance : nil
    }
}

// MARK: - WhisperKitSTT bridge for actor isolation

extension WhisperKitSTT {
    /// Public actor-friendly wrapper around the internal warmup-safe transcription path.
    public func transcribeSamplesPublic(_ samples: [Float]) async throws -> String {
        try await transcribeSamples(samples)
    }
}
