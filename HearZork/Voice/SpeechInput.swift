import AVFoundation
@preconcurrency import Speech
#if os(macOS)
import AVKit
#endif

/// Speech recognition engine using SFSpeechRecognizer with on-device processing.
/// Captures microphone audio via AVAudioEngine and converts speech to text.
///
/// Recognition core methods are nonisolated so they can be driven from a
/// background GCD queue (the MainActor executor on macOS stalls with Swift
/// concurrency, so the voice loop runs on plain GCD instead).
@MainActor
@Observable
final class SpeechInput: @unchecked Sendable {
    // Recognition engine — accessed from background threads too, so nonisolated(unsafe).
    // Access is serialised by the voice-loop design (one listen at a time).
    @ObservationIgnored nonisolated(unsafe) private let speechRecognizer: SFSpeechRecognizer
    @ObservationIgnored nonisolated(unsafe) private let audioEngine = AVAudioEngine()
    @ObservationIgnored nonisolated(unsafe) private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored nonisolated(unsafe) private var recognitionTask: SFSpeechRecognitionTask?

    // Async listen support (for GameViewModel path)
    private let completionLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _listenContinuation: CheckedContinuation<String, Never>?
    @ObservationIgnored nonisolated(unsafe) private var _listenCompleted = false

    // Sync listen support (for VoiceCoordinator background loop)
    private let syncLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _syncSemaphore: DispatchSemaphore?
    @ObservationIgnored nonisolated(unsafe) private var _syncResult: String = ""
    @ObservationIgnored nonisolated(unsafe) private var _syncCompleted = false

    /// Last partial result from recognition — used for silence detection.
    /// Updated from recognition callback thread, read from timeout thread.
    @ObservationIgnored nonisolated(unsafe) private var _lastPartial: String = ""

    var isListening = false
    var isAuthorized = false
    var partialResult: String = ""
    var errorMessage: String?

    /// Words from the game dictionary to boost recognition accuracy.
    var gameVocabulary: [String] = []

