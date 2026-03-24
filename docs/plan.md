# HearZork - Plan

A Z-machine interpreter for the visually impaired, operated entirely by voice.
iOS (primary) and macOS.


## 1. What We're Building

A native Swift app that:

- Interprets Z-machine story files (versions 1-5, 7, 8). V6 excluded (graphics-dependent).
- Is fully operable via voice commands -- no touch/keyboard required.
- Reads all game output aloud via text-to-speech.
- Optionally shows a text console with adjustable font size (up to very large), or hides it entirely for voice-only mode.
- Integrates with VoiceOver and iOS/macOS accessibility infrastructure.


## 2. Lessons from Prior Z-Machine Work

Our previous Z-machine projects (zorkie, z2js, zwalker) taught us:

- The Z-machine spec is poorly defined in edge cases. The "Z-Machine Standards Document" v1.1 by Graham Nelson is the canonical reference but has ambiguities.
- Test coverage is critical. We got flack on IF forums for poor testing.
- The ZILF test suite (local copy at ~/esrc/zilf) is valuable -- integration tests that execute compiled Z-code and interpreter tests for macro evaluation. Licensed GPLv3, convertible to our use.
- The user "Vaporware" (Tara McGrew, author of ZILF) on intfiction.org is a key community contact. She pointed us to the ZILF test cases.
- Zorkie's docs/ZMACHINE_SPECIFICATION.md is our most complete internal spec reference.

### Known Z-Machine Test Suites (Interpreter Compliance)

    Suite       Author              Tests
    Praxix      Zarf + Dannii W.    Most thorough unit test for Z-machine implementations
    Czech       Amir Karger         Broad compliance with spec v1.0
    TerpEtude   Andrew Plotkin      Compliance with Standards Document 0.99
    StrictZ     T. Andersson        Strict error checking, edge cases

All available from the IF Archive. Praxix is the priority -- described as "much more thorough than Czech."


## 3. Z-Machine Versions: Scope

    Version   Support    Notes
    V1-V2     Yes        Rare, historical. Simple subset of V3.
    V3        Yes        Core target. Most Infocom games. 128KB, 255 objects.
    V4        Yes        Extended V3. 256KB, 65535 objects, timed input.
    V5        Yes        Color, sound, undo, custom alphabets. 256KB.
    V6        NO         Graphics-dependent. Incompatible with voice-only use.
    V7        Skip       Almost no games exist. Obsolete.
    V8        Yes        Identical to V5 except packed addressing (x8) and 512KB max.

V3, V5, and V8 cover 95%+ of all playable Z-machine games.


## 4. Architecture

### 4.1 Project Structure

    HearZork/
        App/                    SwiftUI app entry point, scene management
        ZMachine/
            Memory.swift        Memory model (dynamic/static/high regions)
            Header.swift        Story file header parsing (64 bytes)
            ObjectTable.swift   Object tree, attributes, properties
            Dictionary.swift    Dictionary table parsing and lookup
            TextDecoder.swift   Z-character to Unicode decoding (ZSCII)
            Instruction.swift   Opcode decoding (short/long/variable/extended forms)
            Processor.swift     Main execution loop, stack machine
            IOSystem.swift      Protocol for I/O (text output, keyboard input)
            SaveRestore.swift   Quetzal save format
        Voice/
            SpeechInput.swift   Speech recognition (SFSpeechRecognizer / SpeechAnalyzer)
            SpeechOutput.swift  Text-to-speech (AVSpeechSynthesizer)
            VocabModel.swift    Custom language model from Z-machine dictionary
            CommandParser.swift Post-recognition filtering and correction
        UI/
            ConsoleView.swift   Scrollable text console with adjustable font
            GameView.swift      Main game view (console + controls)
            SettingsView.swift  Voice, font size, display mode settings
            LibraryView.swift   Game file browser/importer
        Accessibility/
            VoiceOverBridge.swift   VoiceOver integration
            AccessibilityConfig.swift  Dynamic Type, reduce motion, etc.

### 4.2 Key Design Decisions

**Pure Swift.** No C/ObjC interpreter port. Clean-room implementation from the spec. This avoids inheriting bugs from existing C interpreters and gives us full control over the I/O layer.

**Protocol-based I/O.** The Z-machine core communicates through an IOSystem protocol. The voice layer and console are both implementations. This keeps the interpreter testable without UI.

**Shared codebase for iOS and macOS.** SwiftUI with platform-specific adaptations. One Xcode project, two targets.


## 5. Voice System Design

### 5.1 Speech Recognition (Input)

**Primary API:** `SFSpeechRecognizer` with `SFSpeechAudioBufferRecognitionRequest` (iOS 10+ / macOS 10.15+). On-device recognition with `requiresOnDeviceRecognition = true` for privacy and no network dependency.

**Future:** `SpeechAnalyzer` / `SpeechTranscriber` when targeting iOS 26+ (announced WWDC 2025). Faster, more accurate, designed for long-form and distant audio.

