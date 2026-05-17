import Foundation
import AVFoundation
import WhisperKit

/// Local on-device speech-to-text via WhisperKit (argmax-oss-swift).
///
/// On first instantiation, downloads the default Whisper model (~150 MB) to
/// WhisperKit's default cache directory. Subsequent inits reuse the cached
/// model.
///
/// **No network calls** beyond the one-time model download. Inference runs
/// 100% on-device via CoreML.
public final class WhisperKitSTT: @unchecked Sendable {
    public enum Model: String, Sendable {
        case tiny  = "openai_whisper-tiny"
        case base  = "openai_whisper-base"
        case small = "openai_whisper-small"
    }

    private let whisper: WhisperKit
    public let modelName: String

    // Guards a one-shot retry for the first transcription after init. WhisperKit
    // sometimes returns an empty result on the very first call right after
    // model load (warmup race); a 500 ms pause + retry resolves it reliably.
    // Lock-free flip flag — only the first caller observes `true`.
    private var firstTranscriptionPending = true
    private let firstTranscriptionLock = NSLock()

    /// Initialize with a specific model. Default is `.base` — best balance of
    /// speed (~5× realtime on M-series) and accuracy.
    public init(model: Model = .base) async throws {
        Log.audio.info("loading WhisperKit model: \(model.rawValue) (this may take ~30s on first run)")
        let config = WhisperKitConfig(model: model.rawValue)
        self.whisper = try await WhisperKit(config)
        self.modelName = model.rawValue
        Log.audio.info("WhisperKit ready (model=\(model.rawValue))")
    }

    private func consumeFirstTranscriptionFlag() -> Bool {
        firstTranscriptionLock.lock()
        defer { firstTranscriptionLock.unlock() }
        if firstTranscriptionPending {
            firstTranscriptionPending = false
            return true
        }
        return false
    }

    /// One-shot file transcription. Used by tests and by the debug harness.
    ///
    /// Returns the concatenated text of all `TranscriptionResult` segments,
    /// trimmed of leading/trailing whitespace.
    public func transcribeFile(url: URL) async throws -> String {
        let isFirst = consumeFirstTranscriptionFlag()
        var transcript = try await runFileTranscription(path: url.path)
        if transcript.isEmpty && isFirst {
            // Warmup race: WhisperKit occasionally returns an empty result on
            // the very first call after model load. Pause briefly and retry.
            Log.audio.warning("WhisperKit returned empty on first call — retrying after 500 ms (warmup race)")
            try? await Task.sleep(nanoseconds: 500_000_000)
            transcript = try await runFileTranscription(path: url.path)
        }
        return transcript
    }

    private func runFileTranscription(path: String) async throws -> String {
        let results: [TranscriptionResult] = try await whisper.transcribe(audioPath: path)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streaming session — stub for now. P3-7 ConversationCoordinator will
    /// flesh this out with real partial-transcript handling. Today, it
    /// supports buffer-append + finalize via a one-shot transcribe of the
    /// accumulated samples.
    public func makeStreamingSession() throws -> StreamingSession {
        StreamingSession(parent: self, whisper: whisper)
    }

    internal func transcribeSamples(_ samples: [Float]) async throws -> String {
        let isFirst = consumeFirstTranscriptionFlag()
        var transcript = try await runArrayTranscription(samples: samples)
        if transcript.isEmpty && isFirst {
            Log.audio.warning("WhisperKit streaming returned empty on first call — retrying after 500 ms (warmup race)")
            try? await Task.sleep(nanoseconds: 500_000_000)
            transcript = try await runArrayTranscription(samples: samples)
        }
        return transcript
    }

    private func runArrayTranscription(samples: [Float]) async throws -> String {
        let results: [TranscriptionResult] = try await whisper.transcribe(audioArray: samples)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public final class StreamingSession {
        private weak var parent: WhisperKitSTT?
        private let whisper: WhisperKit
        private var buffered: [Float] = []

        init(parent: WhisperKitSTT, whisper: WhisperKit) {
            self.parent = parent
            self.whisper = whisper
        }

        /// Append a 16 kHz mono Float32 audio buffer to the rolling sample
        /// store. Caller is responsible for resampling/format conversion if
        /// the source is not already 16 kHz mono Float32.
        public func append(_ buffer: AVAudioPCMBuffer) {
            guard let ptr = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            buffered.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
        }

        /// Append raw 16 kHz mono Float32 samples.
        public func append(samples: [Float]) {
            buffered.append(contentsOf: samples)
        }

        /// How many samples have been accumulated since the last `finish()` / `cancel()`.
        public var sampleCount: Int { buffered.count }

        /// Finalize and return the full transcript of buffered audio.
        ///
        /// Clears the internal buffer on entry so the session can be reused
        /// for the next utterance.
        public func finish() async throws -> String {
            let samples = buffered
            buffered.removeAll(keepingCapacity: true)
            guard let parent else {
                let results: [TranscriptionResult] = try await whisper.transcribe(audioArray: samples)
                return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return try await parent.transcribeSamples(samples)
        }

        public func cancel() {
            buffered.removeAll(keepingCapacity: false)
        }
    }
}
