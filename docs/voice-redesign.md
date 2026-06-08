# HearZork — Voice System Redesign

**Scope:** Full rewrite of the voice layer; targeted fixes to the Z-machine interpreter
(kept). Companion to [`recognition-system.md`](recognition-system.md), which is the deep
dive on the recognition pipeline (dictionary → custom LM → matcher); this document is the
whole-system spec — diagnosis, audio graph, TTS, concurrency, the turn-loop state machine,
the `IOSystem` bridge, component contracts, and a staged migration plan.

**Status:** buildable spec. Every `file:line` was confirmed against the working tree at
`/Users/wohl/src/hearzork` on `main`. Apple API claims were verified against WWDC23/WWDC25,
Apple docs, and Apple-engineer Developer-Forums posts, adversarially reviewed, and a second
adjudication pass resolved the two originally-contested items (does AEC cancel `speak`; iOS
26 biasing). Items that genuinely need on-device measurement are flagged in §7.

---

## 1. Executive summary

HearZork is unplayable for its target users for two **independent** reasons — one in the
interpreter, one in the voice layer.

The interpreter is correct everywhere **except the V1‑4 `sread` text-buffer layout**, which
corrupts every typed command in V3 games (Zork I–III) — a ~3-line bug (`Processor.swift:538-551`,
`Dictionary.swift:80-86`) that alone explains "works very poorly" even before voice enters
the picture. Fix it first (§6 Step 0).

The voice layer is broken at the **architecture** level and must be rewritten. The single
biggest mistake: **there is no acoustic echo cancellation (AEC), so the app tries to avoid
"hearing itself" by manually muting the mic around TTS with wall-clock sleeps and
`isSpeaking` polling** (`SpeechInput.swift:253` `Thread.sleep(0.1)`; `VoiceCoordinator.swift:114-120`
`Thread.sleep(0.3)` + `while synthesizer.isSpeaking { Thread.sleep(0.05) }`;
`GameViewModel.swift:142,165` `await delayMs(300)`). This is the root of *both* complaints:
with the mic open and no AEC the speaker bleeds into the recognizer (it "hears itself"); and
because the gating is wall-clock guesswork around `AVSpeechSynthesizer.isSpeaking` (which
goes false when the last buffer reaches the HAL, not when sound stops), the mic reopens too
late and clips the user's first word, or too early and re-hears the tail ("muting messes up
timing and misses speech"). The `@unchecked Sendable` / `nonisolated(unsafe)` sprawl and the
dual `listen()` / `listenSync()` paths exist only to make this fragile half-duplex scheme
compile and not "stall on MainActor." **AEC dissolves the entire problem class:** with the
voice-processing I/O unit enabled, mic and speaker are live simultaneously and the OS
subtracts the TTS from the mic — nothing to mute, no timing to guess.

The second mistake is recognition strategy ("really crappy at understanding"), from three
compounding errors: (a) the high-value **custom language model (`SFCustomLanguageModelData`)
does not exist** — `grep` returns zero hits; only the weak `contextualStrings` layer is
wired; (b) `requiresOnDeviceRecognition = false` (`SpeechInput.swift:309`), which **silently
disables any custom LM** (WWDC23: a custom LM is honored only on-device) and injects server
latency; (c) the recognizer is fed **truncated 6/9-Z-char dictionary stems** ("examin",
"mailbo") and a **naive edit-distance corrector rewrites every token within distance ≤2**
(`SpeechInput.swift:400-422`), clobbering correctly-heard English ("to"→"go", "the"→"tie").
The fix — a real on-device custom LM trained on **full** words with stem-mapping done in the
parser — is specified in [`recognition-system.md`](recognition-system.md) and summarized in §3.3.

---

## 2. Diagnosis

### 2.1 Complaint → root-cause map

