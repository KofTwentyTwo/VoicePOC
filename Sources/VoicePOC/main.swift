import Foundation
import AVFoundation
import Darwin   // for termios + getchar

// MARK: - Configuration

let wakeThreshold: Float = 0.30
let hysteresisFrames = 4
let statusUpdateHz: Double = 10            // status line refresh rate
// openWakeWord pipeline minimum: 76 mel frames for first embedding (+stride 8 × 15
// more for the 16-embedding classifier window) → 196 mel frames @ ~50 fps → ~3.92 s.
// Use 4.0 s = 64_000 samples so the first classifier score is always available.
let windowSamples = 64_000                 // 4.0 s @ 16 kHz rolling window
let recordingFile = "/tmp/voicepoc-last-recording.wav"

// MARK: - Boot header

let defaultInput = AVCaptureDevice.default(for: .audio)
let deviceName = defaultInput?.localizedName ?? "(unknown)"

print("───────────────────────────────────────────────────────────────────────")
print("  VoicePOC v0.1  —  wake-word debug (press-to-record)")
print("───────────────────────────────────────────────────────────────────────")
print("  Audio input device : \(deviceName)")
print("  Target format      : 1 ch, 16 kHz, Float32 (converted in tap @ max quality)")
print("  Wake model         : hey_jarvis_v0.1.onnx")
print("  Wake threshold     : \(String(format: "%.2f", wakeThreshold))")
print("  Hysteresis frames  : \(hysteresisFrames)")
print("  Rolling window     : \(windowSamples) samples (4.0 s)")
print("  Recording file     : \(recordingFile)")
print("───────────────────────────────────────────────────────────────────────")
print()
print("  KEYS:")
print("    1   start recording (mic captures; wake detector runs on the buffer)")
print("    1   (again) stop recording — prints peak score and saves WAV")
print("    2   play back the last recording")
print("    q   quit")
print()

// MARK: - Setup

let capture = try AudioCapture()
let detector = try OpenWakeWordDetector(threshold: wakeThreshold)
try await capture.requestMicrophoneAuthorization()
try capture.start()

// MARK: - Speaker check

final class StartupSpeaker: NSObject, @preconcurrency AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let synth = AVSpeechSynthesizer()
    var done: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) async {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let premium = voices.first { $0.language.hasPrefix("en") && $0.quality == .premium }
        let enhanced = voices.first { $0.language.hasPrefix("en") && $0.quality == .enhanced }
        let voice = premium ?? enhanced ?? AVSpeechSynthesisVoice(language: "en-US")!
        print("  Speaker check        : \(voice.name) (quality \(voice.quality.rawValue == 3 ? "premium" : voice.quality.rawValue == 2 ? "enhanced" : "default"))")
        let utt = AVSpeechUtterance(string: text)
        utt.voice = voice
        utt.rate = AVSpeechUtteranceDefaultSpeechRate
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.done = cont
            self.synth.speak(utt)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        done?.resume(); done = nil
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        done?.resume(); done = nil
    }
}

print("  Speaker test         : speaking 'VoicePOC debug ready' …")
let speaker = StartupSpeaker()
await speaker.speak("Voice POC debug ready. Press one to record, press two to play back.")
print("  Speaker test         : ✓ done")
print()

