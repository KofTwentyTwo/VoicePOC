import Foundation
import OnnxRuntimeBindings
// Note: do NOT import Logging here — that's swift-log's module name. The project's
// log helper is the `Log` enum (declared in Logging.swift).

/// openWakeWord 3-stage pipeline: waveform → mel → embedding → score.
///
/// Pipeline details (from openWakeWord 0.6 reference):
///   - Mel input:    [1, samples Int]              (Float32 PCM at 16 kHz)
///   - Mel output:   [1, 1, mel_frames, 32]        (Float32)
///   - Embed input:  [1, 76, 32, 1]                (sliding 76-frame window over mels)
///   - Embed output: [1, 1, 1, 96]
///   - Class input:  [1, 16, 96]                   (16-step rolling buffer of embeddings)
///   - Class output: [1, 1]                        (Float32 score 0..1)
///
/// Detection uses a 4-frame hysteresis: emit `true` only after 4 consecutive scores
/// above threshold.
public final class OpenWakeWordDetector {
    public let threshold: Float
    private let env: ORTEnv
    private let melSession: ORTSession
    private let embedSession: ORTSession
    private let classifierSession: ORTSession

    private var aboveCount: Int = 0
    private let hysteresisFrames = 4

    public init(modelsDirectory: URL = URL(fileURLWithPath: "Resources/models/openWakeWord"),
                threshold: Float = 0.5) throws {
        self.threshold = threshold
        let model = try HeyJarvisModel(modelsDirectory: modelsDirectory)
        self.env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        self.melSession        = try ORTSession(env: env, modelPath: model.melspectrogramURL.path, sessionOptions: opts)
        self.embedSession      = try ORTSession(env: env, modelPath: model.embeddingURL.path, sessionOptions: opts)
        self.classifierSession = try ORTSession(env: env, modelPath: model.classifierURL.path, sessionOptions: opts)
        Log.audio.info("openWakeWord pipeline loaded")
    }

    /// Score a Float32 PCM block at 16 kHz mono. Returns max classifier score across
    /// all classifier windows in the block. For the test, ~1.5 s of audio is sufficient.
    public func score(samples: [Float]) throws -> Float {
        do {
            let melFrames = try runMel(samples: samples)
            let embeddings = try runEmbed(melFrames: melFrames)
            let scores = try runClassifier(embeddings: embeddings)
            return scores.max() ?? 0
        } catch let err as VoicePOCError {
            throw err
        } catch {
            throw VoicePOCError.wakeWordInferenceFailed(underlying: error)
        }
    }

    /// Stream-mode: feed one buffer at a time, returns true on a confirmed wake
    /// (4 consecutive frames above threshold).
    public func consume(samples: [Float]) throws -> Bool {
        let s = try score(samples: samples)
        if s >= threshold {
            aboveCount += 1
            if aboveCount >= hysteresisFrames {
                aboveCount = 0
                return true
            }
        } else {
            aboveCount = 0
        }
        return false
    }

    // MARK: - Stage 1: Mel spectrogram

    private func runMel(samples: [Float]) throws -> [[Float]] {
        // Input: [1, samples]
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let mutableData = NSMutableData(data: data)
        let shape: [NSNumber] = [1, NSNumber(value: samples.count)]
        let tensor = try ORTValue(tensorData: mutableData, elementType: .float, shape: shape)
        let inputName = try melSession.inputNames().first!
        let outputName = try melSession.outputNames().first!
        let outputs = try melSession.run(
            withInputs: [inputName: tensor],
            outputNames: Set([outputName]),
            runOptions: nil
        )
        guard let out = outputs[outputName] else {
            throw VoicePOCError.wakeWordInferenceFailed(
                underlying: NSError(domain: "VoicePOC", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "mel output missing"]))
        }
        let info = try out.tensorTypeAndShapeInfo()
        let shapeOut = info.shape  // [1, 1, frames, 32]
        guard shapeOut.count >= 4 else {
            throw VoicePOCError.wakeWordInferenceFailed(
                underlying: NSError(domain: "VoicePOC", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "mel shape rank < 4: \(shapeOut)"]))
        }
        let frames = shapeOut[2].intValue
        let mels = shapeOut[3].intValue
        let raw = try out.tensorData() as Data
        let floats: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // Reshape into [frames][32]
        return (0..<frames).map { f in
            Array(floats[(f * mels)..<((f + 1) * mels)])
        }
    }

    // MARK: - Stage 2: Embedding

    private func runEmbed(melFrames: [[Float]]) throws -> [[Float]] {
        // Sliding window of 76 frames, stride 8 — produces one 96-dim embedding per window.
        let windowSize = 76
        let stride = 8
        guard melFrames.count >= windowSize else { return [] }

        var embeddings: [[Float]] = []
        var start = 0
        let inputName = try embedSession.inputNames().first!
        let outputName = try embedSession.outputNames().first!

        while start + windowSize <= melFrames.count {
            var flat: [Float] = []
            flat.reserveCapacity(windowSize * 32)
            for i in 0..<windowSize {
                flat.append(contentsOf: melFrames[start + i])
            }
            let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
            let mutable = NSMutableData(data: data)
            let shape: [NSNumber] = [1, 76, 32, 1]
            let tensor = try ORTValue(tensorData: mutable, elementType: .float, shape: shape)
            let outs = try embedSession.run(
                withInputs: [inputName: tensor],
                outputNames: Set([outputName]),
                runOptions: nil
            )
            guard let outVal = outs[outputName] else {
                throw VoicePOCError.wakeWordInferenceFailed(
                    underlying: NSError(domain: "VoicePOC", code: 3,
                                        userInfo: [NSLocalizedDescriptionKey: "embed output missing"]))
            }
            let raw = try outVal.tensorData() as Data
            let emb: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }  // 96
            embeddings.append(emb)
            start += stride
        }
        return embeddings
    }

    // MARK: - Stage 3: Classifier

    private func runClassifier(embeddings: [[Float]]) throws -> [Float] {
        // Sliding window of 16 embeddings, stride 1.
        let windowSize = 16
        guard embeddings.count >= windowSize else { return [] }

        var scores: [Float] = []
        let inputName = try classifierSession.inputNames().first!
        let outputName = try classifierSession.outputNames().first!

        for start in 0...(embeddings.count - windowSize) {
            var flat: [Float] = []
            flat.reserveCapacity(windowSize * 96)
            for i in 0..<windowSize {
                flat.append(contentsOf: embeddings[start + i])
            }
            let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
            let mutable = NSMutableData(data: data)
            let shape: [NSNumber] = [1, 16, 96]
            let tensor = try ORTValue(tensorData: mutable, elementType: .float, shape: shape)
            let outs = try classifierSession.run(
                withInputs: [inputName: tensor],
                outputNames: Set([outputName]),
                runOptions: nil
            )
            guard let outVal = outs[outputName] else {
                throw VoicePOCError.wakeWordInferenceFailed(
                    underlying: NSError(domain: "VoicePOC", code: 4,
                                        userInfo: [NSLocalizedDescriptionKey: "classifier output missing"]))
            }
            let raw = try outVal.tensorData() as Data
            let score: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            scores.append(score[0])
        }
        return scores
    }
}