| User complaint | Proximate cause in code | Root cause | Fix class |
|---|---|---|---|
| "It hears itself" | Raw mic tap, no AEC: `SpeechInput.swift:328` `installTap(onBus:0,…)`; session is `.playAndRecord` mode **`.default`** + `.defaultToSpeaker` (`SpeechInput.swift:54`). `grep setVoiceProcessingEnabled\|voiceChat\|measurement` = 0 hits. | No voice-processing I/O unit anywhere; `.defaultToSpeaker` + `.default` maximizes speaker→mic coupling. | **Rewrite:** enable AEC (§3.1). |
| "Muting during speech messes up timing, often misses speech" | Half-duplex gating by guesswork: `SpeechInput.swift:253`; `VoiceCoordinator.swift:114-120`; `GameViewModel.swift:142,165`; engine torn down/rebuilt every cycle (`SpeechInput.swift:304` `removeTap`, `:328` `installTap`, `:379` `removeTap`). `isSpeaking` flips false when the last buffer reaches the HAL, not when audio stops. | Serializing speak/listen with wall-clock sleeps instead of AEC + deterministic events; cold-starting `AVAudioEngine` per utterance drops the first ~100–300 ms. | **Rewrite:** persistent engine + AEC + barge-in (§3.1, §3.5). |
| "Really crappy at understanding" | No custom LM (zero `SFCustomLanguageModelData` hits); `requiresOnDeviceRecognition = false` (`:309`); truncated stems as `contextualStrings = Array(vocabulary.prefix(100))` (`:312`); aggressive corrector (`:400-422`, dist ≤2, no guards, first-match-wins). | Easy API built, hard layer skipped; off-device routing nullifies customization; stem/word conflation; corrector treats dictionary as authoritative spell-check. | **Rewrite:** custom LM + on-device + full-word training + stem-in-parser + guarded correction (§3.3, recognition-system.md). |
| (Latent) "Works very poorly" even with perfect recognition | V1‑4 `sread` writes a spurious count byte: `Processor.swift:538-551` (the V1‑4 and V5+ `if/else` arms are **byte-for-byte identical** — both write count at `+1`, text at `+2`); tokenizer reads `textStart = textBuffer + 1` for V1‑4 (`Dictionary.swift:84`), so it reads the count byte as character 0 and drops the last char. | V5 buffer layout copied into the V1‑4 branch; per Z‑spec §15, V1‑4 has **no** count byte — text starts at offset 1, zero-terminated. | **Fix (keep):** ~3 lines (§6 Step 0). |
| Crash on first voice use (device) | `Info.plist` has only `ITSAppUsesNonExemptEncryption` — **no** `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription`. macOS `HearZork.entitlements` is empty `<dict/>` — no `com.apple.security.device.audio-input`. | Privacy/entitlement config never added. | **Fix:** packaging (§6 Step 1). |
| Blind user gets stuck silently | Empty recognition dead-ends: `GameViewModel.swift:144` `guard !raw.isEmpty else { return }` — no re-prompt, game blocked. `read_char` has no voice path. No earcons anywhere. | Turn modeled as fire-once async, not a resilient state machine; single-key input never integrated; listening state is visual-only. | **Rewrite:** VoiceLoop + earcons + read_char grammar (§3.6, §5). |

### 2.2 Keep vs. rewrite

**KEEP — the Z-machine interpreter is architecturally clean** (proven byte-correct against
real `zork1.z3`):

- `ZMachine/Processor.swift`, `Memory.swift`, `Header.swift`, `Instruction.swift`, `ObjectTable.swift`
- `ZMachine/TextDecoder.swift` (decode/alphabet/abbreviations all correct)
- `ZMachine/Dictionary.swift` reader/lookup/tokenize and the `editDistance` primitive
- `ZMachine/IOSystem.swift` **as the integration seam** — but extend it (§5.6)

Apply this interpreter fix-list before treating it as a black box: **(1)** V1‑4 `sread`
buffer [critical], **(2)** `[MORE]` hook + line counting [high — needed by voice], **(3)**
timed-input protocol extension [medium — needed by voice], **(4)** Quetzal save/restore
[high], **(5)** stream-3 table writes [medium]. Items 1–3 touch the voice experience directly.

**REWRITE — delete entirely:**

- `Voice/SpeechInput.swift` — dual `listen()`/`listenSync()`, per-cycle teardown,
  `nonisolated(unsafe)` state, raw tap, the corrector.
- `Voice/SpeechOutput.swift` — replace with `TTSPlayer` rendered onto the AEC engine.
- `Voice/VoiceCoordinator.swift` — the blocking GCD `speakSync`/`listenSync` library loop and
  `DispatchQueue.main.sync` (`:107`). Its *intent* (a voice-driven library/menu) moves into
  the unified VoiceLoop.
- The voice methods in `GameViewModel.swift` (`listenForInput`, `speakNewOutput`, `readChar`
  voice path, meta-command re-listen Tasks) — replaced by the VoiceLoop.

**Do not preserve** `requiresOnDeviceRecognition = false`, `mode: .default`,
`.defaultToSpeaker`-without-AEC, `contextualStrings`-as-sole-strategy, the unconditional
`correctWithVocabulary` rewrite, or the `Info.plist`/entitlements gaps.

---

## 3. Target architecture

### 3.1 One long-lived AVAudioEngine with voice-processing I/O (AEC)

**The core decision.** A single `AVAudioEngine` is created once at voice-session start, has
voice processing enabled **while stopped**, installs its mic tap **once**, and runs for the
session lifetime. It is never `stop()`/`removeTap`/`start()`-ed per turn.

Startup sequence (order is load-bearing):

