import Foundation
import OnnxRuntimeBindings
// Note: do NOT import Logging here — that's swift-log's module name. The project's
// log helper is the `Log` enum (declared in Logging.swift).

/// Silero VAD v6.2.1 inference.
///
/// Input contract:
///   - Frame: 512 samples, Float32, 16 kHz mono (= 32 ms per frame), normalized to [-1, 1].
///     Internally scaled to PCM16 integer range before passing to the ONNX model,
///     which expects amplitude in the ±32768 range.
///   - State: [2, 1, 128] internal state carried across calls (managed automatically).
///   - Sample rate: hardcoded to 16000 (8000 Hz path not used by VoicePOC).
///
/// Output: speech probability ∈ [0, 1]. Apply your own threshold (typically 0.5)
/// plus a "hangover" (continue treating frames as speech for ~600 ms after last
/// detection) to gate end-of-utterance cleanly.
///
/// Silero v6 VAD note: the model uses an STFT-based architecture. On macOS TTS
/// audio (e.g., `say -v Karen`) it typically peaks at 0.2–0.3; real microphone
/// speech typically exceeds 0.5.
public final class SileroVAD {

    /// Errors specific to SileroVAD operations.
    public enum SileroError: Error {
        case wrongFrameSize(Int)
        case outputMissing(String)
    }

    private let env: ORTEnv
    private let session: ORTSession
    private var state: [Float]
    private let sampleRate: Int64 = 16_000

    // Tensor name slots — discovered at init from the model.
    private let inputName: String
    private let stateName: String
    private let srName: String
    private let outputName: String
    private let stateOutName: String

    public init(modelURL: URL = URL(fileURLWithPath: "Resources/models/silero/silero_vad_v6_2_1.onnx")) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VoicePOCError.modelFileMissing(modelURL.path)
        }
        self.env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: opts)

        // Discover actual tensor names from the model — they can vary across
        // Silero releases. We match by position:
        //   inputs[0] = waveform ("input")
        //   inputs[1] = lstm/stft state ("state")
        //   inputs[2] = sample rate ("sr")
        //   outputs[0] = speech probability ("output")
        //   outputs[1] = updated state ("stateN")
        let inputs = try session.inputNames()
        let outputs = try session.outputNames()
        Log.audio.info("silero VAD inputs: \(inputs)")
        Log.audio.info("silero VAD outputs: \(outputs)")

        guard inputs.count >= 3 else {
            throw VoicePOCError.modelFileMissing("Silero model has fewer than 3 inputs: \(inputs)")
        }
        guard outputs.count >= 2 else {
            throw VoicePOCError.modelFileMissing("Silero model has fewer than 2 outputs: \(outputs)")
        }

        self.inputName    = inputs[0]
        self.stateName    = inputs[1]
        self.srName       = inputs[2]
        self.outputName   = outputs[0]
        self.stateOutName = outputs[1]

        self.state = Array(repeating: 0, count: 2 * 1 * 128)
        Log.audio.info("silero VAD loaded (input=\(self.inputName) state=\(self.stateName) sr=\(self.srName) → output=\(self.outputName) stateN=\(self.stateOutName))")
    }

    /// Reset internal state — call at the start of each new STT session.
    public func reset() {
        state = Array(repeating: 0, count: 2 * 1 * 128)
    }

    /// Score one 512-sample frame (normalized Float32 in [-1, 1] at 16 kHz).
    /// Returns speech probability ∈ [0, 1].
    public func probability(frame: [Float]) throws -> Float {
        guard frame.count == 512 else {
            throw SileroError.wrongFrameSize(frame.count)
        }

        // Silero v6.2.1 ONNX export expects audio in PCM16 integer-amplitude range
        // (roughly ±32768). AudioCapture produces normalized floats in [-1, 1];
        // scale here so callers don't need to know about this implementation detail.
        let scaledFrame = frame.map { $0 * 32768.0 }

        // Input tensor: [1, 512] Float32
        let inputData = NSMutableData(data: scaledFrame.withUnsafeBufferPointer { Data(buffer: $0) })
        let inputTensor = try ORTValue(
            tensorData: inputData,
            elementType: .float,
            shape: [NSNumber(value: 1), NSNumber(value: 512)]
        )

        // State tensor: [2, 1, 128] Float32
        let stateData = NSMutableData(data: state.withUnsafeBufferPointer { Data(buffer: $0) })
        let stateTensor = try ORTValue(
            tensorData: stateData,
            elementType: .float,
            shape: [NSNumber(value: 2), NSNumber(value: 1), NSNumber(value: 128)]
        )

        // Sample rate tensor: [1] Int64
        let srValue = sampleRate
        let srBytes = withUnsafeBytes(of: srValue) { Data($0) }
        let srData = NSMutableData(data: srBytes)
        let srTensor = try ORTValue(
            tensorData: srData,
            elementType: .int64,
            shape: [NSNumber(value: 1)]
        )

        let outputs = try session.run(
            withInputs: [
                inputName:  inputTensor,
                stateName:  stateTensor,
                srName:     srTensor,
            ],
            outputNames: Set([outputName, stateOutName]),
            runOptions: nil
        )

        // Update internal state for next call.
        if let stateOut = outputs[stateOutName],
           let stateRaw = try? stateOut.tensorData() as Data {
            self.state = stateRaw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        // Extract speech probability.
        guard let probOut = outputs[outputName] else {
            throw SileroError.outputMissing(outputName)
        }
        let probData: Data = try probOut.tensorData() as Data
        let probs: [Float] = probData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return probs.first ?? 0
    }
}
