import Foundation
import AVFoundation
import Logging

/// Owns a single `AVAudioEngine` with one tap at 16 kHz mono Float32.
///
/// Push model: buffers are placed onto an `AsyncStream` that downstream stages
/// consume one at a time. Only one consumer should be iterating `buffers` at any
/// moment; transitions between stages cancel the current iterator.
public final class AudioCapture: @unchecked Sendable {
    /// A fresh AsyncStream subscription. Each call returns a new stream — the
    /// underlying audio tap fans out to every active subscription. This lets
    /// multiple consumers (e.g., ConversationCoordinator opening a new
    /// "captureUtterance" loop per turn) each get their own iterator.
    ///
    /// Older buffers are NOT replayed; subscribers only receive buffers
    /// produced after their subscription started.
    public var buffers: AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            let id = self.addContinuation(continuation)
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat

    // Multi-consumer fan-out state.
    private let lock = NSLock()
    private var nextSubscriberID: Int = 0
    private var continuations: [Int: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]

    private func addContinuation(_ c: AsyncStream<AVAudioPCMBuffer>.Continuation) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextSubscriberID += 1
        let id = nextSubscriberID
        continuations[id] = c
        return id
    }

    private func removeContinuation(id: Int) {
        lock.lock(); defer { lock.unlock() }
        continuations.removeValue(forKey: id)
    }

    private func broadcast(_ buffer: AVAudioPCMBuffer) {
        // AVAudioPCMBuffer isn't Sendable in Swift 6, but in this code path
        // the buffer is freshly produced by the converter inside the tap
        // closure and is not mutated after this point. Wrap in an unsafe-
        // Sendable box so the AsyncStream yield is allowed by the strict
        // concurrency checker.
        struct UnsafeSendableBuffer: @unchecked Sendable { let buf: AVAudioPCMBuffer }
        let boxed = UnsafeSendableBuffer(buf: buffer)
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        for c in snapshot {
            c.yield(boxed.buf)
        }
    }

    private func finishAll() {
        lock.lock()
        let snapshot = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in snapshot { c.finish() }
    }

    public init() throws {
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
            self.broadcast(outBuffer)
        }

        engine.prepare()
        try engine.start()
        Log.audio.info("audio engine started")
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        finishAll()
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
