import Cocoa
import AVFoundation
import VoicePOCKit

/// VoicePOC's NSApplication delegate.
///
/// Owns the long-lived components (AudioCapture, STT, VAD, Ollama, TTS) and
/// the ConversationCoordinator that stitches them together. Wires up the
/// global F1 hotkey, the menu-bar status item (Quit only for now), and the
/// boot banner.
///
/// All blocking initialization happens inside a `Task` from
/// `applicationDidFinishLaunching` so the AppKit run loop is already pumping
/// before we touch AVSpeech / WhisperKit / Ollama. This avoids deadlocks
/// where a callback would have nowhere to deliver.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Hotkey
    private let defaultHotkeyKeyCode: UInt16 = 122          // F1

    // Conversation tuning
    private let endOfTurnSilenceMs = 800
    private let sessionIdleTimeoutSec: Double = 10

    // Long-lived components — set up inside the boot Task.
    private var capture: AudioCapture?
    private var coordinator: ConversationCoordinator?
    private var hotkey: HotkeyMonitor?
    private var statusItem: NSStatusItem?

    // HUD
    private let hudState = JarvisHUDState()
    private lazy var hudWindow = JarvisHUDWindowController(state: hudState)
    private var intensityDecayTimer: Timer?

    private var bootTask: Task<Void, Never>?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        printBootHeader()
        installStatusItem()
        hudWindow.show()
        startIntensityDecay()
        startBootTask()
    }

    func applicationWillTerminate(_ notification: Notification) {
        bootTask?.cancel()
        hotkey?.stop()
        capture?.stop()
    }

    // MARK: - Boot

    private func printBootHeader() {
        let defaultInput = AVCaptureDevice.default(for: .audio)
        let deviceName = defaultInput?.localizedName ?? "(unknown)"
        print("───────────────────────────────────────────────────────────────────────")
        print("  VoicePOC v0.1  —  local conversation (Path 3) — .app bundle")
        print("───────────────────────────────────────────────────────────────────────")
        print("  Audio input device : \(deviceName)")
        print("  Target format      : 1 ch, 16 kHz, Float32 (converted in tap @ max quality)")
        print("  Hotkey             : F1 (keyCode \(defaultHotkeyKeyCode))   — also: menu bar 🎙 menu")
        print("  End-of-turn        : \(endOfTurnSilenceMs) ms silence (VAD)")
        print("  Idle timeout       : \(Int(sessionIdleTimeoutSec)) s no-speech → idle")
        print("───────────────────────────────────────────────────────────────────────")
        print()
    }

    private func startBootTask() {
        bootTask = Task { [weak self] in
            do {
                try await self?.boot()
            } catch {
                Log.state.error("boot failed: \(error.localizedDescription)")
                print("  [boot] FAILED: \(error.localizedDescription)")
            }
        }
    }

    private func boot() async throws {
        print("  [init] AudioCapture …")
        let cap = try AudioCapture()
        try await cap.requestMicrophoneAuthorization()
        try cap.start()
        self.capture = cap
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
            print("  [init] Ollama ✗  — install / start / pull gemma4:latest; loop will fail at .thinking")
        }

        print("  [init] AVSpeechTTS …")
        let tts = AVSpeechTTS()
        // Wire HUD pulse hooks: each spoken word bumps intensity, decay timer
        // pulls it back down so the orb gently breathes between words.
        tts.onSpeakingStart = { [weak self] in self?.hudState.intensity = 0.9 }
        tts.onSpeakingPulse = { [weak self] in
            // Bump intensity per word; clamp 0..1.
            self?.hudState.intensity = min(1.0, (self?.hudState.intensity ?? 0) + 0.55)
        }
        tts.onSpeakingEnd = { [weak self] in self?.hudState.intensity = 0 }
        print("  [init] AVSpeechTTS ✓ (voice='\(tts.voice.name)')")

        let coord = ConversationCoordinator(
            capture: cap,
            stt: stt,
            vad: vad,
            ollama: ollama,
            tts: tts,
            endOfTurnSilenceMs: endOfTurnSilenceMs,
            sessionIdleTimeoutSec: sessionIdleTimeoutSec
        )
        self.coordinator = coord

        // Hotkey: capture coord weakly so AppDelegate stays the owner.
        let hk = HotkeyMonitor(keyCode: defaultHotkeyKeyCode) { [weak coord] in
            guard let coord else { return }
            Task { await coord.toggle() }
        }
        hk.start()
        self.hotkey = hk

        print()
        print("  [boot] speaking startup banner …")
        try? await tts.speak("Voice POC ready. Press F1 to start a conversation.")
        print("  [boot] ✓")
        print()
        print("  Ready. Press F1 anywhere on your Mac to start talking.")
        print("  Use the 🎙 menu-bar item (or Cmd-Q in a focused app) to quit.")
        print()

        // Status renderer — refreshes ~4 Hz, mirrors coordinator state to the
        // HUD and prints a one-line console status for the terminal observer.
        let statusRenderer = Task { [weak self, weak coord] in
            let interval = UInt64(250_000_000)
            var spinIdx = 0
            let spin = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
            while !Task.isCancelled, let coord {
                try? await Task.sleep(nanoseconds: interval)
                let s = await coord.status()
                spinIdx = (spinIdx + 1) % spin.count

                // Mirror to HUD on main actor.
                let mode: JarvisHUDState.Mode = {
                    switch s.state {
                    case .idle:      return .idle
                    case .listening: return .listening
                    case .thinking:  return .thinking
                    case .speaking:  return .speaking
                    }
                }()
                let elapsed = s.listeningElapsedSec ?? 0
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.hudState.setMode(mode)
                    self.hudState.listeningElapsed = elapsed
                }

                let line: String
                switch s.state {
                case .idle:
                    line = "  idle      — press F1 anywhere to talk"
                case .listening:
                    let phase = s.speechDetected ? "speech" : "waiting"
                    line = String(format: "  %@ listening  (%.1fs, %@)", spin[spinIdx], elapsed, phase)
                case .thinking:
                    line = "  \(spin[spinIdx]) thinking   (asking gemma4:latest …)"
                case .speaking:
                    line = "  \(spin[spinIdx]) speaking   (\(s.streamedTokens) chunks; last len=\(s.lastTranscriptLen))"
                }
                print("\u{001B}[2K\r" + line, terminator: "")
                fflush(stdout)
            }
        }
        _ = statusRenderer

        // Mirror transcript + response strings to the HUD as they're observed
        // by the coordinator. We piggyback on the coordinator's existing
        // status() snapshot; for the actual text we need a separate hook.
        // Simpler path: coordinator publishes events via the existing logger,
        // and we capture them by adding tiny accessors on the coordinator.
        startTextRefresher(coord: coord)
    }

    /// Refreshes HUD's caption strings by polling the coordinator's most
    /// recent transcript and response. Cheap; runs at 4 Hz next to the
    /// status renderer.
    private func startTextRefresher(coord: ConversationCoordinator) {
        Task { [weak self, weak coord] in
            while !Task.isCancelled, let coord {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let (utt, resp) = await coord.lastTexts()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !utt.isEmpty { self.hudState.lastUtterance = utt }
                    if !resp.isEmpty { self.hudState.lastResponse = resp }
                }
            }
        }
    }

    /// Decays HUD orb intensity gently between TTS word-pulse bumps so the
    /// orb breathes naturally instead of staying clamped to 1.0.
    private func startIntensityDecay() {
        intensityDecayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Only decay while speaking; other modes set intensity to 0 directly.
            if self.hudState.mode == .speaking {
                self.hudState.intensity = max(0, self.hudState.intensity - 0.04)
            }
        }
    }

    // MARK: - Menu bar status item (Quit + manual toggle)

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎙"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle conversation (F1)", action: #selector(toggleConversation(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoicePOC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for it in menu.items where it.action == #selector(toggleConversation(_:)) {
            it.target = self
        }
        item.menu = menu
        self.statusItem = item
    }

    @objc private func toggleConversation(_ sender: Any?) {
        guard let coord = coordinator else { return }
        Task { await coord.toggle() }
    }
}
