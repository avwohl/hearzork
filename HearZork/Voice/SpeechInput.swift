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

    /// Set by the recognition callback when a final or error result arrives.
    private var recognitionResult: String?
    private var bufferCount = 0

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
    /// Polls for result with a 10-second timeout.
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
        recognitionResult = nil
        bufferCount = 0

        startRecognition()

        // Poll for result — avoids withCheckedContinuation which can stall
        let start = ContinuousClock.now
        while recognitionResult == nil && (ContinuousClock.now - start) < .seconds(10) {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let result = recognitionResult ?? partialResult
        stopListening()

        if result.isEmpty {
            let fmt = audioEngine.inputNode.outputFormat(forBus: 0)
            let taskState = recognitionTask.map { "state=\($0.state.rawValue)" } ?? "nil"
            errorMessage = "No speech detected (bufs:\(bufferCount) fmt:\(Int(fmt.sampleRate))Hz/\(fmt.channelCount)ch \(taskState))"
        }

        return result
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
            recognitionResult = ""
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { @Sendable [weak self] buffer, _ in
            request.append(buffer)
            Task { @MainActor [weak self] in
                self?.bufferCount += 1
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            recognitionResult = ""
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let transcription = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDesc = error?.localizedDescription
            let nsError = error.map { $0 as NSError }

            Task { @MainActor [weak self] in
                guard let self else { return }

                if let transcription {
                    self.partialResult = transcription
                    if isFinal {
                        self.recognitionResult = transcription
                    }
                }

                if nsError != nil {
                    if nsError?.domain != "kAFAssistantErrorDomain" || nsError?.code != 216 {
                        self.errorMessage = errorDesc
                    }
                    // Signal completion on error
                    if self.recognitionResult == nil {
                        self.recognitionResult = self.partialResult
                    }
                }
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
    /// Corrects near-misses using edit distance matching.
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
