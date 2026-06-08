import AVFoundation
@preconcurrency import Speech

/// On-device diagnostic for the make-or-break question of the voice redesign:
/// **does the engine's voice-processing acoustic echo cancellation remove the
/// app's own TTS from the mic, so the recognizer does NOT transcribe it?**
///
/// It speaks a known phrase through the shared AEC engine (the real TTS path)
/// with the mic open and continuous recognition running, then reports whether
/// the recognizer "heard" the phrase (echo leaked → AEC failed) or stayed quiet
/// (AEC working). The `muteDuringSpeech` toggle exercises the half-duplex
/// fallback. Reuses the VoiceCoordinator's single shared engine so there is
/// never a second engine fighting for the audio session.
///
/// AEC is inert in the Simulator — run this on a real device.
@MainActor
@Observable
final class AECProbe {
    enum Verdict: Equatable {
        case idle, running, clear, leaked, inconclusive
        case failed(String)
    }

    let phrase = "the quick brown fox jumps over the lazy dog beside the white house"

    var status = "Idle. Tap Run on a real device — echo cancellation is off in the Simulator."
    var heard = ""
    var verdict: Verdict = .idle
    var muteDuringSpeech = false
    var isRunning = false

    private let voice: VoiceCoordinator
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    @ObservationIgnored nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored nonisolated(unsafe) private var task: SFSpeechRecognitionTask?

    init(voice: VoiceCoordinator) { self.voice = voice }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        verdict = .running
        heard = ""
        defer { isRunning = false }

        // Free the library voice loop so we have sole use of the shared engine.
        voice.stopLibraryLoop()

        status = "Requesting microphone & speech permission…"
        guard await requestPermissions() else {
            verdict = .failed("Permission denied")
            status = "Microphone or speech permission was denied."
            return
        }

        let audio = voice.audio
        voice.speechOutput.audio = audio
        do {
            try audio.configureIfNeeded()
        } catch {
            verdict = .failed(error.localizedDescription)
            status = "Audio engine failed: \(error.localizedDescription)"
            return
        }
        guard recognizer.isAvailable else {
            verdict = .failed("Recognizer unavailable")
            status = "Speech recognizer is unavailable on this device."
            return
        }

        // Continuous recognition on the persistent mic tap.
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = req
        audio.micSink = { [weak req] buffer in req?.append(buffer) }
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in self.heard = text }
        }

        // Speak the phrase through the AEC engine with the mic open.
        if muteDuringSpeech { audio.setInputMuted(true) }
        status = muteDuringSpeech
            ? "Speaking with the mic muted (half-duplex fallback)…"
            : "Speaking with the mic open — listening for echo…"
        await voice.speechOutput.speakAndWait(phrase)
        if muteDuringSpeech { audio.setInputMuted(false) }

        // Let any trailing recognition flush, then tear down recognition only
        // (the shared engine keeps running).
        status = "Finishing up…"
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        req.endAudio()
        task?.cancel(); task = nil
        audio.micSink = nil
        request = nil

        let captured = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if captured.isEmpty {
            verdict = .clear
            status = "Clear — the recognizer heard nothing while speaking. Echo cancellation is working: keep the engine-rendered TTS path with the mic open (barge-in)."
        } else if phraseOverlap(captured) {
            verdict = .leaked
            status = "Echo leaked — the recognizer transcribed the spoken phrase, so AEC is NOT cancelling the TTS on this path. Use the half-duplex fallback (turn on \"mute mic during speech\")."
        } else {
            verdict = .inconclusive
            status = "Inconclusive — the recognizer picked up “\(captured)”, which doesn't match the phrase. Likely ambient noise; rerun in a quiet room."
        }
    }

    /// True if the captured transcript shares notable (non-stopword) words with the phrase.
    private func phraseOverlap(_ captured: String) -> Bool {
        let stop: Set<String> = ["the", "a", "an", "over", "near", "beside"]
        let phraseWords = Set(phrase.lowercased().split(separator: " ").map(String.init)).subtracting(stop)
        let heardWords = Set(captured.lowercased().split(separator: " ").map(String.init))
        return !phraseWords.isDisjoint(with: heardWords)
    }

    private func requestPermissions() async -> Bool {
        #if os(iOS)
        let mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        #else
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard mic else { return false }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable s in c.resume(returning: s) }
        }
        return speech == .authorized
    }
}
