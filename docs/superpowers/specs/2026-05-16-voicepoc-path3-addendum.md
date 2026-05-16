# VoicePOC Path 3 Addendum — Local Continuous Conversation

**Date:** 2026-05-16
**Status:** Approved (replaces the wake-word-centric loop from the original 2026-05-14 spec)
**Author:** James Maes
**Supersedes (partially):** sections 2, 3, 4.2, 4.3, 9, 10, 11, 13 of
`2026-05-14-voicepoc-design.md`. The original spec's component choices for
audio plumbing, Logging, AudioCapture, and the Swift Package executable shape
remain unchanged.

## 1. Why a Pivot

Live-mic testing of `openWakeWord/hey_jarvis_v0.1.onnx` on the author's voice
produced scores of **0.03** — essentially the silence floor (0.00004) — across
many attempts, despite:

- Correct audio capture (RMS rises clearly when speaking, playback sounds clean)
- A long-enough rolling window (4.0 s)
- A pristine recording (5.4 s, well-padded silence on both sides, clear speech)
- The same detector instance scoring the bundled TTS Karen fixture at 0.43

The `hey_jarvis_v0.1` community model does not generalize to this speaker.
Custom training would solve it, but the larger realization was: **wake-word
accuracy doesn't matter much for the actual product goal.**

The user's stated goal is *continuous conversation* with Jarvis — "talk to me
in voice, JARVIS-STYLE." For that experience:

- Wake word is a *session opener*, not a per-utterance gate. It fires once,
  then the assistant stays in conversation until silence timeout or hotkey.
- A hotkey provides the same session-opener function and is 100% reliable.
- The hard problem is no longer "wake detection" — it's "continuous STT,
  turn segmentation, LLM call, response speech, return to listening."

## 2. New Architecture

```
   [idle]
     │  ← user presses hotkey (F1 or Cmd+Shift+J)
     ▼
   [conversation: turn N]
     │  user speaks
     ▼  WhisperKit streaming transcribes
     │  SileroVAD detects end-of-turn (≥600 ms silence)
     ▼
   [thinking]
     │  Ollama (local) generates response
     ▼
   [speaking]
     │  AVSpeech (Premium voice) — or Orpheus tier-2 later
     ▼
   [conversation: turn N+1]   ← back to listening, no wake needed
     ...
   [end conversation]
     │  ← 10-second silence OR "goodbye Jarvis" OR hotkey toggle
     ▼
   [idle]
```

## 3. Stack — All Local

| Layer            | Choice                                                    | Why |
|------------------|-----------------------------------------------------------|-----|
| Audio capture    | `AVAudioEngine` tap → 16 kHz mono Float32 AsyncStream     | unchanged from original spec (already working) |
| Session entry    | Global hotkey via NSEvent monitor (F1 default)            | reliable, no accent issues, instant. Wake word becomes a later polish |
| STT              | **WhisperKit** (`argmaxinc/argmax-oss-swift`)             | trained on 680k hours of speech, generalizes across all voices and accents. Same package Jarvis spec'd as STT fallback |
| Whisper model    | `openai_whisper-base` (~150 MB) for now; `small` later    | Base balances speed (~5× realtime on M-series) and accuracy. Upgrade to small for better punctuation |
| End-of-turn      | **SileroVAD v6.2.1** + 600 ms hangover                    | unchanged from original spec; carries forward |
| LLM              | **Ollama** at `http://localhost:11434`                    | user has Ollama running with multiple models. Local, free, fully offline |
| LLM model        | `gemma4:latest` (9.6 GB) default; configurable via env    | user has it pulled; fast on Apple Silicon |
| TTS              | **AVSpeechSynthesizer** (Premium voice preferred)         | unchanged from original spec tier-1 |
| TTS upgrade path | Orpheus (mlx-audio-swift) — deferred                      | original spec's tier-2, kept as a future option |

## 4. What Gets Built (replaces original Tasks 6, 7, 8, 10, 11)

