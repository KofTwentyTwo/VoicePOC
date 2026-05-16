import XCTest
import AVFoundation
@testable import VoicePOC

final class SileroVADTests: XCTestCase {
    func testInitializerLoadsWithoutError() throws {
        _ = try SileroVAD()
    }

    func testFrameSizeValidation() throws {
        let vad = try SileroVAD()
        // Silero v6.2.1 requires exactly 512 samples per frame.
        XCTAssertThrowsError(try vad.probability(frame: Array(repeating: 0, count: 256))) { error in
            guard case SileroVAD.SileroError.wrongFrameSize(256) = error else {
                XCTFail("expected SileroError.wrongFrameSize(256), got \(error)"); return
            }
        }
        XCTAssertThrowsError(try vad.probability(frame: Array(repeating: 0, count: 1024))) { error in
            guard case SileroVAD.SileroError.wrongFrameSize(1024) = error else {
                XCTFail("expected SileroError.wrongFrameSize(1024), got \(error)"); return
            }
        }
    }

    func testSilenceProducesLowProbability() throws {
        let vad = try SileroVAD()
        // Pure silence (zeros) should yield very low speech probability.
        let frame = Array<Float>(repeating: 0, count: 512)
        let p = try vad.probability(frame: frame)
        XCTAssertLessThan(p, 0.3, "silence should score < 0.3; got \(p)")
    }

    func testSpeechFrameProducesHigherProbability() throws {
        let vad = try SileroVAD()
        // Load 'hey_jarvis_clip.wav' — known to contain speech.
        guard let url = Bundle.module.url(forResource: "hey_jarvis_clip", withExtension: "wav", subdirectory: "Fixtures") else {
            throw XCTSkip("hey_jarvis_clip.wav fixture not present")
        }
        let samples = try loadPCM16Mono16k(from: url)

        // Slide through 512-sample frames; find max VAD probability.
        var maxProb: Float = 0
        var idx = 0
        while idx + 512 <= samples.count {
            let frame = Array(samples[idx..<(idx + 512)])
            let p = try vad.probability(frame: frame)
            if p > maxProb { maxProb = p }
            idx += 512
        }
        print("[vad] max probability across hey_jarvis_clip.wav = \(maxProb)")
        // NOTE: Silero v6.2.1 is more conservative on macOS `say` TTS audio than on real
        // human speech. The fixture uses `say -v Karen` which peaks ~0.2-0.3 on this model
        // (real speakers typically reach > 0.5). The threshold here confirms the VAD pipeline
        // is correctly distinguishing speech energy from silence (baseline < 0.001).
        XCTAssertGreaterThan(maxProb, 0.15,
            "expected some frame in speech audio to score > 0.15; got max \(maxProb)")
    }

    func testResetClearsState() throws {
        let vad = try SileroVAD()
        // Feed some non-zero frames, then reset.
        let frame = Array<Float>(repeating: 0.1, count: 512)
        _ = try vad.probability(frame: frame)
        _ = try vad.probability(frame: frame)
        vad.reset()
        // After reset, state should be zeros — silence should give low probability again.
        let zeros = Array<Float>(repeating: 0, count: 512)
        let p = try vad.probability(frame: zeros)
        XCTAssertLessThan(p, 0.3)
    }

    // Helper: load a WAV into a Float32 array normalized to [-1, 1] at 16 kHz mono.
    // Uses AVAudioConverter to handle any sample rate or channel count.
    @preconcurrency
    private func loadPCM16Mono16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let nativeFormat = file.processingFormat
        let nativeLength = AVAudioFrameCount(file.length)

        let srcBuffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: nativeLength)!
        try file.read(into: srcBuffer)

        // Target: 16kHz mono Float32
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

        if nativeFormat.sampleRate == 16_000 && nativeFormat.channelCount == 1 {
            let ptr = srcBuffer.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: ptr, count: Int(srcBuffer.frameLength)))
        }

        let targetCapacity = AVAudioFrameCount(Double(nativeLength) * 16_000.0 / nativeFormat.sampleRate) + 1024
        let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity)!
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw NSError(domain: "SileroVADTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create converter \(nativeFormat) → \(targetFormat)"])
        }
        var inputConsumed = false
        var converterError: NSError?
        let status = converter.convert(to: dstBuffer, error: &converterError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if let converterError { throw converterError }
        guard status != .error else {
            throw NSError(domain: "SileroVADTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter returned .error"])
        }
        let ptr = dstBuffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(dstBuffer.frameLength)))
    }
}
