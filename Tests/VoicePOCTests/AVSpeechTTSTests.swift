import XCTest
@testable import VoicePOC

final class AVSpeechTTSTests: XCTestCase {
    /// Conforms to the protocol — compile-time check.
    func testConformsToTTSProvider() {
        let tts = AVSpeechTTS()
        let _: TTSProvider = tts
    }

    /// Speak a short utterance and resolve cleanly.
    /// Audible by default — set TTS_SILENT=1 to skip if running headless / shared environment.
    func testSpeakReturnsWhenComplete() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TTS_SILENT"] == "1",
                      "TTS_SILENT=1 → skipping audible test")
        let tts = AVSpeechTTS()
        let start = Date()
        try await tts.speak("test")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.05, "speak should take at least 50 ms for a 1-word utterance")
        XCTAssertLessThan(elapsed, 5.0, "speak should resolve within 5 s")
    }
}

// XCTest has XCTSkipUnless but not a clean XCTSkipIf — small shim.
func XCTSkipIf(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String) throws {
    if try condition() { throw XCTSkip(message()) }
}
