import Foundation
import AVFoundation
import Logging

/// Owns a single `AVAudioEngine` with one tap at 16 kHz mono Float32.
///
/// Push model: buffers are placed onto an `AsyncStream` that downstream stages
/// consume one at a time. Only one consumer should be iterating `buffers` at any
/// moment; transitions between stages cancel the current iterator.
public final class AudioCapture: @unchecked Sendable {
    public let buffers: AsyncStream<AVAudioPCMBuffer>

    private let engine = AVAudioEngine()
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let targetFormat: AVAudioFormat

    public init() throws {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.buffers = AsyncStream { c in cont = c }
        self.continuation = cont

        // Target format: 16 kHz mono Float32 — what openWakeWord and Silero want.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw VoicePOCError.audioEngineFailed(-1)
        }
        self.targetFormat = format
    }

    /// Explicitly request microphone authorization. On unsigned macOS CLI tools,
    /// `AVAudioEngine.start()` alone does NOT trigger the TCC prompt — macOS
    /// silently delivers zeroed buffers instead. Calling this method first
    /// surfaces the prompt and lets us fail fast if the user denies.
    public func requestMicrophoneAuthorization() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            Log.audio.info("mic authorization: already granted")
            return
        case .notDetermined:
            Log.audio.info("mic authorization: requesting…")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                Log.audio.info("mic authorization: granted")
            } else {
                Log.audio.error("mic authorization: denied by user")
                throw VoicePOCError.microphonePermissionDenied
            }
        case .denied, .restricted:
            Log.audio.error("mic authorization: previously denied or restricted")
            throw VoicePOCError.microphonePermissionDenied
        @unknown default:
            throw VoicePOCError.microphonePermissionDenied
        }
    }

    /// Begin capturing. The mic TCC prompt fires here on first run.
    public func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        Log.audio.info("input format: \(inputFormat.description)")

        // Tap at the input's native rate, then convert to 16 kHz mono in the tap.
        // Use maximum-quality mastering resampler so the 48→16 downsample preserves
        // as much speech detail as possible (matters for wake-word inference).
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        converter?.sampleRateConverterQuality = .max
        converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: self.targetFormat,
                frameCapacity: AVAudioFrameCount(self.targetFormat.sampleRate * Double(buffer.frameLength) / inputFormat.sampleRate) + 32
            )!
            var error: NSError?
            converter?.convert(to: outBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let error {
                Log.audio.error("conversion error: \(error.localizedDescription)")
                return
            }
            self.continuation.yield(outBuffer)
        }

        engine.prepare()
        try engine.start()
        Log.audio.info("audio engine started")
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
        Log.audio.info("audio engine stopped")
    }
}

/// Project-wide typed errors.
public enum VoicePOCError: Error {
    case microphonePermissionDenied
    case modelFileMissing(String)
    case wakeWordInferenceFailed(underlying: Error)
    case sttUnavailable
    case ttsStreamStalled
    case audioEngineFailed(OSStatus)
}
