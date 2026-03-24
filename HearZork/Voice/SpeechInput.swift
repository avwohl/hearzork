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
    private var inputContinuation: CheckedContinuation<String, Never>?

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
        // macOS requires explicit microphone permission request
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            errorMessage = "Microphone access not granted"
            return false
        }
        #endif

        isAuthorized = true
        return true
    }

    /// Listen for a single spoken command and return it as text.
    /// Times out after 10 seconds of no recognition result.
    func listen() async -> String {
        guard isAuthorized, !isListening else { return "" }

        // Check recognizer availability (requires Dictation enabled on macOS)
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

        defer {
            stopListening()
        }

        return await withCheckedContinuation { continuation in
            inputContinuation = continuation
            startRecognition()

            // Timeout: if no result after 10 seconds, stop and return what we have
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.inputContinuation != nil else { return }
                let result = self.partialResult
                if result.isEmpty {
                    self.errorMessage = "No speech detected. Try speaking louder or check microphone."
                }
                self.inputContinuation?.resume(returning: result)
                self.inputContinuation = nil
            }
        }
    }

    /// Start the recognition pipeline.
    private func startRecognition() {
        // Cancel any previous task
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        // Don't require on-device recognition — the model may not be downloaded
        // even when supportsOnDeviceRecognition reports true. The system will
        // still prefer on-device when available.
        request.requiresOnDeviceRecognition = false

        // Set contextual strings from game vocabulary
        if !gameVocabulary.isEmpty {
            // contextualStrings works best with ~100 items, prioritize unusual words
            request.contextualStrings = Array(gameVocabulary.prefix(100))
        }

        self.recognitionRequest = request

        // Set up audio input
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate audio format
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            errorMessage = "No audio input device available"
            inputContinuation?.resume(returning: "")
            inputContinuation = nil
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { @Sendable buffer, _ in
            request.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            inputContinuation?.resume(returning: "")
            inputContinuation = nil
            return
        }

        // Start recognition
        recognitionTask = speechRecognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // Extract values before crossing isolation boundary
            let transcription = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDesc = error?.localizedDescription
            let nsError = error.map { $0 as NSError }

            Task { @MainActor [weak self] in
                guard let self else { return }

                if let transcription {
                    self.partialResult = transcription

                    if isFinal {
                        self.inputContinuation?.resume(returning: transcription)
                        self.inputContinuation = nil
                    }
                }

                if nsError != nil {
                    // Don't report cancellation as an error
                    if nsError?.domain != "kAFAssistantErrorDomain" || nsError?.code != 216 {
                        self.errorMessage = errorDesc
                    }
                    self.inputContinuation?.resume(returning: self.partialResult)
                    self.inputContinuation = nil
                }
            }
        }

        // Auto-stop after silence (recognizer handles this via isFinal)
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
    /// Corrects near-misses using edit distance matching.
    func correctWithVocabulary(_ text: String) -> String {
        guard !gameVocabulary.isEmpty else { return text }

        let words = text.lowercased().split(separator: " ").map(String.init)
        let vocabSet = Set(gameVocabulary.map { $0.lowercased() })

        let corrected = words.map { word -> String in
            if vocabSet.contains(word) { return word }

            // Find closest match by edit distance
            var bestMatch = word
            var bestDistance = Int.max
            for vocabWord in gameVocabulary {
                let dist = editDistance(word, vocabWord.lowercased())
                if dist < bestDistance && dist <= 2 { // max 2 edits
                    bestDistance = dist
                    bestMatch = vocabWord.lowercased()
                }
            }
            return bestMatch
        }

        return corrected.joined(separator: " ")
    }

    /// Simple Levenshtein edit distance.
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
