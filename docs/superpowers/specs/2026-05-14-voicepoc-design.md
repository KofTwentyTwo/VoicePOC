# VoicePOC Design Spec

**Date:** 2026-05-14
**Status:** Approved (brainstorm), pending writing-plans handoff
**Author:** James Maes
**Companion project:** [Jarvis](../../../../Jarvis) (production target), [MetalPOC](../../../../MetalPOC) (sibling HUD POC)

---

## 1. Purpose

Derisk the **Jarvis voice loop** by building a standalone macOS application that demonstrably runs the chosen stack end-to-end on real Apple Silicon hardware, with none of Jarvis's bundling, signing, or architectural ceremony in the way.

Jarvis's voice package (`packages/Voice/`) has 64 unit tests passing but Human UAT Gates 1 and 2 are deferred:

> Blocked by Xcode 26 ad-hoc-Debug bundle launch fragility.

VoicePOC's job is to **be the controlled environment** where the voice loop can be proven to work against a live microphone and live speaker, without fighting the bundle/launch problem that's currently blocking Jarvis's UAT.

VoicePOC is **not** an attempt to design a better voice stack than Jarvis. It uses Jarvis's component choices intentionally so that working code can transfer back. The simplifications are in the *plumbing*, not the *components*.

## 2. Three Capabilities (POC scope)

1. **Wake word** — the system listens continuously for "Hey Jarvis" and transitions to a listening state when it hears it.
2. **Voice command** — after wake, the system transcribes the user's next utterance and dispatches it through a hardcoded command table.
3. **Voice response (JARVIS-style)** — the system speaks the response back using high-quality TTS (Orpheus tier-2, with an AVSpeech Premium fallback).

No LLM. No HUD. No persistence. No menu bar. No code signing. Just the three capabilities, on one consumer audio path, in one state machine.

## 3. Stack Choices

| Layer | Choice | Rationale |
|---|---|---|
| Wake word | **openWakeWord** ONNX, pre-trained `hey_jarvis_v0.1.onnx` | Same model Jarvis specs. MIT. ~5 MB total (mel + embedding + classifier). |
| VAD | **Silero v6.2.1** ONNX | Tiny (~2 MB). Gates end-of-utterance cleanly via `.speechEnd` + 5-chunk hangover. |
| STT | **SpeechAnalyzer** (macOS 26 Tahoe) | Native, on-device, ~55% faster than Whisper per Apple. No fallback in POC — POC machine is macOS 26. |
| TTS primary | **Orpheus 3B** via `blaizzy/mlx-audio-swift v0.1.2`, voice "tara" | Same as Jarvis tier-2. Streaming via `generateStream`. Target TTFA ≤ 1.5 s for POC (Jarvis prod target is 150–250 ms). |
| TTS fallback | **AVSpeechSynthesizer** with macOS Premium voice (`com.apple.voice.premium.en-US.Zoe` or equivalent available on host) | Activated by `VOICEPOC_TTS=avspeech` env var. Free, instant, ships with the OS, sounds dramatically better than the default voices. |
| LLM | None (hardcoded `CommandRouter`) | Decouples voice-loop validation from agent-loop validation. |

## 4. Architecture

### 4.1 Module Layout

Swift Package executable. Chosen over Xcode `.app` bundle because `swift run` bypasses the Xcode-26 bundle-launch fragility that's blocking Jarvis's UAT.

```
VoicePOC/
├── Package.swift
├── Sources/
│   └── VoicePOC/
│       ├── main.swift                       (entrypoint)
│       ├── AppCoordinator.swift             (state-machine actor)
│       ├── AudioCapture.swift               (AVAudioEngine + tap → AsyncStream)
│       ├── WakeWord/
│       │   ├── OpenWakeWordDetector.swift   (ONNX: mel → embed → classify)
│       │   └── HeyJarvisModel.swift         (model-file path resolver)
│       ├── STT/
│       │   ├── SpeechAnalyzerSTT.swift      (macOS 26 STT wrapper)
│       │   └── SileroVAD.swift              (end-of-speech gate)
│       ├── TTS/
│       │   ├── TTSProvider.swift            (protocol)
│       │   ├── OrpheusTTS.swift             (mlx-audio-swift, streaming)
│       │   └── AVSpeechTTS.swift            (AVSpeechSynthesizer Premium)
│       ├── CommandRouter.swift              (hardcoded phrase → response)
│       └── Logging.swift                    (os.Logger, transcript-redacting)
├── Resources/models/
│   ├── openWakeWord/
│   │   ├── hey_jarvis_v0.1.onnx
│   │   ├── melspectrogram.onnx
│   │   └── embedding_model.onnx
│   └── silero/silero_vad_v6_2_1.onnx
├── scripts/
│   ├── fetch-models.sh                      (downloads ONNX models)
│   └── fetch-orpheus.sh                     (downloads MLX Orpheus weights)
├── docs/superpowers/specs/
│   └── 2026-05-14-voicepoc-design.md        (this file)
└── README.md
```

Source modules are deliberately small (target: each file under ~200 lines). Boundaries are by stage, so any one stage can be replaced or stubbed without touching the others.

