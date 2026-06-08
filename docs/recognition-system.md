# HearZork — Speech Recognition System

How HearZork should turn a spoken command into Z-machine parser input.

This document specifies the **recognition pipeline** only: getting clean audio in,
biasing the recognizer with the game's own vocabulary, and mapping the result back to
words the game's parser understands. Text-to-speech, the turn state machine, and the rest
of the voice UX are covered by the broader voice redesign; they appear here only where they
affect recognition.

> **Confidence.** The Apple API surface below was verified against WWDC23 ("Customize
> on-device speech recognition"), WWDC25 session 277 ("SpeechAnalyzer"), Apple
> documentation, Apple-engineer Developer-Forums posts, and mechanism reasoning, then
> adversarially reviewed and a second adjudication pass resolved the two contested items
> (AEC-of-`speak` and iOS-26 biasing). What remains are a handful of values that **no source
> can settle** — they must be measured on hardware — collected in §11. Everything else is
> high-confidence.

---

## 1. Why the old approach fails

The current recognizer (`HearZork/Voice/SpeechInput.swift`) is built on four wrong choices:

| # | Defect | Location | Effect |
|---|--------|----------|--------|
| 1 | Mic + `AVAudioEngine` torn down and rebuilt **every listen cycle** | `SpeechInput.swift:298-334` (`startRecognitionCore`), `:377-384` | First word of each command is clipped while the engine cold-starts → "often misses speech" |
| 2 | **No acoustic echo cancellation**; instead the mic is muted during TTS with sleeps | `GameViewModel.swift:142,153-166` (`speakNewOutput`), `VoiceCoordinator.swift:103-121` | App "hears itself"; the mute/sleep dance breaks timing and drops speech |
| 3 | `requiresOnDeviceRecognition = false` + weak `contextualStrings` (capped 100) instead of a custom LM | `SpeechInput.swift:309-312` | With on-device off, **any custom LM is silently ignored**; `contextualStrings` is far too weak for a 600–1000-word dictionary |
| 4 | Vocabulary fed to the recognizer is **truncated dictionary stems**, and an edit-distance pass rewrites good words into those stems | `Dictionary.swift:140` (`allWords`), `SpeechInput.swift:395-445` (`correctWithVocabulary`) | Recognizer is biased toward non-words; correct input gets corrupted |

The new system fixes all four: one long-lived audio graph with voice-processing echo
cancellation, an on-device custom language model built from the game dictionary, and
**truncation-aware** (not edit-distance) matching.

---

## 2. Architecture overview

```
                         game loads
                              │
                              ▼
                  ┌───────────────────────┐
                  │  VocabularyModel       │   built once per game, cached by serial
                  │  dict stems → full     │
                  │  words + custom LM     │
                  └───────────┬───────────┘
                              │ compiled LM (.bin on disk)
                              ▼
  mic ──► AudioGraph ──► Recognizer ──► Matcher ──► CommandRouter ──► Z-machine
        (one engine,      (on-device,   (truncation-  (meta cmd vs   (sread/aread
         AEC always on)    custom LM)    aware)        game input)     tokenize)
                              ▲
                              │ reference signal (so AEC can subtract TTS)
                       TTS rendered through the SAME engine
```

Five components, each with a single job:

- **AudioGraph** — one persistent `AVAudioEngine` with voice-processing I/O (echo
  cancellation). Owns the single mic tap and the TTS playback node. Never torn down
  mid-session.
- **VocabularyModel** — turns the game dictionary into (a) full words to recognize and
  (b) a compiled on-device custom language model.
- **Recognizer** — protocol with an `SFSpeechRecognizer` implementation (the baseline).
  An optional iOS 26 `SpeechAnalyzer` path is discussed in §8.
- **Matcher** — maps a recognized phrase to dictionary words using Z-machine truncation
  rules. Exact, not fuzzy.
- **CommandRouter** — decides whether a recognized phrase is a meta command ("louder",
  "repeat") or game input, and forwards accordingly.

---

## 3. The game dictionary as a recognition asset

Every Z-machine story file contains a dictionary table listing every word the parser
understands (typically 600–1000 entries). This is the single biggest accuracy lever we
have: we know the exact closed vocabulary the user will draw from.

### 3.1 The truncation rule (critical)

Dictionary resolution is measured in **Z-characters**, not letters:

| Version | Dict entry bytes | Significant Z-chars |
|---|---|---|
| V1–V3 (most Infocom `.z3`, incl. Zork I/II/III) | 4 | **6** |
| V4+ (`.z5`, `.z8`) | 6 | **9** |

For ordinary lowercase words, **1 letter = 1 Z-char**, so the limit is **6 letters (V3)** or
**9 letters (V5/V8)**. Digits and punctuation cost **2 Z-chars** each (a shift into alphabet
A2), so a word containing them hits the limit after fewer visible characters.

The interpreter already truncates at lookup time:

```swift
// TextDecoder.swift:246 — TextEncoder.encodeDictionaryWord
let maxZChars = version <= 3 ? 6 : 9
...
if zchars.count >= maxZChars { break }   // extra letters discarded before dictionary match
```

Called from `Dictionary.lookup` → `Dictionary.tokenize` (`Dictionary.swift:37,121`), which
runs inside `sread`/`aread` (`Processor.swift:554`). **Consequence:** typing or saying
`mailboxxxx`, `mailbox`, or `mailbo` all encode to the same 6 Z-chars and match the same
entry. The dictionary stores only the truncated stem (e.g. `mailbo`, `examin`, `northe`).

### 3.2 Two consequences for recognition

**On output (recognized text → game): truncation is a non-issue.** Hand the full
recognized word to the game verbatim. The interpreter truncates and matches exactly as it
would for typed input. **Never** truncate the word yourself, and **never** rewrite it into
the stored stem. (The current `correctWithVocabulary` does exactly the wrong thing.)

**On input (building the recognizer's bias): truncation is the bug to fix.** The current
code feeds the recognizer the truncated stems (`mailbo`, `examin`). The user says the full
word `mailbox`. Biasing a recognizer toward a non-word fragment is worse than useless: the
acoustic model can't map it, and it competes with the correct full word. We bias toward
**full natural words**, reconstructed from the stems (§4).

### 3.3 The hidden upside

Because the parser only inspects the first 6 (V3) / 9 (V5) characters, **the recognizer
only has to get the first 6/9 characters right.** `examine`, `examines`, `examining` all
collapse to `examin` and parse identically. Long words half-misheard still parse if their
stem is correct. This makes prefix/truncation matching (§6) exact rather than fuzzy, and
makes stem collisions (multiple full words → one stem) harmless — the parser never
distinguished them anyway.

---

## 4. VocabularyModel — dictionary → custom language model

Built once when a game loads, off the main thread, cached on disk keyed by the story file's
serial/checksum so it is rebuilt once per game, not once per launch. Building is the slow
step — do it during the "loading <game>" announcement.

`SFCustomLanguageModelData`, `SFSpeechLanguageModel`, `Configuration`, and
`request.customizedLanguageModel` all require **iOS 17.0 / macOS 14.0** — matching the
current deployment floor.

### 4.1 Extract and bucket

1. Call `Dictionary.allWords(decoder:)` to get every dictionary stem. Record, per word: the
   raw stem, its length, and whether it is "at the limit" (length == 6 in V1–3, == 9 in V4+)
   — i.e. probably truncated.
2. Split into two buckets:
   - **Complete words** (below the limit): use as-is. This is the bulk of useful command
     vocabulary — verbs, directions, short nouns (`take`, `drop`, `open`, `north`, `lamp`,
     `key`, `sword`, `grue`).
   - **At-the-limit stems** (probably truncated): reconstruct full word(s) — §4.2.

> Z-machine dictionaries are **flat word lists**. Each entry has optional trailing data
> bytes, but their meaning is compiler-specific (ZIL vs Inform differ) and **not a reliable
> part-of-speech source** — do not depend on them to classify words.

### 4.2 Reconstruct full words from stems

For each at-the-limit stem, produce candidate full words to bias toward:

1. **English prefix expansion.** Look the stem up as a prefix in a bundled English word list
   (e.g. a trimmed SCOWL list shipped with the app). `examin → examine, examiner`;
   `northe → northeast, northern`; `mailbo → mailbox`. Add the expansion(s).
2. **Keep the stem too**, as a fallback, with a generated **custom pronunciation** (§4.3).
3. **Fantasy words that don't expand** (`zorkmi ← zorkmid`, `froboz ← frobozz`): no English
   match exists. Keep the stem with an X-SAMPA pronunciation. This still parses, because the
   game only needs the first 6/9 chars right (§3.3).

Always keep the **stem ↔ full-word** mapping for the Matcher (§6).

### 4.3 Build the custom language model

Use `SFCustomLanguageModelData`'s result-builder DSL — **not** `contextualStrings`
(`contextualStrings` is capped at ~100 entries, carries no weights/grammar/pronunciation,
and is far too weak for this dictionary). Confirmed API shape:

```swift
let data = SFCustomLanguageModelData(locale: Locale(identifier: "en_US"),
                                     identifier: "com.awohl.hearzork.<gameId>",
                                     version: "<storySerial>") {

    // (a) Weighted vocabulary — every reconstructed full word. Higher count = stronger bias.
    for w in vocab {
        SFCustomLanguageModelData.PhraseCount(phrase: w.text, count: w.weight)   // e.g. 50–100
    }

    // (b) Command grammar via templates. The `count` is split evenly across all generated
    //     permutations, so use HEAVY counts to make command-shaped utterances dominate.
    SFCustomLanguageModelData.PhraseCountsFromTemplates(classes: [
        "verb":      IF_VERBS,          // curated closed set, intersected with the game dict
        "direction": IF_DIRECTIONS,     // n,s,e,w,ne,nw,se,sw,up,down,in,out
        "noun":      gameNouns,         // = the dictionary words (everything not a known verb/dir)
    ]) {
        SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("<verb> <noun>", count: 100_000)
        SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("<verb> <noun> with <noun>", count: 20_000)
        SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("go <direction>", count: 20_000)
        SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("look at <noun>", count: 20_000)
    }

    // (c) Pronunciations for fantasy terms and kept stems (X-SAMPA; locale supports a subset).
    for p in pronunciations {
        SFCustomLanguageModelData.CustomPronunciation(grapheme: p.word, phonemes: p.xsampa)  // e.g. "grue" -> ["g r u"]
    }
}
```

The **POS problem is solved by construction**, not by the dictionary: `verb` and
`direction` come from curated IF closed sets (verbs are a small, stable cross-game set —
`take, get, drop, go, look, examine, open, close, read, put, turn, …`), and every remaining
dictionary word is treated as a `noun`. No POS tagging of the story file is required.

Then compile and prepare (off-thread, once at load):

```swift
try await data.export(to: binURL)                                   // compile to .bin
try await SFSpeechLanguageModel.prepareCustomLanguageModel(
    for: binURL,
    clientIdentifier: "com.awohl.hearzork",                         // iOS 17 form
    configuration: lmConfig)                                        // writes LM + Vocab files to caches
```

> The `clientIdentifier:` form is **deprecated in iOS 26** in favor of
> `prepareCustomLanguageModel(for:configuration:)` / `…ignoresCache:`. Write against the
> iOS 17 form for back-compat and accept the deprecation warning, or `#if available`-branch.

### 4.4 Attach to recognition

```swift
guard SFSpeechRecognizer.supportsOnDeviceRecognition else { /* fall back, see below */ }
request.requiresOnDeviceRecognition = true          // MANDATORY for the custom LM
request.customizedLanguageModel = SFSpeechLanguageModel.Configuration(
    languageModel: lmURL, vocabulary: vocabURL)     // vocabulary URL is optional
request.addsPunctuation = false                      // commands aren't prose
request.shouldReportPartialResults = true
```

A custom LM **requires** `requiresOnDeviceRecognition = true` — verified from WWDC23: *"you
first enforce that the recognition is run on device. Failing to do so will cause requests to
be serviced without customization."* All customized requests are serviced strictly
on-device; customization data never goes over the network. This flips the current
`= false`, and is what we want anyway (offline, private, no per-request/duration limits).

**Fallback** when `supportsOnDeviceRecognition` is false (older/unsupported hardware): drop
the custom LM, set `requiresOnDeviceRecognition = false`, and load the top ~100
most-frequent dictionary words into `contextualStrings`. Weaker, but degrades gracefully.

---

## 5. Getting clean audio in (echo cancellation)

The recognizer is only as good as its input. The app "hears itself" because there is **no
acoustic echo cancellation** and TTS plays into an open mic. The fix is not to mute the mic
— it's to cancel the echo and leave the mic open.

### 5.1 One persistent audio graph with voice processing

- Create **one** `AVAudioEngine` for the whole session. Install the mic tap **once**. Never
  tear it down between turns — this alone fixes the clipped-first-word problem.
- **AEC comes from the voice-processing I/O unit, not from a session mode.** While the
  engine is **stopped**, call:
  ```swift
  try audioEngine.inputNode.setVoiceProcessingEnabled(true)   // iOS 13+/macOS 10.15+
  ```
  This enables **echo cancellation + noise suppression + automatic gain control** and
  "takes any audio coming from the device out of the incoming mic audio." Enabling it on the
  input node forces **both** I/O nodes into voice-processing mode. It **cannot** be toggled
  while the engine is running, and it does **not** work in manual-rendering mode.
- **Read the input format AFTER enabling voice processing** — it changes (notably channel
  count: mono can become multi-channel). Install the tap with
  `inputNode.outputFormat(forBus: 0)` read *after* the call, or you get silence/crashes.
  ```swift
  try audioEngine.inputNode.setVoiceProcessingEnabled(true)
  let fmt = audioEngine.inputNode.outputFormat(forBus: 0)     // AFTER enabling
  audioEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
      request.append(buf)
  }
  audioEngine.prepare(); try audioEngine.start()              // ONCE, kept running for the session
  ```
- **iOS session (once):** `setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])`
  then `setActive(true)`. `.voiceChat` is the right companion mode for two-way audio, but
  **the mode alone does not apply AEC** — `setVoiceProcessingEnabled(true)` is what does.
  Do **not** use `.measurement` (it disables processing). `.allowBluetoothHFP` is iOS-26-only
  (it was `.allowBluetooth` on iOS 17–25) — guard it with `#if compiler(>=6.2)` or omit it
  (Bluetooth HFP routing is deprioritized).
- **Counter the ducking side-effect:** voice processing ducks other in-app audio. Set
  ```swift
  audioEngine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
      AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)  // iOS 17+/macOS 14+
  ```
- **macOS:** there is no `AVAudioSession`; configure the engine/voice-processing directly.
  Add the `com.apple.security.device.audio-input` entitlement (currently the entitlements
  file is **empty**) plus `NSMicrophoneUsageDescription`, and request access via
  `AVCaptureDevice`. Without the entitlement, engine input fails.
- `AVAudioSession.setPrefersEchoCancelledInput` (iOS 18.2+, 2024+ iPhones only) is **not
  needed** here — voice-processing routes already apply AEC.

### 5.2 Route TTS so the canceller has a reference

AEC works by subtracting a **reference** of the played audio from the mic signal, and that
reference only exists for **the engine's own nodes**. This is now **confirmed** (Apple
Frameworks engineer, Dev Forums thread 729218; WWDC23 §10235): `AVSpeechSynthesizer.speak`
"produces sound through the system audio path," **not** through your `AVAudioEngine`, so the
voice-processing canceller has no reference for it and **does not reliably cancel it** —
the TTS leaks into the mic. (Sharing the app's `AVAudioSession` via `usesApplicationAudioSession`
is not the same as being an engine node.) So **render TTS through the engine**:

```swift
// AVSpeechSynthesizer.write delivers PCM buffers over MULTIPLE callbacks; the final
// callback delivers a ZERO-LENGTH buffer (the completion signal).
synth.write(utterance) { buffer in
    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return /* done */ }
    let converted = convert(pcm, to: playerNode.outputFormat)   // synth buffers are often Int16 -> Float32
    playerNode.scheduleBuffer(converted)                        // play through the AEC engine
}
```

Pin down these gotchas (all reported/verified):

- **Format conversion is required.** `write` buffers are commonly Int16 and/or a different
  channel count than the engine; convert with `AVAudioConverter` to the player node's
  format, or `scheduleBuffer` fails on a `channelCount` mismatch.
- **Completion comes from the player node, not the synth delegate.** `didFinish`/`didCancel`
  fire for `speak(_:)`, **not** for `write`. Detect end-of-TTS from the zero-length terminal
  buffer and/or `AVAudioPlayerNode.scheduleBuffer`'s completion handler.
- **Barge-in needs a credibility gate.** AEC is imperfect (~10–20 dB suppression, not
  infinite), so residual TTS leakage can trigger a false "partial result" while TTS plays.
  Don't treat the *first* partial-during-TTS as a barge-in. Require a credibility threshold
  (minimum energy/duration, or an in-vocabulary token via the Matcher, or a short ignore
  window at utterance start) before calling `synth.stopSpeaking(at: .immediate)`.
- **Why some devices "just work" anyway.** A *separate*, route-level canceller —
  `AVAudioSession.setPrefersEchoCancelledInput` (iOS 18.2+, certain 2024+ iPhones only,
  built-in mic+speaker route, `.playAndRecord`) — operates outside the engine graph and
  *can* cancel plain `speak`. That's the narrow exception behind "it works on my new phone."
  It is **not portable** (hardware/OS-gated) and must not be the baseline.
- **Fallback** if the `write` → `AVAudioPlayerNode` integration proves flaky on device: keep
  `AVSpeechSynthesizer.speak`, and instead of muting/tearing down, gate recognition with
  `inputNode.isVoiceProcessingInputMuted = true` on the *running* engine while speaking
  (unmute on the synth's `didFinish`). Far better than today's teardown, but **no barge-in**.
  Prefer the engine-rendered path for guaranteed AEC and real barge-in.

### 5.3 Endpointing (end of utterance)

Replace the 0.2 s string-diff polling (`SpeechInput.swift:120-139`) with deterministic
signals:

- **Primary:** `SFSpeechRecognitionResult.isFinal`. (Note: `speechRecognitionMetadata` /
  `SFVoiceAnalytics` only populate on the *final* result, so they can't drive live
  endpointing.)
- **Active VAD:** compute frame energy in the tap (`vDSP_measqv`) and call
  `request.endAudio()` after ~600–800 ms below threshold — far snappier than the current
  2.0 s wait. **Tune the threshold against the post-voice-processing signal**, not raw mic:
  AGC + noise suppression compress the dynamic range, so a raw-mic threshold misfires.
- **Backstop:** keep a ~15 s overall cap to force completion if nothing finalizes.
- **iOS 26 option:** `SpeechDetector` (a dedicated VAD module in `SpeechAnalyzer`) can
  replace the hand-rolled energy VAD where available.
- **No grammar/FSG API exists** for `SFSpeechRecognizer` — recognition is biased, never
  constrained, to your vocabulary. Heavy `PhraseCount` weights + template expansion (§4.3)
  plus the Matcher (§6) are how we approximate "only these phrases."

---

## 6. Matcher — recognized phrase → parser words

Truncation-aware and exact. Replaces `correctWithVocabulary` entirely.

For each recognized phrase:

1. Lowercase and split on spaces **and the game's dictionary separators**
   (`Dictionary.separators`), mirroring the parser.
2. For each token, compute `truncate(token, N)` where N = 6 Z-chars (V1–3) or 9 (V4+) using
   the **same `TextEncoder` the interpreter uses**. Membership test: does the truncated form
   exist in the dictionary? This is the exact operation the parser performs, so it is a
   precise in-vocabulary check — `examining → examin ✓`, `mail box → mailbo ✓`.
3. If a token's truncation is **not** in the dictionary, attempt recovery in order:
   - **N-best:** scan the recognizer's alternative `transcriptions` (beyond
     `bestTranscription`) for a token whose truncation *is* in-dictionary.
   - **Reconstructed-word edit distance:** edit-distance against the **full reconstructed
     word list** (§4.2), not the stems; threshold ≤1 for short words, ≤2 for long. Protect
     common English function words from being "corrected."
   - **Homophone/number map:** to/two/too, for/four, ate/eight, digit words ↔ digits.
4. Emit the result **as full words**. Let the interpreter truncate at lookup. Never
   substitute stems into the output.

The Matcher never blocks a turn: if recovery fails, pass the best transcription through
unchanged and let the game respond ("I don't know the word …") — correct IF behavior, and
audible feedback for the user.

---

## 7. CommandRouter — meta vs game input

A recognized phrase is checked against **meta commands** (handled locally) before being sent
to the game:

- `repeat` / `say again`, `louder` / `quieter`, `faster` / `slower`, `stop` (interrupt TTS),
  `show console` / `hide console`, `bigger/smaller text`, `help`, `quit game`.
- Prefix `game …` forces the rest to the parser literally (e.g. "game save" sends "save").
- **Single-key contexts** (`read_char`, "press any key", yes/no): map spoken words to ZSCII
  codes — "yes"→`121` (`y`), "no"→`110` (`n`), "enter/continue/more"→`13`, NATO/letter words
  → their letter's ZSCII, any utterance or tap for "press any key" → `32`/`13`. Prompt the
  user audibly for what's expected.
- **Timed input** (V4+ `aread` with time + routine operands): the **interpreter** drives the
  timeout by periodically invoking the game's interrupt routine; the recognizer just needs a
  **bounded, cancellable** recognition window. On timeout, resume the input continuation with
  an empty string / timeout sentinel so the game's timer logic runs. (Mind that
  `Processor.swift:559` stores `13` for V5+ line input — keep the read_char/timed-input
  return contract distinct from that.)

