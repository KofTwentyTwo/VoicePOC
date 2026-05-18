import Cocoa
import AVFoundation
import SwiftUI
import VoicePOCKit

/// VoicePOC NSApplicationDelegate.
///
/// Owns the long-lived components (AudioCapture, STT, VAD, Ollama, TTS,
/// ConversationCoordinator), the global F1 hotkey, the main visible window
/// (HUD orb + live status panel), the menu bar, and the log-stream
/// secondary window. Mirrors VisionPOC's AppDelegate pattern.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Hotkey / tuning
    private let defaultHotkeyKeyCode: UInt16 = 122          // F1
    private let endOfTurnSilenceMs = 800
    private let sessionIdleTimeoutSec: Double = 10

    // Long-lived components — set up inside the boot Task.
    private var capture: AudioCapture?
    private var coordinator: ConversationCoordinator?
    private var hotkey: HotkeyMonitor?

    // UI
    private let hudState = JarvisHUDState()
    private var mainWindow: JarvisMainWindowController?
    private var logWindow: LogStreamWindowController?
    private var intensityDecayTimer: Timer?
    private var bootTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bootstrap the file mirror for the LogStream so `tail -f
        // /tmp/voicepoc.log` works even when launched from Finder.
        LogStream.bootstrapFile()
        LogStream.shared.log("VoicePOC starting up", source: .app)

        installMainMenu()
        showMainWindow()
        startIntensityDecay()
        startBootTask()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when the user closes the window — keep the conversation
        // running. Quit comes from ⌘Q.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        bootTask?.cancel()
        hotkey?.stop()
        capture?.stop()
    }

    // MARK: - UI

    private func showMainWindow() {
        let controller = JarvisMainWindowController(state: hudState)
        controller.showWindow(nil)
        self.mainWindow = controller
    }

    @objc private func showLogStreamWindow() {
        if logWindow == nil {
            logWindow = LogStreamWindowController()
        }
        logWindow?.showWindow(nil)
        logWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleConversation() {
        guard let coord = coordinator else { return }
        Task { await coord.toggle() }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // ── Application menu ───────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About \(appName)", action: nil, keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // ── Conversation menu ──────────────────────────────────────────────
        let convoItem = NSMenuItem()
        let convoMenu = NSMenu(title: "Conversation")
        let toggleItem = NSMenuItem(title: "Toggle Conversation", action: #selector(toggleConversation), keyEquivalent: "")
        toggleItem.target = self
        convoMenu.addItem(toggleItem)
        convoItem.submenu = convoMenu
        mainMenu.addItem(convoItem)

        // ── View menu ──────────────────────────────────────────────────────
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let logItem = NSMenuItem(title: "Log Stream", action: #selector(showLogStreamWindow), keyEquivalent: "l")
        logItem.target = self
        viewMenu.addItem(logItem)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // ── Window menu ────────────────────────────────────────────────────
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Boot

    private func startBootTask() {
        bootTask = Task { [weak self] in
            do {
                try await self?.boot()
            } catch {
                LogStream.shared.log("boot failed: \(error.localizedDescription)", level: .error, source: .app)
            }
        }
    }

    private func boot() async throws {
        LogStream.shared.log("init: AudioCapture …", source: .app)
        let cap = try AudioCapture()
        try await cap.requestMicrophoneAuthorization()
        try cap.start()
        self.capture = cap
        LogStream.shared.log("init: AudioCapture ✓", source: .app)

        LogStream.shared.log("init: SileroVAD …", source: .app)
        let vad = try SileroVAD()
        LogStream.shared.log("init: SileroVAD ✓", source: .app)

        LogStream.shared.log("init: WhisperKit (downloading on first run, ~150 MB) …", source: .app)
        let stt = try await WhisperKitSTT()
        LogStream.shared.log("init: WhisperKit ✓ (model=\(stt.modelName))", source: .app)

        LogStream.shared.log("init: OllamaClient …", source: .app)
        let ollama = OllamaClient()
        let ollamaUp = (try? await ollama.healthCheck()) ?? false
        if ollamaUp {
            LogStream.shared.log("init: Ollama ✓ (gemma4:latest reachable)", source: .app)
        } else {
            LogStream.shared.log("init: Ollama ✗ — install + start + pull gemma4:latest; conversation will fail at .thinking", level: .warn, source: .app)
        }

        LogStream.shared.log("init: AVSpeechTTS …", source: .app)
        let tts = AVSpeechTTS()
        tts.onSpeakingStart = { [weak self] in self?.hudState.intensity = 0.9 }
        tts.onSpeakingPulse = { [weak self] in
            self?.hudState.intensity = min(1.0, (self?.hudState.intensity ?? 0) + 0.55)
        }
        tts.onSpeakingEnd = { [weak self] in self?.hudState.intensity = 0 }
        LogStream.shared.log("init: AVSpeechTTS ✓ (voice='\(tts.voice.name)')", source: .app)

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

        // Forward live observability data to the HUD state on main actor.
        await coord.setObservers(
            onRMS: { [weak self] rms in
                Task { @MainActor [weak self] in self?.hudState.micRMS = rms }
            },
            onVAD: { [weak self] prob in
                Task { @MainActor [weak self] in self?.hudState.vadProbability = prob }
            },
            onTranscript: { [weak self] text in
                Task { @MainActor [weak self] in self?.hudState.lastUtterance = text }
            },
            onLLMProgress: { [weak self] count, partial in
                Task { @MainActor [weak self] in
                    self?.hudState.streamingTokenCount = count
                    self?.hudState.lastResponse = partial
                }
            },
            onLLMResponse: { [weak self] text in
                Task { @MainActor [weak self] in self?.hudState.lastResponse = text }
            }
        )

        let hk = HotkeyMonitor(keyCode: defaultHotkeyKeyCode) { [weak coord] in
            LogStream.shared.log("F1 pressed", source: .app)
            guard let coord else { return }
            Task { await coord.toggle() }
        }
        hk.start()
        self.hotkey = hk

        LogStream.shared.log("boot complete — press F1 (or Conversation → Toggle Conversation) to talk", source: .app)
        try? await tts.speak("Voice POC ready. Press F1 to talk.")

        // Mirror coordinator state into the HUD state at 4 Hz so the orb
        // and meters know what mode we're in.
        let stateMirror = Task { [weak self, weak coord] in
            while !Task.isCancelled, let coord {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let s = await coord.status()
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
                    self?.hudState.setMode(mode)
                    self?.hudState.listeningElapsed = elapsed
                }
            }
        }
        _ = stateMirror
    }

    private func startIntensityDecay() {
        intensityDecayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.hudState.mode == .speaking {
                self.hudState.intensity = max(0, self.hudState.intensity - 0.04)
            }
        }
    }
}