### 4.2 State Machine

The `AppCoordinator` actor owns a single state variable:

```swift
enum State {
    case idle
    case wake        // wake-word detector consumes audio
    case listen      // STT + VAD consume audio
    case think       // CommandRouter computes response (synchronous)
    case speak       // TTSProvider streams to speaker; mic is silenced
}
```

Transitions:

```
idle ──[app launch]──► wake
wake ──[wake-word hit]──► listen
listen ──[VAD .speechEnd + 5 chunks]──► think
listen ──[no audio 10s]──► wake        (timeout)
think ──[router returns response]──► speak
speak ──[TTS completes]──► wake        (return to listening for the next wake)
speak ──[TTS error]──► wake
```

### 4.3 Single-Consumer Audio Invariant

The `AudioCapture` module owns one `AVAudioEngine` with one tap at 16 kHz mono. The tap pushes `AVAudioPCMBuffer` into an `AsyncStream`. At any moment, **exactly one stage subscribes** to that stream.

When the state machine transitions, the current subscriber's task is cancelled and the next subscriber subscribes. The engine itself is **not** torn down between stages — only the consumer changes. During `.speak` no stage consumes audio (mic is effectively muted at the consumer level; the engine keeps running so we don't pay restart cost).

This eliminates the entire class of bugs Jarvis's `BufferBroadcaster` was built to fix. The POC pays for that simplicity by not supporting barge-in — to interrupt the assistant, the user waits for it to finish or restarts the app.

### 4.4 Data Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                          VoicePOC.app                                 │
│                                                                       │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  AppCoordinator (actor)                                     │    │
│   │  state: idle → wake → listen → think → speak → wake         │    │
│   └────┬────────────────────────────────────────────────┬──────┘    │
│        │                                                │           │
│   ┌────▼─────────────┐                          ┌───────▼────────┐  │
│   │ AudioCapture     │                          │ TTSProvider    │  │
│   │ AVAudioEngine    │                          │   protocol     │  │
│   │ tap @ 16 kHz     │                          ├────────────────┤  │
│   │ → AsyncStream    │                          │ OrpheusTTS     │  │
│   │   <PCM buffer>   │                          │ (primary)      │  │
│   └────┬─────────────┘                          ├────────────────┤  │
│        │  one consumer at a time                │ AVSpeechTTS    │  │
│        │                                        │ (fallback)     │  │
│   ┌────▼────────────────┐  ┌───────────────┐   └───────┬────────┘  │
│   │ OpenWakeWordDetector│  │ SpeechAnalyzer│           │           │
│   │ (active in .wake)   │  │ + SileroVAD   │           │           │
│   └─────────────────────┘  │ (in .listen)  │           │           │
│                            └──────┬────────┘           │           │
│                                   │                    │           │
│                            ┌──────▼──────────┐         │           │
│                            │ CommandRouter   │ ────────►           │
│                            │ (hardcoded)     │                     │
│                            └─────────────────┘                     │
└──────────────────────────────────────────────────────────────────────┘
```

## 5. Dependencies

| Package | Version | Purpose |
|---|---|---|
| `microsoft/onnxruntime-swift-package-manager` | latest stable | openWakeWord + Silero inference |
| `blaizzy/mlx-audio-swift` | v0.1.2 | Orpheus streaming TTS |
| `apple/swift-log` | latest | Channel-tagged logging |

Apple frameworks: `AVFoundation`, `Speech`, `os.log`. No `AppKit` if avoidable — the executable runs its event loop with `Task` + `AsyncStream`.

### 5.1 Models

Downloaded on first run by `scripts/fetch-models.sh`:

- openWakeWord (~5 MB total, MIT, from openWakeWord HuggingFace mirror):
  - `hey_jarvis_v0.1.onnx`
  - `melspectrogram.onnx`
  - `embedding_model.onnx`
- Silero VAD v6.2.1 (~2 MB)

Downloaded on first run by `scripts/fetch-orpheus.sh`:

- `mlx-community/orpheus-3b-0.1-ft-bf16` (~6 GB, cached at `~/Library/Caches/VoicePOC/orpheus/`)

If the user runs without Orpheus weights (`scripts/fetch-orpheus.sh` not yet executed), the TTSProvider auto-falls-back to `AVSpeechTTS`.

## 6. Error Handling

Single typed error:

```swift
enum VoicePOCError: Error {
    case microphonePermissionDenied
    case modelFileMissing(String)
    case wakeWordInferenceFailed(underlying: Error)
    case sttUnavailable
    case ttsStreamStalled
    case audioEngineFailed(OSStatus)
}
```

Strategy: log, return to `.wake` (or print + exit if mic permission is denied). No retry loops, no recovery UI, no AEC fallback ceremony.

**Mic permission flow:** macOS shows its standard TCC prompt on first `AVAudioEngine` start. If denied, VoicePOC prints a `tccutil reset Microphone` hint and exits with code 1. No System Settings deep link.

## 7. Logging

`os.Logger` with three categories:

- `voicepoc.state` — every state transition with timestamp
- `voicepoc.audio` — RMS levels, frame counts, engine lifecycle events
- `voicepoc.perf` — wake-detection latency, STT finalize latency, TTS time-to-first-audio

**Invariant (matching Jarvis T-06-05-03):** transcript text is **never** logged. Only `transcript redacted, len=N` is acceptable. `Logging.redact(_:)` helper enforces this at the call site.

## 8. Testing

| Layer | Test | Type |
|---|---|---|
| `OpenWakeWordDetector` | Loads model, returns confidence ≥ 0.5 on canonical "Hey Jarvis" WAV; ≤ 0.1 on silence | Unit |
| `SileroVAD` | Returns `.speech` on speech frames, `.silence` on silence | Unit |
| `CommandRouter` | Maps known phrases; returns echo for unknown | Unit |
| `OrpheusTTS` | First audio chunk arrives within 5 s | Integration, gated by `VOICEPOC_REAL_MODELS=1` |
| End-to-end | Live mic + live speaker — three gates pass three times | Manual UAT (see §9) |

No mocks of the audio graph. Single-consumer plumbing has no test seams worth building because there's nothing to fan out.

## 9. Success Criteria

VoicePOC is **done** when all three gates below pass on the user's actual Apple Silicon Mac, three consecutive runs of `swift run` from a clean shell:

### Gate 1 — Wake
- Say "Hey Jarvis" into the built-in mic.
- Console logs `state: idle → wake → listen` within **1 second** of utterance end.

### Gate 2 — Listen + Think
- After Gate 1 fires, say "what time is it".
- Silero VAD reports `.speechEnd`; SpeechAnalyzer finalizes transcript within **1.5 seconds**.
- Console logs `transcript redacted, len=N` followed by `dispatch: .timeOfDay`.

### Gate 3 — Speak (JARVIS-style)
- Orpheus speaks the current time. First audio out of speakers within **1.5 seconds** of `.think` entering.
- Voice is the Orpheus "tara" voice (or the configured AVSpeech Premium voice if the fallback flag is set).
- After speech ends, state returns to `.wake` and the loop is ready for the next wake word.

### Sample command table

```swift
[
    "what time is it" : .timeOfDay,
    "what day is it"  : .dayOfWeek,
    "hello"           : .greeting,
    "are you there"   : .greeting,
    // any other input → .echo(transcript) for diagnostic feedback
]
```

## 10. Non-Goals

Explicitly **out of scope** for VoicePOC:

- HUD / ring / menu bar UI
- LLM in the loop (no Anthropic API, no Ollama)
- Push-to-talk
- Mute wake-word toggle
- Barge-in (interrupt TTS by speaking)
- AEC / echo cancellation
- WhisperKit STT fallback
- Multi-consumer audio fan-out
- Audio engine rebuild on device change
- JSON Bus / MCP / tool calling
- Code signing / notarization / `.app` bundle
- Settings UI / config file
- Persistent state across launches
- Multi-language support (en-US only)
- Continuous re-wake during speech (return to `.wake` after speech, not during)

## 11. Build, Run, Test

```bash
# one-time setup
git clone <this repo>
cd VoicePOC
./scripts/fetch-models.sh       # ~7 MB of ONNX
./scripts/fetch-orpheus.sh      # ~6 GB MLX weights (or skip and fall back to AVSpeech)