**Audio pipeline:** `AVAudioEngine` captures microphone input, feeds audio buffers to the speech recognizer in real time.

### 5.2 Exploiting the Z-Machine Dictionary

This is a key advantage. Every Z-machine game contains a dictionary table at a known offset (header byte $08). It lists every word the game's parser understands. Typical Infocom games have 600-1000 entries.

**Strategy (layered):**

1. **Custom Language Model (iOS 17+):** At game load time, extract the dictionary, decode Z-characters to Unicode, and build an `SFCustomLanguageModelData` with:
   - All dictionary words as custom vocabulary (with X-SAMPA pronunciations for fantasy terms like "zorkmid", "Flathead", "Dimwit")
   - Phrase templates from common IF command patterns: "[verb] [noun]", "[verb] [noun] with [noun]", "go [direction]", "look at [noun]"
   - Weighted phrases via `PhraseCount` boosting game-specific terms
   - Call `prepareCustomLanguageModel()` on a background thread during game loading

2. **Contextual Strings (iOS 10+, fallback):** Populate `SFSpeechRecognitionRequest.contextualStrings` with the most unusual dictionary words (proper nouns, fantasy terms). Limited to ~100 items, so prioritize words unlikely to be in the system vocabulary.

3. **Post-Recognition Correction:** After speech-to-text, tokenize the result and fuzzy-match each word against the dictionary (edit distance). Handle truncation: V1-3 games only store first 6 characters, V4+ store 9. Map recognized words to their truncated dictionary forms before passing to the Z-machine's parser.

### 5.3 Text-to-Speech (Output)

**API:** `AVSpeechSynthesizer` with `AVSpeechUtterance`.

**Considerations:**
- Queue utterances so game output is read in order.
- Allow interrupting speech with a new voice command (e.g., say "stop" to skip long room descriptions).
- Configurable voice, rate, and pitch in settings.
- Pause TTS while listening for input to avoid feedback.
- Handle the Z-machine's `[MORE]` prompt -- speak a chunk, wait for "continue" or "more" voice command.

### 5.4 Voice Command Flow

    1. Game prints text -> AVSpeechSynthesizer reads it aloud
    2. After TTS completes (or game requests input), begin listening
    3. Visual/audio cue that app is listening (subtle tone or "Ready")
    4. User speaks command ("go north", "take the lamp")
    5. SFSpeechRecognizer returns text, filtered through VocabModel
    6. Corrected text fed to Z-machine as keyboard input
    7. Z-machine processes, outputs response -> back to step 1

### 5.5 Meta Voice Commands (Outside the Game)

These commands control the app itself, not the game:

    "save game"             Trigger Z-machine save
    "restore game"          Trigger Z-machine restore
    "repeat" / "say again"  Re-read last game output
    "louder" / "softer"     Adjust TTS volume
    "faster" / "slower"     Adjust TTS rate
    "show console"          Show text display
    "hide console"          Voice-only mode
    "bigger text"           Increase console font
    "smaller text"          Decrease console font
    "help"                  List voice commands
    "quit game"             Back to library

These are intercepted before the game sees them. Prefix with "game" to send literally (e.g., "game save" sends "save" to the Z-machine parser).


## 6. Console / Display

- SwiftUI `ScrollView` + `Text` with monospaced font.
- Font size slider in settings, plus voice commands. Range: 12pt to 72pt.
- High contrast mode: white on black, or user-configurable.
- "Hide console" mode: screen goes to a minimal listening indicator. All interaction via voice.
- Supports Dynamic Type for system-wide font scaling.
- Status bar (Z-machine upper window) shown as a fixed header when console is visible; read aloud periodically or on "status" voice command when hidden.


## 7. Game Library

- Import .z1-.z5, .z8 files via Files app, Share Sheet, or drag-and-drop (macOS).
- Store in app's Documents directory.
- Display game name, version, serial number (parsed from header).
- Remember last-played position per game.
- Bundled sample game: a small public domain .z3 (e.g., advent.z3) so the app works out of the box.


## 8. Testing Strategy

### 8.1 Interpreter Compliance Tests

Run all four community test suites as automated tests:

    Priority  Suite       Format    What It Tests
    1         Praxix      .z5       Comprehensive opcode/behavior compliance
    2         Czech       .z5       Broad spec compliance
    3         TerpEtude   .z5       Standards document compliance
    4         StrictZ     .z5       Edge cases and error handling

These are Z-code story files. Our interpreter runs them; we verify output matches expected results.

### 8.2 ZILF Test Suite

Convert relevant ZILF integration tests (from ~/esrc/zilf) to Swift XCTests. These test Z-code execution behavior and are complementary to the community suites.