| Task | Module | Purpose |
|------|--------|---------|
| P3-2 | `STT/WhisperKitSTT.swift`           | WhisperKit wrapper. `transcribeFile(url:)` + `makeStreamingSession()` mirroring the SpeechAnalyzer shape from the original spec |
| P3-3 | `STT/SileroVAD.swift`               | Carries over from original Task 7 (unchanged) |
| P3-4 | `LLM/OllamaClient.swift`            | Thin HTTP client. Streaming `chat()` returns `AsyncStream<String>` (token chunks) |
| P3-5 | `TTS/TTSProvider.swift`, `TTS/AVSpeechTTS.swift` | Carries over from original Task 9 (unchanged) |
| P3-6 | `Input/HotkeyMonitor.swift`         | NSEvent global monitor for hotkey (F1 default, configurable). Toggles conversation mode |
| P3-7 | `ConversationCoordinator.swift`     | Actor state machine: `idle / listening / thinking / speaking`. Replaces the wake-driven `AppCoordinator` from the original spec |
| P3-8 | `main.swift`                        | Wires hotkey + coordinator + AudioCapture |

## 5. What Survives From the Original Spec

These are still 100% in scope, no changes needed:

- Swift Package executable shape (SwiftPM, not Xcode bundle)
- `AudioCapture` with 48 kHz → 16 kHz mono Float32 conversion (mastering-quality resampler)
- `Log` module with three categories (state, audio, perf) and `redact()` for transcript privacy
- `VoicePOCError` typed-error enum
- Test target with `Fixtures/` directory; `Bundle.module.url(...)` resolves resources
- Spec §10's non-goals list (no HUD, no signing, no PTT, etc.)
- The press-to-record debug harness (`Sources/VoicePOC/main.swift` current state) — kept as a separate diagnostic mode behind `--debug` flag

## 6. What Gets Retired (kept in git for reference, not deleted)

- `Sources/VoicePOC/WakeWord/` — the OpenWakeWord detector. Code stays; runtime path no longer uses it. May be revived later for custom-trained wake word.
- `Resources/models/openWakeWord/*.onnx` — stays downloaded (still listed in `fetch-models.sh`)
- Silero VAD model — still used (no change)

## 7. Success Criteria (replaces original spec §9 gates)

Path 3 succeeds when **a continuous, fully-local voice conversation works on the author's machine**, demonstrating:

### Gate A — Open conversation
- Press hotkey while in idle.
- Console logs `state: idle → listening`. Onscreen indicator (status line) shows ● LISTENING.

### Gate B — One full turn
- Say "What time is it?".
- Console logs WhisperKit transcript (redacted-len).
- Console logs Ollama response start within ~1 s of end-of-speech.
- AVSpeech speaks Ollama's response (e.g., "It's 11:43 AM" or similar).
- After speech ends, console logs `state: speaking → listening` automatically.

### Gate C — Multi-turn conversation
- Without pressing hotkey again, say "What day is it?" — assistant responds.
- Then say "Tell me a joke" — assistant responds.
- Three turns in a row without re-pressing hotkey.

### Gate D — Conversation ends cleanly
- Stop speaking for 10 seconds → conversation auto-ends, state returns to `idle`.
- OR press hotkey again → conversation ends immediately.

### Gate E — All local
- Run `lsof -i -n -P | grep VoicePOC` (or `nettop`) during a conversation.
- Only outbound connection visible: `localhost:11434` (Ollama).
- No connection to OpenAI, Anthropic, or any other external host.

## 8. Open Decisions That Are Settled

- **STT engine:** WhisperKit (decided 2026-05-16)
- **LLM:** Ollama with `gemma4:latest` default (decided 2026-05-16)
- **Session entry:** Hotkey only for now; wake word deferred (decided 2026-05-16)
- **No cloud:** confirmed; runtime must show zero external connections (decided 2026-05-16)

## 9. Future Polish (out of Path 3 scope)

- Whisper-tiny continuous wake-word listening (substring match for "jarvis")
- Custom-trained openWakeWord model on author's voice
- Orpheus tier-2 TTS for more natural responses
- HUD integration with MetalPOC
- AEC (echo cancellation while assistant is speaking)
- Barge-in (interrupt assistant mid-speech by speaking)
- Conversation memory / context across turns (LLM gets full history each turn for now)
- System integration (calendar, clipboard, AppleScript) via MCP

These belong to Jarvis production, not VoicePOC.
