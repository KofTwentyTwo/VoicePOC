import Foundation
import AVFoundation
import AppKit
import Darwin   // for termios + getchar

// MARK: - Configuration

let defaultHotkeyKeyCode: UInt16 = 122          // F1
let statusUpdateHz: Double = 4
let endOfTurnSilenceMs = 800
let sessionIdleTimeoutSec: Double = 10
let bootBanner = "Voice POC ready. Press F1 to start a conversation, or press space in this terminal."

// MARK: - Boot header

let defaultInput = AVCaptureDevice.default(for: .audio)
let deviceName = defaultInput?.localizedName ?? "(unknown)"

print("───────────────────────────────────────────────────────────────────────")
print("  VoicePOC v0.1  —  local conversation (Path 3)")
print("───────────────────────────────────────────────────────────────────────")
print("  Audio input device : \(deviceName)")
print("  Target format      : 1 ch, 16 kHz, Float32 (converted in tap @ max quality)")
print("  Hotkey             : F1 (keyCode \(defaultHotkeyKeyCode))   — fallback: space (this terminal)")
print("  End-of-turn        : \(endOfTurnSilenceMs) ms silence (VAD)")
print("  Idle timeout       : \(Int(sessionIdleTimeoutSec)) s no-speech → idle")
print("  Status refresh     : \(Int(statusUpdateHz)) Hz")
print("───────────────────────────────────────────────────────────────────────")
print()

// MARK: - Initialization

print("  [init] AudioCapture …")
let capture = try AudioCapture()
try await capture.requestMicrophoneAuthorization()
try capture.start()
print("  [init] AudioCapture ✓")

print("  [init] SileroVAD …")
let vad = try SileroVAD()
print("  [init] SileroVAD ✓")

print("  [init] WhisperKit (downloading on first run, ~150 MB; may take ~30 s) …")
let stt = try await WhisperKitSTT()
print("  [init] WhisperKit ✓ (model=\(stt.modelName))")

print("  [init] OllamaClient …")
let ollama = OllamaClient()
let ollamaUp = (try? await ollama.healthCheck()) ?? false
if ollamaUp {
    print("  [init] Ollama ✓ (gemma4:latest reachable)")
} else {
    print("  [init] Ollama ✗")
    print("         The conversation will fail without Ollama.")
    print("         Fix:")
    print("           1. Install Ollama:   brew install ollama   (or https://ollama.com)")
    print("           2. Start the server: ollama serve         (in another shell)")
    print("           3. Pull the model:   ollama pull gemma4:latest")
    print("         Continuing anyway so you can verify the rest of the stack.")
}

print("  [init] AVSpeechTTS …")
let tts = AVSpeechTTS()
print("  [init] AVSpeechTTS ✓ (voice='\(tts.voice.name)')")
print()

// MARK: - Boot announcement

print("  [boot] speaking startup banner …")
try? await tts.speak(bootBanner)
print("  [boot] ✓")
print()

// MARK: - Coordinator + hotkey

let coordinator = ConversationCoordinator(
    capture: capture,
    stt: stt,
    vad: vad,
    ollama: ollama,
    tts: tts,
    endOfTurnSilenceMs: endOfTurnSilenceMs,
    sessionIdleTimeoutSec: sessionIdleTimeoutSec
)

let hotkey = HotkeyMonitor(keyCode: defaultHotkeyKeyCode) {
    Task { await coordinator.toggle() }
}
hotkey.start()

// MARK: - Status renderer

let statusTask = Task {
    let interval = UInt64(1_000_000_000.0 / statusUpdateHz)
    var spinIdx = 0
    let spin = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        let s = await coordinator.status()
        spinIdx = (spinIdx + 1) % spin.count
        let line: String
        switch s.state {
        case .idle:
            line = "  idle      — press F1 (or space) to start a conversation"
        case .listening:
            let elapsed = s.listeningElapsedSec ?? 0
            let phase = s.speechDetected ? "speech" : "waiting"
            line = String(format: "  %@ listening  (%.1fs, %@)", spin[spinIdx], elapsed, phase)
        case .thinking:
            line = "  \(spin[spinIdx]) thinking   (asking gemma4:latest …)"
        case .speaking:
            line = "  \(spin[spinIdx]) speaking   (\(s.streamedTokens) chunks streamed; last transcript len=\(s.lastTranscriptLen))"
        }
        print("\u{001B}[2K\r" + line, terminator: "")
        fflush(stdout)
    }
}

// MARK: - Stdin keyboard reader (fallback toggle + quit)

// Save original terminal settings. Marked nonisolated(unsafe) because we only
// touch it on the main thread or during signal handling.
nonisolated(unsafe) var origTermios = termios()
tcgetattr(STDIN_FILENO, &origTermios)

var rawTermios = origTermios
rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios)

// Restore termios on Ctrl-C.
signal(SIGINT) { _ in
    var t = termios()
    tcgetattr(STDIN_FILENO, &t)
    t.c_lflag |= tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
    print("\nInterrupted.")
    exit(0)
}

let keyTask = Task.detached {
    while !Task.isCancelled {
        let ch = getchar()
        if ch == EOF { break }
        let scalar = UnicodeScalar(UInt8(ch & 0xFF))
        switch scalar {
        case " ":
            print("\r\u{001B}[2K  (stdin) toggle")
            await coordinator.toggle()
        case "q", "Q":
            print("\r\u{001B}[2K  bye.")
            tcsetattr(STDIN_FILENO, TCSANOW, &origTermios)
            exit(0)
        default:
            break
        }
    }
}

// MARK: - Run forever (until Ctrl-C / q)

// AppKit must run its run loop on the main thread for NSEvent monitors to
// deliver. `RunLoop.main.run()` and `CFRunLoopRun()` are both unavailable
// in async contexts (Swift 6). `dispatchMain()` hands the main thread over
// to libdispatch, which drives the main run loop and never returns — exactly
// what we want. The status, key, and conversation tasks all run on the Swift
// concurrency thread pool.
dispatchMain()

// Unreachable in practice, but keep cleanup for completeness:
keyTask.cancel()
statusTask.cancel()
hotkey.stop()
capture.stop()
tcsetattr(STDIN_FILENO, TCSANOW, &origTermios)
print("\nDone.")