1. **iOS session, once:**
   ```swift
   let s = AVAudioSession.sharedInstance()
   try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
   try s.setAllowHapticsAndSystemSoundsDuringRecording(true)   // earcons during record
   try s.setActive(true)
   ```
   `.voiceChat` (not `.default`, **never `.measurement`** — it strips AEC). `.voiceChat`
   alone does **not** give AEC; it must be paired with voice processing (next step). On
   macOS there is no `AVAudioSession` — configure the engine directly.
   > **Bluetooth:** omit BT options by default. HFP routes are mono and AEC poorly (§7.7).
   > If you must support a BT headset, add `.allowBluetooth` (iOS 17–25) /
   > `.allowBluetoothHFP` (**iOS 26 SDK only** — the case was renamed and is *not*
   > source-compatible) under a `#if compiler(>=6.2)` guard, and treat it as a separately
   > tested path.
2. **Enable voice processing while the engine is stopped:**
   ```swift
   try engine.inputNode.setVoiceProcessingEnabled(true)   // switches BOTH I/O nodes
   ```
   iOS 13+/macOS 10.15+ — always present at our floor. Routes I/O through the
   Voice-Processing I/O unit, which applies **AEC, AGC, and noise suppression** and
   *subtracts the device's own output from the mic*.
3. **Read the format AFTER enabling VP, then tap:** enabling VP **changes the input node
   format** (notably channel count, e.g. mono→multi-channel). Reading it before causes
   silence/crashes.
   ```swift
   let fmt = engine.inputNode.outputFormat(forBus: 0)   // AFTER step 2
   engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
       recognizer.append(buf)   // forward to current request; ignored when idle
   }
   ```
4. **Optionally tame ducking** (VP ducks other in-app audio; on macOS it reduces device
   gain, lowering TTS volume):
   ```swift
   engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
       AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
           enableAdvancedDucking: false, duckingLevel: .min)   // iOS 17+/macOS 14+
   ```
5. **`engine.prepare()` then `engine.start()` once.** Keep running. Turn-taking is purely
   software state, never hardware lifecycle.

**Why this kills both complaints.** "Hears itself" goes away because the OS removes the TTS
from the mic signal before the recognizer sees it. The need to mute the mic disappears, so
there is nothing to time, so the timing bug disappears. Cold-start clipping disappears
because the engine never cold-starts mid-session. The `Thread.sleep`/`isSpeaking` loops and
`delayMs(300)` are **deleted**, not tuned.

> **Critical gotchas (high confidence):** VP cannot be toggled while running — set it once,
> stopped. AEC **does not work in the Simulator** (§7.2). On macOS, input silently fails
> without `com.apple.security.device.audio-input`.

### 3.2 TTS playback path (so AEC has a reference signal)

This is the subtle, load-bearing part — and it is now **resolved**. The AEC reference is
**the engine's own output node**. `AVSpeechSynthesizer.speak(_:)` "produces sound through the
system audio path" (Apple Frameworks engineer, Dev Forums 729218; WWDC23) — it is **not** an
engine node, so the engine's canceller has no reference for it and **does not reliably cancel
it**; the recognizer can still hear the TTS. (A *shared* `AVAudioSession` via
`usesApplicationAudioSession` is not the same as being the engine output node.)

**Primary path — render TTS through the engine.** Use `AVSpeechSynthesizer.write(_:toBufferCallback:)`
(iOS 13+/macOS 10.15+) to get `AVAudioPCMBuffer`s, convert to the engine's `Float32` format
with `AVAudioConverter` (synth buffers are frequently `Int16` — a `channelCount`/format
mismatch otherwise), and `scheduleBuffer` them on an `AVAudioPlayerNode` attached to the AEC
engine. Now the TTS **is** the engine output, AEC has a real reference, and **barge-in works**.

> **`write` completion gotcha (correctness):** `write` delivers buffers over **multiple**
> callbacks and signals completion with a **zero-length** terminal buffer. The synthesizer
> delegate `didFinish`/`didCancel` fire for `speak(_:)`, **not** for `write`. Drive
> end-of-TTS off the zero-length terminal buffer and/or `AVAudioPlayerNode.scheduleBuffer`'s
> completion handler — never `isSpeaking` polling.

**Why some new devices "just work" without this.** A *separate*, route-level canceller —
`AVAudioSession.setPrefersEchoCancelledInput` (iOS 18.2+, certain 2024+ iPhones, built-in
mic+speaker, `.playAndRecord`) — operates outside the engine graph and *can* cancel plain
`speak`. That is the narrow exception behind "it works on my phone." It is **not portable**
and must not be the baseline.

**Fallback (if `write` integration proves flaky on device): half-duplex on the running
engine.** Keep `AVSpeechSynthesizer.speak`, mute input during speech via
`engine.inputNode.isVoiceProcessingInputMuted = true` (a flag on the **running** engine, not
a teardown), and unmute on the synth's `didFinish`. Strictly better than today (no teardown,
no sleeps, deterministic `didFinish`), but **sacrifices barge-in**. Use only if the
`write`→`AVAudioConverter`→`AVAudioPlayerNode` path can't be stabilized in the §7.1 test.

### 3.3 Recognition path: a real custom LM, on-device

