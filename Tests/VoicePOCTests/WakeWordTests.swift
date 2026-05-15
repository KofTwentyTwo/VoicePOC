import XCTest
import AVFoundation
@testable import VoicePOC

final class WakeWordTests: XCTestCase {
    // Skip these tests if fixtures aren't recorded yet — the orchestrator
    // records them after the implementer's code lands.
    private func loadFixture(named name: String) throws -> [Float]? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures") else {
            // Fixture not yet present — test is informational only.
            print("[skip] fixture \(name).wav not present yet")
            return nil
        }
        return try loadPCM16Mono16k(from: url)
    }

    func testDetectorLoadsWithoutError() throws {
        // Smoke: detector can find and load all 3 ONNX models.
        _ = try OpenWakeWordDetector()
    }

    func testDetectorScoresWakeClipAboveThreshold() throws {
        let detector = try OpenWakeWordDetector()
        guard let samples = try loadFixture(named: "hey_jarvis_clip") else {
            throw XCTSkip("hey_jarvis_clip.wav fixture not present")
        }
        let score = try detector.score(samples: samples)
        print("[wake] score for hey_jarvis_clip = \(score)")
        XCTAssertGreaterThan(score, 0.5, "wake clip should score > 0.5; got \(score)")
    }

    func testDetectorScoresSilenceBelowThreshold() throws {
        let detector = try OpenWakeWordDetector()
        guard let samples = try loadFixture(named: "silence") else {
            throw XCTSkip("silence.wav fixture not present")
        }
        let score = try detector.score(samples: samples)
        print("[silence] score for silence = \(score)")
        XCTAssertLessThan(score, 0.1, "silence should score < 0.1; got \(score)")
    }

    // Helper: load a 16 kHz mono PCM16 WAV into a Float32 array normalized to [-1, 1].
    private func loadPCM16Mono16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let ptr = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
    }
}