Meta matching uses the same truncation-aware comparison so "louder" survives mishearing.

**Non-visual cues (essential for blind users).** Signal listening state with earcons:
`AudioServicesPlaySystemSound` for "now listening" / "got it" / "didn't catch that." During
`.playAndRecord` these are suppressed unless you set
`AVAudioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)`. Optionally pair with
`CHHapticEngine`.

---

## 8. Recognizer abstraction & platform choice

Define a protocol so the engine choice is swappable:

```swift
protocol SpeechRecognizing {
    func prepare(vocabulary: VocabularyModel) async throws
    func startListening() -> AsyncStream<RecognitionEvent>   // .partial(String) / .final(Transcript)
    func stop()
}
```

- **`SFSpeechRecognizer` implementation — the baseline.** iOS 17 / macOS 14, on-device +
  `SFCustomLanguageModelData`. This is the supported path and the only **confirmed** way to
  bias recognition toward the IF vocabulary.
- **iOS 26 `SpeechAnalyzer` — do NOT migrate command recognition to it.** This is now
  **resolved** (Apple docs + Apple Staff engineer, Dev Forums thread 801877): WWDC25's
  high-accuracy `SpeechTranscriber` supports **no contextual biasing and no custom
  vocabulary** — it silently ignores `AnalysisContext.contextualStrings` and has no custom-LM
  hook — and is hardware-gated to 16-core+ Neural Engine devices (iPhone 11 / SE2 return it
  unavailable). For terse IF commands biased toward fantasy nouns, it would **regress**. The
  **only biasable** iOS 26 module is **`DictationTranscriber`**, which supports *both*
  `AnalysisContext.contextualStrings` (set via `SpeechAnalyzer.context`, ~100 short phrases)
  *and* a precompiled custom LM via the content hint
  `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration)`
  — the bridge to the *same* `SFCustomLanguageModelData` → `SFSpeechLanguageModel` toolchain
  from §4. But `DictationTranscriber` runs the **older SFSpeechRecognizer-class model**, so
  adopting it buys cleaner async/streaming ergonomics, **not** raw accuracy. There is no new
  replacement for `SFCustomLanguageModelData`.