Full detail in [`recognition-system.md`](recognition-system.md). Summary:

- **Flip `requiresOnDeviceRecognition = true`** (gate on `SFSpeechRecognizer.supportsOnDeviceRecognition`;
  fall back to `contextualStrings`-only if false). Mandatory — a custom LM is *silently
  ignored* off-device (WWDC23). Also gives offline play, lower latency, and privacy.
- **Build a per-game custom LM** with `SFCustomLanguageModelData` (iOS 17+): full-word
  weighted `PhraseCount`s; an IF command grammar via `PhraseCountsFromTemplates`
  (`<verb> <noun>`, `go <dir>`, …) with **large** counts; `CustomPronunciation` (X‑SAMPA) for
  fantasy nouns (`grue`, `zorkmid`, `xyzzy`). `export(to:)` then `prepareCustomLanguageModel`
  off-thread, once at game load; assign `request.customizedLanguageModel`.
  Template classes come from a **curated IF verb/direction set + dictionary-as-nouns** — the
  dictionary is a flat word list with no reliable POS.
- **Truncation lives in the parser, never the recognizer.** Train on **full** words; pass the
  full recognized string to the kept tokenizer, which truncates to the 6/9-Z-char stem on
  lookup exactly as it does for typed input.
- **Matcher** maps recognized phrase → dictionary words by truncate-and-compare (exact),
  with N-best then guarded reconstructed-word edit distance as recovery. The old
  unconditional corrector (`SpeechInput.swift:400-422`) is **deleted**; default is
  pass-through (IF parsers degrade gracefully — "I don't know the word X" is recoverable; a
  silent wrong correction is not).

### 3.4 Concurrency model

**What actually caused "MainActor stalls":** audio/recognition work was placed on a
`@MainActor`-annotated `@Observable` class for convenience, then forced off-main with
`@unchecked Sendable` + `nonisolated(unsafe)` on the real mutable state (`SpeechInput.swift:16-36`:
engine, request, task, `_lastPartial`, continuations, semaphores). The recognition callback
thread, a `DispatchQueue.global` timeout loop, and main all mutate the same unsynchronized
fields. The "stall" was the main actor being asked to do blocking audio work; the "fix"
(`DispatchQueue.main.sync { MainActor.assumeIsolated {…} }` at `SpeechInput.swift:239`,
`VoiceCoordinator.swift:107`) is a deadlock hazard. Audio capture should **never** have been
on the main actor.

**New model:**

- **One `actor AudioService`** owns the engine, tap, recognition request/task, and partial
  buffer. All mutation is actor-isolated — no locks, no `nonisolated(unsafe)`, no data races.
  The tap closure is `@Sendable` and posts buffers to an `AsyncStream` the actor drains.
- **One small `@MainActor @Observable VoiceState`** holds only UI-observable flags
  (`isListening`, `isSpeaking`, `lastHeard`, `phase`). The view binds to this; it never
  touches the engine.
- **One `VoiceLoop`** (the turn state machine, §3.6) with **exactly one** `listen()` API. The
  dual `listen()`/`listenSync()` and the GCD library loop are gone. Continuations are assigned
  **synchronously before** listening starts (kills the `readLine` continuation race at
  `GameViewModel.swift:244-262`, where a third Task stored the continuation after listening
  began).
- No `DispatchQueue.main.sync`, no `MainActor.assumeIsolated`, no semaphores. Cross-actor
  handoff is `await`.

### 3.5 Barge-in

With AEC + TTS-on-engine, leave the mic open during TTS. Run recognition continuously; on the
**first credible partial result during playback**, call `synthesizer.stopSpeaking(at: .immediate)`
(and stop the player node), then route the utterance as the command. This makes "stop",
"skip", and correcting an over-long narration work — impossible today because the mic is
closed during speech.

> **Credibility gate (required).** AEC yields ~10–20 dB suppression, not infinite — residual
> TTS leakage can trigger a false partial during playback. Do **not** treat the first
> partial-during-TTS as barge-in. Require a threshold (minimum energy/duration, an
> in-vocabulary token via the Matcher, or a short ignore-window at utterance start) before
> stopping speech. (If the §3.2 fallback half-duplex path is used, barge-in is unavailable —
> document that as a known limitation.)

### 3.6 Endpointing

Replace the 200 ms string-diff polling loop (`SpeechInput.swift:115-139`, duplicated at
`:195-226`) with:

- **Primary:** the recognizer's own finalization — act on `result.isFinal`.
- **Backstop VAD:** compute frame energy with `vDSP_measqv` in the tap; after ~600–800 ms
  below threshold, call `recognitionRequest.endAudio()` to force finalization (replaces the
  2.0 s wait). **Tune the threshold against the post-voice-processing signal**, not raw mic —
  VP's AGC + noise suppression compress the dynamic range.
- **Hard cap:** keep a 15 s overall timeout as a safety backstop only.
- iOS 26+ optional: `SpeechDetector` for VAD. Not required.