    init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    }

    /// Request microphone and speech recognition permissions.
    func requestAuthorization() async -> Bool {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
        } catch {
            errorMessage = "Audio session setup failed: \(error.localizedDescription)"
            return false
        }
        #elseif os(macOS)
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            errorMessage = "Microphone access not granted"
            return false
        }
        #endif

        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            errorMessage = "Speech recognition not authorized"
            return false
        }

        isAuthorized = true
        return true
    }

    // MARK: - Async listen (used by GameViewModel)

    /// Listen for a single spoken command and return it as text.
    func listen() async -> String {
        guard isAuthorized, !isListening else { return "" }

        guard speechRecognizer.isAvailable else {
            #if os(macOS)
            errorMessage = "Speech not available. Enable Dictation in System Settings → Keyboard → Dictation"
            #else
            errorMessage = "Speech recognition not available"
            #endif
            return ""
        }

        isListening = true
        partialResult = ""
        errorMessage = nil

        let vocab = gameVocabulary
        _lastPartial = ""

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            completionLock.lock()
            _listenContinuation = continuation
            _listenCompleted = false
            completionLock.unlock()

            startRecognitionCore(vocabulary: vocab)

            // Silence detection + overall timeout
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                var elapsed: TimeInterval = 0
                var lastSeen = ""
                var silenceTime: TimeInterval = 0
                while !self._listenCompleted && elapsed < 15 {
                    Thread.sleep(forTimeInterval: 0.2)
                    elapsed += 0.2
                    let current = self._lastPartial
                    if current != lastSeen {
                        lastSeen = current
                        silenceTime = 0
                    } else if !current.isEmpty {
                        silenceTime += 0.2
                        if silenceTime >= 2.0 {
                            self.completeListening(with: current)
                            return
                        }
                    }
                }
                if !self._listenCompleted {
                    let partial = self._lastPartial
                    self.completeListening(with: partial.isEmpty ? nil : partial)
                }
            }
        }

        stopListeningCore()
        isListening = false

        if result.isEmpty && errorMessage == nil {
            let fmt = audioEngine.inputNode.outputFormat(forBus: 0)
            errorMessage = "No speech detected (\(Int(fmt.sampleRate))Hz/\(fmt.channelCount)ch)"
        }

        return result
    }

    // MARK: - Sync listen (used by VoiceCoordinator background loop)

    /// Listen for a single spoken command, blocking the calling thread.
    /// Must be called from a background queue — never from the main thread.
    nonisolated func listenSync() -> String {
        let sem = DispatchSemaphore(value: 0)

        syncLock.lock()
        _syncSemaphore = sem
        _syncResult = ""
        _syncCompleted = false
        syncLock.unlock()
        _lastPartial = ""

        // Start recognition on main thread (UI state + audio engine setup)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard self.isAuthorized, !self.isListening else {
                    self.completeSyncListening(with: "")
                    return
                }
                guard self.speechRecognizer.isAvailable else {
                    #if os(macOS)
                    self.errorMessage = "Speech not available. Enable Dictation in System Settings → Keyboard → Dictation"
                    #else
                    self.errorMessage = "Speech recognition not available"
                    #endif
                    self.completeSyncListening(with: "")
                    return
                }
                self.isListening = true
                self.partialResult = ""
                self.errorMessage = nil

                let vocab = self.gameVocabulary
                self.startRecognitionCore(vocabulary: vocab)
            }
        }

        // Silence detection + overall timeout on a background thread.
        // If we get a partial result and then 2s of silence, treat it as final.
        // Overall timeout: 15s with no speech at all.
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var elapsed: TimeInterval = 0
            var lastSeen = ""
            var silenceTime: TimeInterval = 0

            while !self._syncCompleted && elapsed < 15 {
                Thread.sleep(forTimeInterval: 0.2)
                elapsed += 0.2

                let current = self._lastPartial
                if current != lastSeen {
                    // New speech detected — reset silence timer
                    lastSeen = current
                    silenceTime = 0
                } else if !current.isEmpty {
                    // Had speech, now silence
                    silenceTime += 0.2
                    if silenceTime >= 2.0 {
                        // 2s of silence after speech → use partial result
                        self.completeAllListening(with: current)
                        return
                    }
                }
            }

            // Overall timeout — use whatever partial we have
            if !self._syncCompleted {
                let partial = self._lastPartial
                self.completeAllListening(with: partial.isEmpty ? nil : partial)
            }
        }

        sem.wait()

        syncLock.lock()
        let result = _syncResult
        syncLock.unlock()

        // Stop recognition core immediately (nonisolated, safe from background)
        stopListeningCore()

        // Update UI state synchronously on main — must complete before next
        // listenSync() call or the isListening guard will reject it.
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.isListening = false
                if !result.isEmpty {
                    // Got a result — clear any errors from task cancellation
                    self.errorMessage = nil
                } else if self.errorMessage == nil {
                    let fmt = self.audioEngine.inputNode.outputFormat(forBus: 0)
                    self.errorMessage = "No speech detected (\(Int(fmt.sampleRate))Hz/\(fmt.channelCount)ch)"
                }
            }
        }

        // Brief pause to let audio hardware settle before re-opening
        Thread.sleep(forTimeInterval: 0.1)

        return result
    }

    // MARK: - Completion handlers

    /// Resume the async listen continuation. Thread-safe, called at most once.
    private nonisolated func completeListening(with text: String?) {
        completionLock.lock()
        guard !_listenCompleted, let continuation = _listenContinuation else {
            completionLock.unlock()
            return
        }
        _listenCompleted = true
        _listenContinuation = nil
        completionLock.unlock()

        continuation.resume(returning: text ?? "")
    }

    /// Signal the sync listen semaphore. Thread-safe, called at most once.
    private nonisolated func completeSyncListening(with text: String?) {
        syncLock.lock()
        guard !_syncCompleted, let sem = _syncSemaphore else {
            syncLock.unlock()
            return
        }
        _syncCompleted = true
        _syncResult = text ?? ""
        _syncSemaphore = nil
        syncLock.unlock()
        sem.signal()
    }

    /// Called by the recognition callback — signals both async and sync paths.
    private nonisolated func completeAllListening(with text: String?) {
        completeListening(with: text)
        completeSyncListening(with: text)
    }

    // MARK: - Recognition core (nonisolated)

    /// Start the recognition pipeline. Safe to call from any thread.
    nonisolated private func startRecognitionCore(vocabulary: [String]) {
        // Clean up any leftover state from a previous recognition session
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.requiresOnDeviceRecognition = false

        if !vocabulary.isEmpty {
            request.contextualStrings = Array(vocabulary.prefix(100))
        }

        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.errorMessage = "No audio input device available" }
            }
            completeAllListening(with: "")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { @Sendable buffer, _ in
            request.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            let msg = error.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.errorMessage = "Audio engine failed to start: \(msg)" }
            }
            completeAllListening(with: "")
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                self._lastPartial = text
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.partialResult = text }
                }
                if isFinal {
                    self.completeAllListening(with: text)
                }
            }

            if let error {
                let nsError = error as NSError
                // All kAFAssistantErrorDomain errors are routine (cancellation,
                // no speech, end-of-input). Only report truly unexpected errors.
                if nsError.domain != "kAFAssistantErrorDomain" {
                    let msg = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.errorMessage = msg }
                    }
                }
                self.completeAllListening(with: nil)
            }
        }
    }

    /// Stop recognition and release audio resources. Safe to call from any thread.
    nonisolated func stopListeningCore() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    /// Stop listening (MainActor version — updates UI state too).
    func stopListening() {
        stopListeningCore()
        isListening = false
    }

    // MARK: - Vocabulary correction

    /// Post-process recognized text against the game vocabulary.
    func correctWithVocabulary(_ text: String) -> String {
        return Self.correctWithVocabulary(text, vocabulary: gameVocabulary)
    }

    /// Post-process recognized text against a vocabulary list. Thread-safe.
    nonisolated static func correctWithVocabulary(_ text: String, vocabulary: [String]) -> String {
        guard !vocabulary.isEmpty else { return text }

        let words = text.lowercased().split(separator: " ").map(String.init)
        let vocabSet = Set(vocabulary.map { $0.lowercased() })

        let corrected = words.map { word -> String in
            if vocabSet.contains(word) { return word }

            var bestMatch = word
            var bestDistance = Int.max
            for vocabWord in vocabulary {
                let dist = editDistance(word, vocabWord.lowercased())
                if dist < bestDistance && dist <= 2 {
                    bestDistance = dist
                    bestMatch = vocabWord.lowercased()
                }
            }
            return bestMatch
        }

        return corrected.joined(separator: " ")
    }

    nonisolated private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                if a[i-1] == b[j-1] {
                    dp[i][j] = dp[i-1][j-1]
                } else {
                    dp[i][j] = 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
                }
            }
        }
        return dp[m][n]
    }
}
