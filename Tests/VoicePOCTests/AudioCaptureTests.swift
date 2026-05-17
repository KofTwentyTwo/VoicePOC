import XCTest
import AVFoundation
@testable import VoicePOCKit

final class AudioCaptureTests: XCTestCase {
    func testAudioCaptureExposesAsyncStream() async throws {
        let capture = try AudioCapture()
        // Compile-time check that the property exists and has the expected type.
        let _: AsyncStream<AVAudioPCMBuffer> = capture.buffers
    }
}