### 3.7 Non-visual UX

**First-order decision: own the audio experience.** Two competing TTS engines (the app's
`AVSpeechSynthesizer` + VoiceOver reading the same SwiftUI `Text`) plus mic contention are the
"double-talk / focus theft" defect. **Decision: HearZork is the IF engine voice — it owns
audio output and the mic; it does not rely on VoiceOver to read game text.** Concretely:

- Mark spoken game content `.accessibilityHidden(true)` so VoiceOver does not double-read it.
- Detect `UIAccessibility.isVoiceOverRunning`; when true, suppress the app's own re-speaking of
  chrome VoiceOver already announces, and route game narration only through our TTS. Use
  `UIAccessibility.post(.announcement:)` for transient status.
- Keep all interactive controls properly labeled and operable by VoiceOver double-tap (don't
  assume single `.onTapGesture`), so a VoiceOver user can still drive menus by touch as a
  fallback.

**Earcons (mandatory — blind users have no "listening" cue today).** Use
`AudioServicesPlaySystemSound` (reliable during `.playAndRecord` once
`setAllowHapticsAndSystemSoundsDuringRecording(true)` is set): distinct tones for
**listening-open**, **heard/accepted**, **didn't-catch-that/error**, plus optional haptics
(`CHHapticEngine`). This is the core turn-taking affordance.

**`[MORE]` as audio chunking.** Add the interpreter hook (§5.6) so long output is delivered as
interruptible chunks rather than one multi-minute `speakAndWait` blast
(`GameViewModel.swift:157-163`). Between chunks the mic is live (AEC), so "continue"/"next"/"stop"
work via barge-in.

**`read_char` / yes-no / "press any key".** Give it a voice path (it has none —
`GameViewModel.readChar` only parks a continuation). Speak the prompt, then map: `yes`→121,
`no`→110, single letters / NATO alphabet→ZSCII, `space`/any utterance/any tap→32 or 13. This
unblocks MORE prompts, death/restart, and V4+ menus that currently hard-lock voice mode.

**Timed input (V4+).** Surface the game's timeout to the loop (§5.6): the interpreter drives
the timeout by periodically firing its interrupt routine; the loop just provides a bounded,
cancellable recognition window and resumes the continuation with a timeout sentinel on expiry
instead of blocking indefinitely.

**Resilient empty result.** Never dead-end on empty recognition (`GameViewModel.swift:144`).
The loop re-announces ("didn't catch that") with the error earcon and re-listens, bounded by
a retry count, with a spoken fallback.

---

## 4. Platform / version decision

**Recommendation: stay at iOS 17 / macOS 14 with `SFSpeechRecognizer` +
`SFCustomLanguageModelData`, behind a protocol-abstracted `Recognizer` so a `SpeechAnalyzer`
impl can be added later. Do not raise the floor to iOS 26.**

This is now **resolved** (Apple docs + Apple Staff engineer, Dev Forums 801877), not a hedge:

- HearZork's entire accuracy advantage is **vocabulary biasing** (custom LM + contextual
  strings). iOS 26's high-accuracy **`SpeechTranscriber` supports neither** — it silently
  ignores `AnalysisContext.contextualStrings` and has no custom-LM hook — and is
  hardware-gated to 16-core+ Neural Engine devices (excludes iPhone 11 family / SE 2 on iOS
  26). Migrating the command path to it would **regress** terse IF-command accuracy.
- The **only biasable** iOS 26 module is **`DictationTranscriber`**, which supports *both*
  `AnalysisContext.contextualStrings` (set via `SpeechAnalyzer.context`, ~100 short phrases)
  *and* a precompiled custom LM via the content hint
  `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration)`
  — the bridge to the **same** `SFCustomLanguageModelData` → `SFSpeechLanguageModel`
  toolchain used at iOS 17. But it runs the **older SFSpeechRecognizer-class model**, so it
  buys cleaner async/streaming ergonomics, **not** accuracy. There is no new replacement for
  `SFCustomLanguageModelData`.
- Raising the floor to iOS 26 *solely* for `SpeechTranscriber` would drop iOS 17–25 users
  **and** some iOS 26 devices, for a neutral-to-negative outcome.

**Therefore:** target iOS 17 / macOS 14; define a `Recognizer` protocol (§5.2) with an
`SFSpeechRecognizer` implementation now. If a future feature wants free-form long-form
dictation (not terse commands), add a `SpeechAnalyzer`/`DictationTranscriber` impl behind the
same protocol then — the custom-LM `Configuration` carries straight over. (Residual: only the
exact Swift initializer ergonomics for passing `customizedLanguage(...)` into
`DictationTranscriber`'s `contentHints` need Xcode-26 confirmation — a wiring detail, not a
capability question.)

---

## 5. Component spec

New components live under `HearZork/Voice/` (rewritten); `HearZork/ZMachine/` is extended.