**Deployment-target recommendation:** keep the **iOS 17 / macOS 14** floor with
`SFSpeechRecognizer` + custom LM as the supported baseline. Do **not** raise the floor to
iOS 26 for `SpeechTranscriber` — it drops iOS 17–25 users, excludes 8-core-NE iOS 26
devices, and yields neutral-to-negative results for short biased commands. Revisit only if
Apple adds contextual biasing/custom vocabulary to `SpeechTranscriber` in a later 26.x.

---

## 9. Validate on-device early (cheap experiments)

These need **real hardware — voice processing / AEC does not work in the Simulator.**

1. **AEC cancels our TTS?** Minimal app: voice-processing engine on, mic open, render TTS
   through the engine (`write` → `AVAudioPlayerNode`), log whether recognition fires on the
   TTS. Compare against plain `AVSpeechSynthesizer.speak`. **Highest priority** — the whole
   "leave the mic open" model depends on this. Determines §5.2 primary vs fallback.
2. **Custom LM build time.** Time `export` + `prepareCustomLanguageModel` for a ~1000-word
   Zork dictionary. Confirm it's acceptable during game-load and cacheable by serial.
3. **On-device honoring.** Confirm with `customizedLanguageModel` set but
   `requiresOnDeviceRecognition = false` that customization is dropped (proves the flag is
   load-bearing), and that `supportsOnDeviceRecognition` is true on target devices.
