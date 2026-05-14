import Foundation
import AVFoundation
import Logging

print("VoicePOC v0.1 — audio capture smoke test")
print("This will request microphone permission on first run.")
print("Speak for ~5 seconds; RMS values will print. Press Ctrl-C to exit.")
print()

let capture = try AudioCapture()
try await capture.requestMicrophoneAuthorization()
try capture.start()

let task = Task {
    var frameCount = 0
    for await buffer in capture.buffers {
        let rms = computeRMS(buffer: buffer)
        frameCount += 1
        if frameCount % 50 == 0 {  // print ~1x/sec at 1024-frame buffers @ 16 kHz
            Log.audio.info("rms=\(String(format: "%.4f", rms)) frames=\(frameCount)")
        }
    }
}

// Run for 10 seconds then exit cleanly.
try await Task.sleep(for: .seconds(10))
capture.stop()
task.cancel()
print("Done.")

func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData?[0] else { return 0 }
    let frameLength = Int(buffer.frameLength)
    var sumSquares: Float = 0
    for i in 0..<frameLength {
        sumSquares += channelData[i] * channelData[i]
    }
    return sqrt(sumSquares / Float(frameLength))
}