### 5.1 `AudioGraph` (actor)

- **Responsibilities:** own the single `AVAudioEngine`; enable VP while stopped; install the
  mic tap once; own the `AVAudioPlayerNode` for TTS; expose mic buffers; provide
  `setInputMuted(_:)` (toggles `isVoiceProcessingInputMuted` on the *running* engine) and the
  ducking config. Never stop/teardown per turn.
- **Key APIs:** `AVAudioEngine`, `AVAudioInputNode.setVoiceProcessingEnabled(_:)`,
  `AVAudioNode.outputFormat(forBus:)`, `installTap(onBus:bufferSize:format:)`,
  `isVoiceProcessingInputMuted`, `voiceProcessingOtherAudioDuckingConfiguration` /
  `AVAudioVoiceProcessingOtherAudioDuckingConfiguration`, `AVAudioPlayerNode`,
  `AVAudioSession.setCategory(.playAndRecord, mode: .voiceChat, options:)`,
  `setAllowHapticsAndSystemSoundsDuringRecording(true)`.
- **Threading:** `actor`. Tap closure is `@Sendable`, forwards buffers via `AsyncStream`.
  macOS needs `com.apple.security.device.audio-input`.

### 5.2 `Recognizer` (protocol) + `SFRecognizer` (impl)

- **Protocol:** `func recognize(stream: AsyncStream<AVAudioPCMBuffer>, lm: PreparedLanguageModel?) -> AsyncStream<RecognitionEvent>`
  where `RecognitionEvent = .partial(String) | .final(String) | .unavailable`. Abstracts the
  engine choice (§4).
- **`SFRecognizer` impl:** `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest`;
  `requiresOnDeviceRecognition = true` (gated on `supportsOnDeviceRecognition`);
  `customizedLanguageModel = config`; appends buffers; endpointing off `result.isFinal` +
  VAD-triggered `endAudio()`. Sets `contextualStrings` (ranked) only in the no-custom-LM
  fallback.
- **Threading:** stateless façade; results delivered as an `AsyncStream`. No
  `nonisolated(unsafe)`.

### 5.3 `VocabularyModel`

- **Responsibilities:** turn the kept `Dictionary` into (a) a built+prepared custom LM and (b)
  a parser-side stem map. Build full-word `PhraseCount`s, command `PhraseCountsFromTemplates`,
  fantasy `CustomPronunciation`s; filter separators/punctuation/empties; rank contextual
  fallback by unusualness; export + prepare off-thread; cache per game by serial.
- **Key APIs:** `SFCustomLanguageModelData(locale:identifier:version:)`, `.PhraseCount`,
  `.PhraseCountsFromTemplates`, `.TemplatePhraseCountGenerator.Template`, `.CustomPronunciation`,
  `.export(to:)`, `SFSpeechLanguageModel.prepareCustomLanguageModel(for:clientIdentifier:configuration:)`
  (or the iOS 26 `for:configuration:` form), `SFSpeechLanguageModel.Configuration(languageModel:vocabulary:)`.
  Consumes the kept `Dictionary` — but `allWords` (`:140-158`) is repurposed to yield
  **cleaned full-word candidates**, never the recognizer's truncated stems.
- **Threading:** build/export/prepare on `Task.detached`; result handed to `Recognizer`.
  Idempotent + cached.

### 5.4 `TTSPlayer`

- **Responsibilities:** speak text through the AEC engine (primary: `write` → `AVAudioConverter`
  → `AVAudioPlayerNode`); report completion via the player node / terminal zero-length buffer;
  support immediate stop for barge-in and chunked `[MORE]` delivery.
- **Key APIs:** `AVSpeechSynthesizer.write(_:toBufferCallback:)`, `AVAudioConverter`,
  `AVAudioPlayerNode.scheduleBuffer(_:completionHandler:)`, `AVSpeechSynthesizer.stopSpeaking(at: .immediate)`.
  Fallback: `AVSpeechSynthesizer.speak` + `isVoiceProcessingInputMuted` gating with completion
  from `AVSpeechSynthesizerDelegate.didFinish/didCancel` (no barge-in).
- **Threading:** completion bridged to `async`; **no `isSpeaking` polling**.

### 5.5 `VoiceLoop` (turn state machine)

- **Responsibilities:** the one async loop. Phases: `idle → speaking → listening → recognized
  → submitting`. Drives earcons, barge-in (with credibility gate), empty-result re-prompt +
  retry, `readLine` and `read_char` grammars, timed-input timers, and `[MORE]` chunking.
  Exactly one `listen()` in flight; continuations assigned synchronously before listening.
- **Key APIs:** consumes `Recognizer` events + `TTSPlayer` + `AudioGraph`; emits via `IOSystem`
  (§5.6); `AudioServicesPlaySystemSound` for earcons.
- **Threading:** single `actor`/`@MainActor` driver. Replaces `listenForInput`,
  `speakNewOutput`, meta-command Tasks, and the whole `VoiceCoordinator` GCD loop.

