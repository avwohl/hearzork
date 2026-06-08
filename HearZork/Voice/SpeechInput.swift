import AVFoundation
@preconcurrency import Speech

/// Speech recognition over the shared, persistent AudioGraph.
///
/// Unlike the old implementation, the audio engine and mic tap are never torn
/// down per listen cycle (that clipped the first word of every command). Each
/// `listen()` simply attaches a fresh recognition request to the always-running
/// engine, biases it with the game's custom language model on-device, and
/// detaches when done. Acoustic echo cancellation (in AudioGraph) means there is
/// nothing to mute and no sleeps to time.
///
/// Public surface (isListening / partialResult / errorMessage / isAuthorized /
/// gameVocabulary / requestAuthorization / listen / stopListening) is unchanged
/// so the UI keeps binding to it.
@MainActor
@Observable
final class SpeechInput: @unchecked Sendable {
    @ObservationIgnored nonisolated(unsafe) private let recognizer: SFSpeechRecognizer
    @ObservationIgnored nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored nonisolated(unsafe) private var task: SFSpeechRecognitionTask?

    /// Shared engine. Set by VoiceCoordinator (on the main actor); read from
    /// the nonisolated stop path too.
    @ObservationIgnored nonisolated(unsafe) weak var audio: AudioGraph?

    private let lock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _continuation: CheckedContinuation<String, Never>?
    @ObservationIgnored nonisolated(unsafe) private var _completed = false
    @ObservationIgnored nonisolated(unsafe) private var _lastPartial = ""

    var isListening = false
    var isAuthorized = false
    var partialResult = ""
    var errorMessage: String?

    /// Setting the vocabulary (re)builds the custom language model off-thread.
    @ObservationIgnored private var vocab: VocabularyModel?
    var gameVocabulary: [String] = [] {
        didSet { rebuildVocabulary(gameVocabulary) }
    }

    /// Version drives the truncation length for matching (set with the vocab).
    @ObservationIgnored var gameVersion: Int = 3

    init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    }

    private func rebuildVocabulary(_ words: [String]) {
        guard !words.isEmpty else { vocab = nil; return }
        let model = VocabularyModel(words: words, version: gameVersion)
        vocab = model
        Task.detached { await model.prepareLanguageModel() }
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        #if os(iOS)
        // Audio session is configured by AudioGraph; just request permissions.
        let micGranted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard micGranted else { errorMessage = "Microphone access not granted"; return false }
        #elseif os(macOS)
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { errorMessage = "Microphone access not granted"; return false }
        #endif

        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable s in c.resume(returning: s) }
        }
        guard status == .authorized else { errorMessage = "Speech recognition not authorized"; return false }
        isAuthorized = true
        return true
    }

    // MARK: - Listen

    /// Listen for one spoken command and return it (lowercased, vocab-canonicalised).
    func listen() async -> String {
        guard isAuthorized, !isListening, let audio else { return "" }
        guard recognizer.isAvailable else {
            #if os(macOS)
            errorMessage = "Speech not available. Enable Dictation in System Settings."
            #else
            errorMessage = "Speech recognition not available"
            #endif
            return ""
        }
        do { try audio.configureIfNeeded() }
        catch { errorMessage = "Audio engine failed: \(error.localizedDescription)"; return "" }

        isListening = true
        partialResult = ""
        errorMessage = nil
        _lastPartial = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = false
        vocab?.apply(to: req, onDeviceAvailable: recognizer.supportsOnDeviceRecognition)
        self.request = req

        // Feed the persistent tap's buffers into this request.
        audio.micSink = { [weak req] buffer in req?.append(buffer) }

        let raw = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            lock.lock(); _continuation = cont; _completed = false; lock.unlock()

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self._lastPartial = text
                    Task { @MainActor in self.partialResult = text }
                    if result.isFinal { self.complete(with: text) }
                }
                if let error {
                    let ns = error as NSError
                    let routine = ns.domain == "kAFAssistantErrorDomain"
                        || (ns.domain == NSURLErrorDomain && ns.code == -999)
                    if !routine { Task { @MainActor in self.errorMessage = error.localizedDescription } }
                    self.complete(with: self._lastPartial)
                }
            }

            // Endpointing: end the audio after ~0.9s of silence following speech,
            // with a 15s overall cap. The recogniser then delivers isFinal.
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                var elapsed = 0.0, silence = 0.0, last = ""
                while !self._completed && elapsed < 15 {
                    Thread.sleep(forTimeInterval: 0.1); elapsed += 0.1
                    let cur = self._lastPartial
                    if cur != last { last = cur; silence = 0 }
                    else if !cur.isEmpty {
                        silence += 0.1
                        if silence >= 0.9 { self.request?.endAudio(); break }
                    }
                }
                if !self._completed && elapsed >= 15 { self.request?.endAudio() }
            }
        }

        // Detach from the engine (engine keeps running).
        audio.micSink = nil
        task?.cancel(); task = nil
        request = nil
        isListening = false

        let canon = vocab?.canonicalize(raw) ?? raw.lowercased()
        return canon
    }

    private nonisolated func complete(with text: String) {
        lock.lock()
        guard !_completed, let cont = _continuation else { lock.unlock(); return }
        _completed = true; _continuation = nil
        lock.unlock()
        cont.resume(returning: text)
    }

    /// Stop the current recognition (does not stop the shared engine).
    func stopListening() {
        stopListeningCore()
        isListening = false
    }

    nonisolated func stopListeningCore() {
        request?.endAudio()
        task?.cancel()
        complete(with: _lastPartial)
        audio?.micSink = nil
    }

    // MARK: - Vocabulary correction (truncation-aware pass-through)

    func correctWithVocabulary(_ text: String) -> String {
        vocab?.canonicalize(text) ?? text.lowercased()
    }
}
