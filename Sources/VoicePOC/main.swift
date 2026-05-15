import Foundation
import AVFoundation

// MARK: - Configuration

let wakeThreshold: Float = 0.5
let hysteresisFrames = 4
let statusUpdateHz: Double = 10            // status line refresh rate
// openWakeWord pipeline minimum: 76 mel frames for first embedding (+stride 8 × 15
// more for the 16-embedding classifier window) → 196 mel frames @ ~50 fps → ~3.92 s.
// Use 4.0 s = 64_000 samples so the first classifier score is always available.
let windowSamples = 64_000                 // 4.0 s @ 16 kHz rolling window

// MARK: - Boot header

let defaultInput = AVCaptureDevice.default(for: .audio)
let deviceName = defaultInput?.localizedName ?? "(unknown)"

print("───────────────────────────────────────────────────────────────────────")
print("  VoicePOC v0.1  —  wake-word live smoke")
print("───────────────────────────────────────────────────────────────────────")
print("  Audio input device : \(deviceName)")
print("  Target format      : 1 ch, 16 kHz, Float32 (converted in tap)")
print("  Wake model         : hey_jarvis_v0.1.onnx")
print("  Wake threshold     : \(String(format: "%.2f", wakeThreshold))   (TTS Karen scored 0.43 in unit tests)")
print("  Hysteresis frames  : \(hysteresisFrames)")
print("  Rolling window     : \(windowSamples) samples (1.5 s)")
print("───────────────────────────────────────────────────────────────────────")
print()
print("  Say 'Hey Jarvis'.  WAKE! events scroll above the live status line.")
print("  Ctrl-C to exit.")
print()

// MARK: - Setup

let capture = try AudioCapture()
let detector = try OpenWakeWordDetector(threshold: wakeThreshold)
try await capture.requestMicrophoneAuthorization()
try capture.start()

// Shared state — mutated on the audio-consumer Task, read by the status Task.
// Wrap in an actor for Swift 6 concurrency safety.
actor LiveState {
    var lastRMS: Float = 0
    var lastScore: Float = 0
    var peakScore: Float = 0          // running max — held forever so user can see briefly-spiked values
    var peakScoreSinceReset: Float = 0 // rolling: decays after 3 sec of no new peak
    var lastPeakAt: Date = Date()
    var aboveCount: Int = 0
    var totalFrames: Int = 0
    var wakeCount: Int = 0
    var sessionStart = Date()

    func updateAudio(rms: Float, frames: Int) {
        lastRMS = rms
        totalFrames += frames
    }
    func updateScore(_ s: Float, threshold: Float) -> Bool {
        lastScore = s
        if s > peakScore {
            peakScore = s
        }
        // Sticky peak that decays after 3 sec of no new highs.
        let now = Date()
        if s >= peakScoreSinceReset {
            peakScoreSinceReset = s
            lastPeakAt = now
        } else if now.timeIntervalSince(lastPeakAt) > 3.0 {
            peakScoreSinceReset = s
            lastPeakAt = now
        }
        if s >= threshold {
            aboveCount += 1
            if aboveCount >= hysteresisFrames {
                aboveCount = 0
                wakeCount += 1
                return true
            }
        } else {
            aboveCount = 0
        }
        return false
    }
    func snapshot() -> (rms: Float, score: Float, peak: Float, stickyPeak: Float, hyst: Int, frames: Int, wakes: Int, uptime: TimeInterval) {
        return (lastRMS, lastScore, peakScore, peakScoreSinceReset, aboveCount, totalFrames, wakeCount, Date().timeIntervalSince(sessionStart))
    }
}

let state = LiveState()

// MARK: - Audio consumer task

let audioTask = Task {
    var rolling: [Float] = []

    for await buf in capture.buffers {
        guard let ptr = buf.floatChannelData?[0] else { continue }
        let n = Int(buf.frameLength)

        // Compute RMS for the just-arrived buffer.
        var sumSq: Float = 0
        for i in 0..<n { sumSq += ptr[i] * ptr[i] }
        let rms = n > 0 ? (sumSq / Float(n)).squareRoot() : 0
        await state.updateAudio(rms: rms, frames: n)

        // Append to rolling window.
        rolling.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
        if rolling.count > windowSamples {
            rolling.removeFirst(rolling.count - windowSamples)
        }

        // Score and update hysteresis once window is full.
        if rolling.count == windowSamples {
            do {
                let score = try detector.score(samples: rolling)
                let confirmed = await state.updateScore(score, threshold: wakeThreshold)
                if confirmed {
                    let ts = Date().formatted(date: .omitted, time: .standard)
                    // \r clears the live status line, then we print WAKE on its own line.
                    print("\r\u{001B}[2K  ★  WAKE!  \(ts)  (score \(String(format: "%.3f", score)))")
                }
            } catch {
                Log.audio.error("wake-word inference error: \(error)")
            }
        }
    }
}

// MARK: - Live status renderer

func bar(value: Float, max: Float, width: Int) -> String {
    let v = Swift.max(0, Swift.min(1, value / max))
    let filled = Int((Float(width) * v).rounded())
    let empty = width - filled
    return String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
}

let statusTask = Task {
    let interval = UInt64(1_000_000_000.0 / statusUpdateHz)
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        let s = await state.snapshot()
        let rmsBar = bar(value: s.rms, max: 0.3, width: 22)            // 0.3 ≈ shouting
        let scoreBar = bar(value: s.score, max: 1.0, width: 24)
        let hystStr = "\(s.hyst)/\(hysteresisFrames)"
        let uptime = String(format: "%02d:%02d", Int(s.uptime) / 60, Int(s.uptime) % 60)
        // stickyPeak holds the highest score seen in the last ~3 sec so brief spikes are visible
        // peak is the all-time max for the session
        let line = String(
            format: "\rRMS %@ %.3f  WAKE %@ %.2f  peak3s %.2f  max %.2f  hyst %@  thr %.2f  wakes %d  up %@",
            rmsBar, s.rms, scoreBar, s.score, s.stickyPeak, s.peak, hystStr, wakeThreshold, s.wakes, uptime
        )
        // Clear-to-end-of-line then write the new line.
        print("\u{001B}[2K" + line, terminator: "")
        // Force flush so the line actually appears between buffered prints.
        fflush(stdout)
    }
}

// MARK: - Run until Ctrl-C (1-hour ceiling)

try? await Task.sleep(for: .seconds(3600))
statusTask.cancel()
audioTask.cancel()
capture.stop()
print("\nDone.")