### 5.6 `IOSystem` bridge (kept protocol, extended)

The protocol is the right seam (`IOSystem.swift`) but needs three additions for voice:

- **Timed input:** extend `readLine`/`readChar` to carry an optional `timeoutTenths: Int` +
  routine handle so the interpreter can express "wait N tenths then fire routine R." Current
  `async -> String/UInt8` cannot express timeouts. The `VoiceLoop` arms a timer and resumes
  with a sentinel on expiry.
- **`[MORE]` for real:** the Processor must actually **call** `io.showMore()` — it never does
  today (zero call sites) and tracks no line count. Add line counting in the window model so
  `showMore()` fires; the voice `IOSystem` impl maps it to chunked, interruptible TTS.
- **`read_char` voice contract:** the voice `IOSystem.readChar` speaks the prompt and accepts
  the yes/no/letter/space grammar (§3.7) rather than parking a continuation only an invisible
  "Press any key" button can satisfy.

The new voice loop implements `IOSystem`; the kept console keeps its own implementation.
`TestIO` stays for tests.

---

## 6. Migration plan

Each step ends with a concrete verification checkpoint. **De-risk the cutover:** build the
new chain behind a feature flag and prove each piece on-device *before* Step 5 deletes the old
voice layer — the integrated `VoiceLoop` has never run end-to-end, so a flag-gated parallel
path avoids a big-bang delete with no fallback.

**Step 0 — Fix the interpreter `sread` bug (unblocks everything; do first).**
In `Processor.swift:538-551`, make the V1‑4 arm write text at offset **1**, zero-terminated,
**no** count byte; fix the tokenizer `Dictionary.swift:80-86` to read from `textBuffer + 1`
and scan to the 0 terminator for V1‑4. (The two `if/else` arms are currently identical —
that's the tell.)
✅ **Verify:** against `zork1.z3`, "open mailbox", "read leaflet", "quit" all parse; Zork is
playable end-to-end typed. Add an **interactive** regression test (real input through
`sread`) — the Czech suite never calls `sread` and won't catch this.

**Step 1 — Fix packaging so voice can run on device at all.**
Add `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` to `Info.plist`. Add
`com.apple.security.app-sandbox` + `com.apple.security.device.audio-input` to the empty
`HearZork.entitlements`. Bundle test stories and de-hardcode the test fixture paths
(`/Users/wohl/src/zwalker/...`).
✅ **Verify:** app launches on a real iPhone and a sandboxed Mac build without crashing on
first permission request; mic prompt appears with correct copy.

**Step 2 — Build `AudioGraph` (AEC) in isolation and prove AEC works.**
Single engine, VP enabled, tap installed once, `AVAudioPlayerNode` attached. Throwaway harness:
play a known TTS phrase through the player node while logging recognition output.
✅ **Verify (the make-or-break test, §7.1):** speak a sentence via TTS through the engine;
recognition does **not** transcribe it. Test on a **real device** (AEC is dead in the
Simulator). If `write`→player-node is flaky, fall back to `speak` + `isVoiceProcessingInputMuted`
and re-verify no-self-hear half-duplex.

**Step 3 — Build `Recognizer` + on-device + `VocabularyModel` custom LM.**
`SFRecognizer` with `requiresOnDeviceRecognition = true`; `VocabularyModel` builds/exports/prepares
a custom LM from `zork1`'s dictionary (full words + templates + a few `CustomPronunciation`s
like grue/zorkmid).
✅ **Verify:** custom LM prepares without error (log build time — §7.3); spoken "examine
mailbox", "go northeast", "xyzzy", "grue" recognize correctly; recognized text is **full
words**, mapped to stems only at parser lookup. Confirm with `customizedLanguageModel` set but
`requiresOnDeviceRecognition` *false* that customization is ignored (sanity-check the gating).

**Step 4 — Build `TTSPlayer` + barge-in.**
Render TTS on the engine; implement `stopSpeaking(at:.immediate)` on first **credible** partial
(§3.5 gate).
✅ **Verify:** start a long narration, say "stop" mid-sentence, TTS halts and the command is
captured. No clipped first words; no self-barge-in from residual echo.

**Step 5 — Build `VoiceLoop` + earcons + endpointing; delete the old voice layer.**
Implement the turn state machine, earcons, `isFinal`+VAD endpointing, empty-result re-prompt,
`read_char`/yes-no grammar. **Delete** `SpeechInput.swift`, `SpeechOutput.swift`,
`VoiceCoordinator.swift`, and the voice methods in `GameViewModel.swift`.
✅ **Verify:** full hands-free Zork session by voice on device — earcon on listen, accurate
commands, "didn't catch that" recovery, yes/no prompts answered, no dead-ends, no double-talk
with VoiceOver on.

