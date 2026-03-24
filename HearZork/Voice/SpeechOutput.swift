import AVFoundation

/// Text-to-speech engine using AVSpeechSynthesizer.
/// Reads game output aloud, with configurable voice, rate, and pitch.
@MainActor
@Observable
final class SpeechOutput: NSObject, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    /// Thread-safe continuation for speakAndWait.
    private let continuationLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _speakContinuation: CheckedContinuation<Void, Never>?

    var isSpeaking: Bool { synthesizer.isSpeaking }
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitch: Float = 1.0
    var volume: Float = 1.0
    var voiceIdentifier: String?
    var isEnabled = true

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak the given text. If already speaking, queues it.
    func speak(_ text: String) {
        guard isEnabled else { return }
        let cleaned = cleanForSpeech(text)
        guard !cleaned.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = volume
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        synthesizer.speak(utterance)
    }

    /// Speak text and wait for completion.
    func speakAndWait(_ text: String) async {
        guard isEnabled else { return }
        speak(text)
        if synthesizer.isSpeaking {
            await withCheckedContinuation { continuation in
                continuationLock.lock()
                _speakContinuation = continuation
                continuationLock.unlock()
            }
        }
    }

    /// Resume the speak continuation from any thread (delegate callback).
    private nonisolated func completeSpeaking() {
        continuationLock.lock()
        let cont = _speakContinuation
        _speakContinuation = nil
        continuationLock.unlock()
        cont?.resume()
    }

    /// Stop speaking immediately.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        completeSpeaking()
    }

    /// Pause speaking.
    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    /// Resume speaking.
    func resume() {
        synthesizer.continueSpeaking()
    }

    func increaseRate() {
        rate = min(rate + 0.05, AVSpeechUtteranceMaximumSpeechRate)
    }

    func decreaseRate() {
        rate = max(rate - 0.05, AVSpeechUtteranceMinimumSpeechRate)
    }

    /// Clean up game text for better speech output.
    private func cleanForSpeech(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: ">", with: "")
        return result
    }

    /// Get available voices for the current language.
    static func availableVoices(language: String = "en") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { $0.name < $1.name }
    }
}

extension SpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        completeSpeaking()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        completeSpeaking()
    }
}