// MARK: - Detector self-test against the bundled fixture
do {
    let fixtureURL = URL(fileURLWithPath: "Tests/VoicePOCTests/Fixtures/hey_jarvis_clip.wav")
    if FileManager.default.fileExists(atPath: fixtureURL.path) {
        let file = try AVAudioFile(forReading: fixtureURL)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let ptr = buf.floatChannelData![0]
        let samples = Array(UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
        let baseline = try detector.score(samples: samples)
        print("  Detector self-test   : hey_jarvis_clip.wav scores \(String(format: "%.3f", baseline)) (expected ~0.428)")
        if baseline > 0.35 {
            print("                       : ✓ detector + model + path all working.")
        } else {
            print("                       : ⚠ score unexpectedly low — model/path issue.")
        }
    } else {
        print("  Detector self-test   : SKIP (fixture missing)")
    }
} catch {
    print("  Detector self-test   : ERROR \(error)")
}
print()
print("  Press 1 to start your first recording.")
print()

// MARK: - Recorder + state actor

actor State {
    var recording = false
    var samples: [Float] = []
    var lastRecording: [Float] = []   // most recent finalized recording
    var liveScore: Float = 0           // current rolling-window score (only updated while recording)
    var peakScoreThisRecording: Float = 0
    var lastRMS: Float = 0

    var totalRecordings: Int = 0
    var totalFrames: Int = 0

    func startRecording() {
        recording = true
        samples = []
        peakScoreThisRecording = 0
        liveScore = 0
    }

    /// Returns (durationSec, peakScore, samples) for the just-ended recording.
    func stopRecording() -> (durationSec: Double, peak: Float, samples: [Float]) {
        recording = false
        let s = samples
        lastRecording = s
        totalRecordings += 1
        let dur = Double(s.count) / 16_000.0
        let peak = peakScoreThisRecording
        return (dur, peak, s)
    }

    func feed(_ block: [Float]) -> Bool {
        if recording {
            samples.append(contentsOf: block)
            return true
        }
        return false
    }

    func updateAudio(rms: Float, frames: Int) {
        lastRMS = rms
        totalFrames += frames
    }
    func updateScore(_ s: Float) {
        liveScore = s
        if s > peakScoreThisRecording { peakScoreThisRecording = s }
    }
    func resetLiveScoreIfIdle() {
        if !recording { liveScore = 0 }
    }

    func snapshot() -> (recording: Bool, samples: Int, peak: Float, live: Float, rms: Float, totalRecs: Int) {
        (recording, samples.count, peakScoreThisRecording, liveScore, lastRMS, totalRecordings)
    }
    func getLastRecording() -> [Float] { lastRecording }
}

let state = State()

// MARK: - Audio consumer task

let audioTask = Task {
    var rolling: [Float] = []

    for await buf in capture.buffers {
        guard let ptr = buf.floatChannelData?[0] else { continue }
        let n = Int(buf.frameLength)

        // Always compute RMS (so the bar moves even when not recording).
        var sumSq: Float = 0
        for i in 0..<n { sumSq += ptr[i] * ptr[i] }
        let rms = n > 0 ? (sumSq / Float(n)).squareRoot() : 0
        await state.updateAudio(rms: rms, frames: n)

        // Feed the recorder if it's active.
        let block = Array(UnsafeBufferPointer(start: ptr, count: n))
        let wasRecorded = await state.feed(block)

        if wasRecorded {
            // Maintain the 4-sec rolling window for live scoring during recording.
            rolling.append(contentsOf: block)
            if rolling.count > windowSamples {
                rolling.removeFirst(rolling.count - windowSamples)
            }
            if rolling.count == windowSamples {
                if let score = try? detector.score(samples: rolling) {
                    await state.updateScore(score)
                }
            }
        } else {
            // Not recording — clear rolling so the next session starts fresh.
            if !rolling.isEmpty { rolling.removeAll(keepingCapacity: true) }
            await state.resetLiveScoreIfIdle()
        }
    }
}

// MARK: - Status renderer

func bar(value: Float, max: Float, width: Int) -> String {
    let v = Swift.max(0, Swift.min(1, value / max))
    let filled = Int((Float(width) * v).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

let statusTask = Task {
    let interval = UInt64(1_000_000_000.0 / statusUpdateHz)
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        let s = await state.snapshot()
        let rmsBar = bar(value: s.rms, max: 0.3, width: 22)
        let wakeBar = bar(value: s.live, max: 1.0, width: 24)
        let mode = s.recording ? "● REC" : "  idle"
        let durSec = Double(s.samples) / 16_000.0
        let line = String(
            format: "\r\(mode)  RMS %@ %.3f  WAKE %@ %.2f  peak %.2f  rec %.1fs  total %d",
            rmsBar, s.rms, wakeBar, s.live, s.peak, durSec, s.totalRecs
        )
        print("\u{001B}[2K" + line, terminator: "")
        fflush(stdout)
    }
}

// MARK: - Keyboard reader (raw terminal mode)

// Save original terminal settings. Marked nonisolated(unsafe) because we only
// touch it on the main thread or after task cancellation — termios access
// itself is not thread-safe but our usage is bounded.
nonisolated(unsafe) var origTermios = termios()
tcgetattr(STDIN_FILENO, &origTermios)

// Enter raw mode: disable canonical line buffering + echo. Keep ISIG on so Ctrl-C still signals.
var rawTermios = origTermios
rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios)

// Ensure we restore termios on Ctrl-C.
signal(SIGINT) { _ in
    var t = termios()
    tcgetattr(STDIN_FILENO, &t)
    t.c_lflag |= tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
    print("\nInterrupted.")
    exit(0)
}

func writeWAV(samples: [Float], to path: String) throws {
    let url = URL(fileURLWithPath: path)
    // 16-bit PCM mono 16 kHz — universally playable.
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
        buf.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
    }
    try file.write(from: buf)
}

