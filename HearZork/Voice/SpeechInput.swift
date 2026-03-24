import AVFoundation
@preconcurrency import Speech
#if os(macOS)
import AVKit
#endif

/// Speech recognition engine using SFSpeechRecognizer with on-device processing.
/// Captures microphone audio via AVAudioEngine and converts speech to text.
@MainActor
@Observable
final class SpeechInput: @unchecked Sendable {
    private let speechRecognizer: SFSpeechRecognizer
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Thread-safe completion for the current listen() call.
    /// Uses a lock so the continuation can be resumed from any thread.
    private let completionLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _listenContinuation: CheckedContinuation<String, Never>?
    @ObservationIgnored nonisolated(unsafe) private var _listenCompleted = false

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
        // Request microphone access first — speech recognition needs it
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

        // Then request speech recognition permission
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                Task { @MainActor in
                    continuation.resume(returning: status)
                }
            }
        }

        guard speechStatus == .authorized else {
            errorMessage = "Speech recognition not authorized"
            return false
        }

        isAuthorized = true
        return true
    }

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

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            completionLock.lock()
            _listenContinuation = continuation
            _listenCompleted = false
            completionLock.unlock()

            startRecognition()

            // Timeout on a global queue — completely independent of MainActor
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.completeListening(with: nil)
            }
        }

        stopListening()

        if result.isEmpty && errorMessage == nil {
            let fmt = audioEngine.inputNode.outputFormat(forBus: 0)
            errorMessage = "No speech detected (\(Int(fmt.sampleRate))Hz/\(fmt.channelCount)ch)"
        }

        return result
    }

    /// Thread-safe: resume the listen continuation exactly once.
    /// Can be called from any thread (recognition callback, timeout, etc).
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

    /// Start the recognition pipeline.
    private func startRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.requiresOnDeviceRecognition = false

        if !gameVocabulary.isEmpty {
            request.contextualStrings = Array(gameVocabulary.prefix(100))
        }

        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            errorMessage = "No audio input device available"
            completeListening(with: "")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { @Sendable buffer, _ in
            request.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            completeListening(with: "")
            return
        }

        // Recognition callback fires on an arbitrary thread.
        // We resume the continuation directly — no MainActor hop needed.
        recognitionTask = speechRecognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                // Update UI on MainActor
                Task { @MainActor in
                    self.partialResult = text
                }
                if result.isFinal {
                    self.completeListening(with: text)
                }
            }

            if let error {
                let nsError = error as NSError
                if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 216 {
                    Task { @MainActor in
                        self.errorMessage = error.localizedDescription
                    }
                }
                self.completeListening(with: nil)
            }
        }
    }

    /// Stop listening and clean up audio resources.
    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }

    /// Post-process recognized text against the game vocabulary.
    func correctWithVocabulary(_ text: String) -> String {
        guard !gameVocabulary.isEmpty else { return text }

        let words = text.lowercased().split(separator: " ").map(String.init)
        let vocabSet = Set(gameVocabulary.map { $0.lowercased() })

        let corrected = words.map { word -> String in
            if vocabSet.contains(word) { return word }

            var bestMatch = word
            var bestDistance = Int.max
            for vocabWord in gameVocabulary {
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

    private func editDistance(_ a: String, _ b: String) -> Int {
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