4. **Recognition lift.** Measure command accuracy with vs without the custom LM on a fixed
   set of spoken commands ("open the mailbox", "go northeast", "examine the leaflet",
   "turn on lamp"). Quantifies the dictionary advantage.
5. **`SpeechAnalyzer`** (only if pursuing §8 path 2): `DictationTranscriber` availability and
   whether `AnalysisContext.contextualStrings` / `SFCustomLanguageModelData` actually apply.

---

## 10. What to delete / migrate

The recognition rewrite removes, not patches:

- `SpeechInput.startRecognitionCore` per-cycle engine teardown/rebuild (`:298-334`,
  `:377-384`).
- `SpeechInput.correctWithVocabulary` / `editDistance` stem-correction (`:395-445`).
- The dual `listen()` / `listenSync()` paths and the `nonisolated(unsafe)` /
  `@unchecked Sendable` sprawl — replaced by one async recognizer behind `SpeechRecognizing`.
- The mic-muting + sleep gating in `GameViewModel.speakNewOutput` (`:142,153-166`) and
  `VoiceCoordinator.speakSync` (`:103-121`).
- `contextualStrings` as the primary bias, and `requiresOnDeviceRecognition = false`.

**Keep:** the entire Z-machine interpreter (`HearZork/ZMachine/*`), including `Dictionary`,
`TextEncoder`/`TextDecoder`, and the `IOSystem` boundary — the recognizer plugs in behind
`IOSystem.readLine`, unchanged.