### 8.3 Real Game Testing

    Game                Version   Why
    Zork I              .z3       The canonical test. Complex parser, large map.
    Hitchhiker's Guide  .z3       Complex puzzles, unusual parser tricks.
    Planetfall          .z3       Well-tested against zorkie.
    Curses              .z5       Large V5 game (253KB), tests size limits.
    Anchorhead          .z8       Large V8 game (508KB), tests V8 addressing.
    Photopia            .z5       Award winner, modern IF conventions.
    Lost Pig            .z8       IF Competition winner, good V8 test.

### 8.4 Unit Tests

- Each ZMachine/ module gets unit tests: memory operations, header parsing, object table manipulation, text encoding/decoding, instruction decoding, dictionary lookup.
- Voice/ module: mock speech recognizer, test post-recognition correction against dictionary, test command parsing.

### 8.5 Accessibility Testing

- VoiceOver audit on every screen.
- Test full game session in voice-only mode (console hidden).
- Test with actual visually impaired users (beta program).


## 9. Development Phases

### Phase 1: Z-Machine Core (Interpreter)

Build the interpreter with no UI. Text-in, text-out via IOSystem protocol.

    - Memory model, header parsing
    - Object table
    - Text encoding/decoding (ZSCII, Z-characters, abbreviations)
    - Dictionary parsing
    - Instruction decoder (all forms: short, long, variable, extended)
    - Opcode implementation (V3 first, then V4/V5/V8 additions)
    - Stack machine (call stack + evaluation stack)
    - Input/output through IOSystem protocol
    - Save/restore (Quetzal format)

Exit criteria: Pass Praxix and Czech test suites for V3 and V5.

### Phase 2: Console App (iOS)

Minimal UI to play games via typing.

    - SwiftUI console view with text input
    - Game library (import, list, launch)
    - Adjustable font size
    - Status bar display
    - Basic VoiceOver support

Exit criteria: Play through Zork I start to finish on device.

### Phase 3: Voice Integration

Add speech recognition and TTS.

    - AVAudioEngine microphone capture
    - SFSpeechRecognizer integration (on-device)
    - AVSpeechSynthesizer for game output
    - Dictionary extraction and custom language model (SFCustomLanguageModelData)
    - Post-recognition vocabulary correction
    - Meta voice commands
    - Listening state management (when to listen, when to speak)

Exit criteria: Play Zork I entirely by voice, no touch interaction.

### Phase 4: Polish and Accessibility

    - Voice-only mode (hide console)
    - VoiceOver full audit and fixes
    - Dynamic Type support
    - High contrast themes
    - [MORE] prompt handling via voice
    - Interrupt/repeat TTS
    - Settings persistence
    - macOS target (Catalyst or native SwiftUI)

Exit criteria: Accessibility audit passes. Usable by visually impaired tester.

### Phase 5: Release

    - App Store metadata, screenshots, preview video
    - Bundled sample game
    - TestFlight beta with accessibility community
    - App Store submission (iOS + macOS)


## 10. Apple Neural Engine -- Summary

Yes, late-model Apple devices have a Neural Engine (dedicated ML hardware):

    Chip            Year    ANE Cores    TOPS
    A12+            2018+   8-16         5-35
    M1+             2020+   16           11-38

On-device speech recognition (SFSpeechRecognizer) has been available since iOS 13 / macOS Catalina (2019) and runs inference on the Neural Engine where available. It requires an A9 chip or newer but works best on A12+ with the full ANE.

The Neural Engine absolutely helps. On-device recognition means:
- No internet required
- No 1-minute audio duration limit
- No per-day request limits
- Low latency (no network round-trip)
- Privacy (audio never leaves the device)

The Z-machine dictionary is a significant advantage: we can build a custom language model (`SFCustomLanguageModelData`, iOS 17+) from the game's own vocabulary, boosting recognition accuracy for the exact words the game understands.


## 11. Open Questions

1. **Minimum deployment target.** iOS 17 gives us `SFCustomLanguageModelData` (the dictionary-based language model). iOS 15/16 would reach more devices but with weaker vocabulary matching. Recommend iOS 17+.

2. **Timed input.** V4+ games can request input with a timeout (e.g., Border Zone). How to handle this in voice mode? Probably: play a ticking sound, auto-submit empty input on timeout.

3. **Character-by-character input.** Some games use single-keypress input (`read_char`). In voice mode: map short words to keys ("yes" -> 'y', "no" -> 'n'), or use a phonetic alphabet for arbitrary characters.

4. **Sound effects.** V5+ games can play sounds. Worth supporting via `AVAudioPlayer`, but low priority -- few games use them, and they may conflict with TTS.

5. **Transcript/log.** Should we offer a text transcript of the voice session? Useful for accessibility and debugging.

6. **Vaporware's test suite.** The user mentioned a specific test suite lead from Vaporware (Tara McGrew) on IF forums. The ZILF test cases at ~/esrc/zilf are likely what was meant. Confirm with the forum thread. The four community suites (Praxix, Czech, TerpEtude, StrictZ) are the interpreter compliance tests.
