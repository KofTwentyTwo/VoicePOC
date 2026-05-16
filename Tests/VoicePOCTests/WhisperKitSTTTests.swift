import XCTest
import AVFoundation
@testable import VoicePOC

final class WhisperKitSTTTests: XCTestCase {
    func testTranscribesHeyJarvisClipFixture() async throws {
        // Skipped by default — Whisper model download is ~150 MB and takes
        // ~30 s on first run.
        // Run with: WHISPER_REAL=1 swift test --filter WhisperKitSTTTests
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WHISPER_REAL"] == "1",
                          "set WHISPER_REAL=1 to enable real-Whisper integration test")

        let stt = try await WhisperKitSTT()
        guard let url = Bundle.module.url(forResource: "hey_jarvis_clip", withExtension: "wav", subdirectory: "Fixtures") else {
            XCTFail("fixture not found"); return
        }
        let transcript = try await stt.transcribeFile(url: url)
        let lowered = transcript.lowercased()
        print("[whisper] transcript: '\(transcript)'")
        XCTAssertTrue(lowered.contains("jarvis") || lowered.contains("hey"),
                      "expected transcript to mention 'hey' or 'jarvis'; got '\(transcript)'")
    }

    func testInitializerLoadsWithoutError() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WHISPER_REAL"] == "1",
                          "set WHISPER_REAL=1 to enable real-Whisper integration test")
        _ = try await WhisperKitSTT()
    }
}