**De-risk the cutover:** the new `AudioGraph` → `Recognizer` → `Matcher` → `VoiceLoop` chain
has never run end-to-end. Build it behind a feature flag and prove it on-device (§9) *before*
deleting the old voice layer, rather than a big-bang swap with no fallback.

---

## 11. Confidence / still to verify

High-confidence (verified, build against these):

- `setVoiceProcessingEnabled(true)` gives AEC+AGC+noise-suppression; enable while stopped, on
  the input node (forces both nodes); input format changes — read it *after* enabling.
- The full `SFCustomLanguageModelData` API (builder, `PhraseCount`,
  `PhraseCountsFromTemplates` / `TemplatePhraseCountGenerator.Template`, `CustomPronunciation`,
  `export(to:)`, `prepareCustomLanguageModel`, `Configuration(languageModel:vocabulary:)`).
- Custom LM **requires** `requiresOnDeviceRecognition = true` (WWDC23).
- `contextualStrings` is ~100-cap, unweighted, biases-not-constrains; no grammar API exists.
- Render TTS through the engine for AEC; `write` buffers need `AVAudioConverter`; `write`
  completion is not the synth delegate.
- **Engine voice-processing AEC does *not* reliably cancel `AVSpeechSynthesizer.speak`**
  (Apple engineer, Forums 729218; WWDC23) — the `write` → `AVAudioPlayerNode` path is
  required. The route-level `setPrefersEchoCancelledInput` exception is iOS 18.2+ / 2024+
  iPhones only and not portable (§5.2).
- **iOS 26 biasing is `DictationTranscriber`-only** (Apple docs + Apple engineer, Forums
  801877): it accepts `contextualStrings` and a custom LM via
  `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:)`; `SpeechTranscriber`
  supports neither. SFSpeechRecognizer stays the baseline (§8).

Genuinely device-only (no source can settle these — measure on hardware):

- The **suppression magnitude** of the `write` → `AVAudioPlayerNode` reference path (~10–20 dB,
  not infinite) — hence the barge-in credibility gate is still required.
- The exact device/OS boundary of the route-level `setPrefersEchoCancelledInput` exception.
- Tuned values: VAD energy threshold against the post-voice-processing signal, barge-in
  credibility threshold, ducking level, custom-LM build time.