**Step 6 — Interpreter follow-ups for voice completeness.**
Add the `IOSystem` timed-input extension; wire `io.showMore()` + line counting for `[MORE]`
chunking; then Quetzal save/restore and stream-3 table writes (lower priority).
✅ **Verify:** a long room description is delivered as interruptible chunks; a timed-input game
fires its routine; save/restore round-trips; bundled interactive regression tests green.

**Step 7 — VoiceOver coexistence pass.**
`.accessibilityHidden` on spoken content; `isVoiceOverRunning` handling; labeled controls.
✅ **Verify:** with VoiceOver on system-wide, no double-talk, no mic/focus theft, menus still
operable by touch.

---

## 7. Open questions / risks — validate on-device early

1. **Suppression magnitude of the engine-rendered TTS path.** *Resolved in direction:* engine
   VP-AEC does **not** cancel `AVSpeechSynthesizer.speak`; rendering via `write` →
   `AVAudioPlayerNode` is required (§3.2). What remains is **magnitude** — AEC gives ~10–20 dB,
   not infinite, so residual TTS may still trip a false partial. **Cheap test (Step 2):** on a
   real device, play TTS through the player node while recognizing; assert the recognizer
   returns empty for the spoken text, and measure leakage to set the §3.5 barge-in credibility
   threshold. If it still hears itself even via the player node, fall back to
   `isVoiceProcessingInputMuted` half-duplex (no barge-in). Do this **before** anything else.
2. **AEC in the Simulator.** Confirmed it does **not** work there. **Mitigation:**
   conditional-compile a Simulator fallback (or require device testing for the audio path);
   never trust Simulator results for the no-self-hear claim.
3. **Custom LM build/prepare latency.** `prepareCustomLanguageModel` is "high latency"; for a
   ~600–1000-word IF dictionary the time is unknown. **Cheap test (Step 3):** log wall-clock
   for export + prepare on the oldest supported device; if seconds, do it once at game load
   behind a spoken "preparing"; if tens of seconds, **pre-build and ship the `.bin`** per
   bundled game and only `prepare` (cache) at first run.
4. **VP input-format surprises.** Enabling VP changes channel count/sample rate. **Mitigation:**
   always read `outputFormat(forBus:0)` *after* enabling VP and tap with that; assert the
   format in a log line during Step 2.
5. **macOS sandbox mic.** Even with the entitlement, validate input actually flows in a
   sandboxed build (not just `swift run`). **Cheap test (Step 1):** log non-silent buffer
   energy from the tap on macOS.
6. **Ducking volume drop.** VP ducks other audio / lowers macOS device gain — TTS may be quiet.
   **Mitigation:** `voiceProcessingOtherAudioDuckingConfiguration(duckingLevel: .min)`; verify
   TTS loudness on device; bump synth volume if needed.
7. **Bluetooth HFP + AEC.** HFP is mono and may AEC poorly. **Mitigation:** prefer
   `.defaultToSpeaker`; test a BT headset separately and, if AEC is bad over HFP, fall back to
   muted half-duplex only on BT routes. (Note the `.allowBluetoothHFP` iOS-26-SDK rename, §3.1.)
8. **iOS 26 `SpeechAnalyzer`.** *Resolved* (§4): `SpeechTranscriber` can't be biased;
   `DictationTranscriber` can (and carries the same custom LM). Not on the critical path —
   only the `contentHints` initializer ergonomics need Xcode-26 confirmation if/when adopted.
9. **`contextualStrings` reliability (fallback only).** Developers report it weak/unreliable and
   capped ~100. It is only the no-custom-LM fallback here; surface reduced accuracy as "limited
   recognition (offline model unavailable)."
10. **Interpreter test coverage gap.** Czech compliance is non-interactive and won't catch
    input-path regressions. **Mitigation:** the bundled interactive regression tests from Step
    0/1 are the real safety net for the kept interpreter; make them required CI before relying
    on the interpreter as a black box.

---

**Relevant files (absolute):**
- Rewrite/delete: `HearZork/Voice/SpeechInput.swift`, `HearZork/Voice/SpeechOutput.swift`,
  `HearZork/Voice/VoiceCoordinator.swift`; voice methods in `HearZork/UI/GameViewModel.swift`.
- Keep + fix: `HearZork/ZMachine/Processor.swift` (sread `:538-551`),
  `HearZork/ZMachine/Dictionary.swift` (tokenizer `:80-86`, `allWords` `:140-158`),
  `HearZork/ZMachine/IOSystem.swift` (extend).
- Packaging: `HearZork/Info.plist`, `HearZork/HearZork.entitlements`, `project.yml`.
- Tests: de-hardcode paths in `Tests/ZMachineTests/ComplianceTests.swift`,
  `Tests/ZMachineTests/IntegrationTests.swift`; add interactive `sread` regression tests.

---

*See [`recognition-system.md`](recognition-system.md) for the full recognition pipeline
(dictionary truncation, custom-LM construction, matcher, fallbacks).*