# run
swift run                       # the entire POC

# run with AVSpeech fallback (skip Orpheus)
VOICEPOC_TTS=avspeech swift run

# unit tests
swift test

# integration tests (requires fetched models)
VOICEPOC_REAL_MODELS=1 swift test
```

## 12. Open Questions / Risks

| Risk | Probability | Mitigation |
|---|---|---|
| openWakeWord pre-trained `hey_jarvis` accuracy is poor on user's voice | Medium | Threshold tuneable via env var; can fall back to custom training later |
| Orpheus TTFA > 5 s on user's Mac | Medium | AVSpeech Premium fallback wired from day one |
| SpeechAnalyzer requires entitlements we can't add to a SwiftPM executable | Low–Medium | Spike this in plan-phase; if so, fall back to `SFSpeechRecognizer` (macOS 10.15+) |
| MLX runtime requires an `.app` bundle and refuses to load from a SwiftPM executable | Low | If true, wrap the executable in a minimal XcodeGen project at that point — still simpler than Jarvis's full bundle |
| 6 GB Orpheus download is impractical on user's connection | Low | Skip Orpheus, run with `VOICEPOC_TTS=avspeech` — POC still passes Gate 3 with Premium voice |

These get resolved during the writing-plans phase, not now.

## 13. After the POC Succeeds

Once all three gates pass three times in a row, two paths open:

1. **Migrate the working pattern back into Jarvis.** The single-consumer audio path, the simpler state machine, and the SwiftPM-first packaging may inform what to simplify in Jarvis's `packages/Voice/`.
2. **Use VoicePOC as a diagnostic reference.** If Jarvis's voice package still fails on the same hardware where VoicePOC succeeds, the delta is the bundling / orchestrator / Bus layer — not the voice stack itself. That's a much smaller search space.

Either way, VoicePOC is a one-time tool. It doesn't ship.