@MainActor
final class PlaybackController: @unchecked Sendable {
    var player: AVAudioPlayer?
    func play(_ path: String) async throws {
        let url = URL(fileURLWithPath: path)
        let p = try AVAudioPlayer(contentsOf: url)
        p.prepareToPlay()
        p.play()
        self.player = p
        // Wait for completion.
        while p.isPlaying {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
let playback = await PlaybackController()

// Keyboard task: blocks on getchar(), so we run it on a background Task.
let keyTask = Task.detached {
    while !Task.isCancelled {
        let ch = getchar()
        if ch == EOF { break }
        switch UnicodeScalar(UInt8(ch & 0xFF)) {
        case "1":
            let snap = await state.snapshot()
            if snap.recording {
                // Stop and report.
                let result = await state.stopRecording()
                let verdict = result.peak >= wakeThreshold ? "→ WOULD FIRE WAKE" : "→ below threshold \(String(format: "%.2f", wakeThreshold))"
                print(String(format: "\r\u{001B}[2K  ⏹  stopped:  %.2fs of audio  peak %.3f  \(verdict)", result.durationSec, result.peak))
                if !result.samples.isEmpty {
                    do {
                        try writeWAV(samples: result.samples, to: recordingFile)
                        print("       saved → \(recordingFile)")
                        print("       press 2 to play back")
                    } catch {
                        print("       write failed: \(error)")
                    }
                }
            } else {
                await state.startRecording()
                print("\r\u{001B}[2K  ⏺  recording started — speak now, press 1 again to stop")
            }
        case "2":
            let samples = await state.getLastRecording()
            if samples.isEmpty {
                print("\r\u{001B}[2K  (no recording yet — press 1 first)")
            } else {
                print(String(format: "\r\u{001B}[2K  ▶  playing %.2fs back…", Double(samples.count) / 16_000.0))
                do {
                    try await playback.play(recordingFile)
                    print("\r\u{001B}[2K  ▶  playback done")
                } catch {
                    print("\r\u{001B}[2K  playback failed: \(error)")
                }
            }
        case "q", "Q":
            print("\r\u{001B}[2K  bye.")
            // Restore terminal and exit.
            tcsetattr(STDIN_FILENO, TCSANOW, &origTermios)
            exit(0)
        default:
            break  // ignore other keys
        }
    }
}

// MARK: - Run

try? await Task.sleep(for: .seconds(3600))
keyTask.cancel()
statusTask.cancel()
audioTask.cancel()
capture.stop()
tcsetattr(STDIN_FILENO, TCSANOW, &origTermios)
print("\nDone.")
