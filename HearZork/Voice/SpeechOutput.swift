import AVFoundation

/// Text-to-speech. Renders speech **through the shared AudioGraph** (via
/// `AVSpeechSynthesizer.write` → `AVAudioConverter` → the engine's player node)
/// so the voice-processing echo canceller has a reference signal and the
/// recogniser does not hear the app's own speech. When no shared engine is
/// attached it falls back to plain `AVSpeechSynthesizer.speak`.
///
/// The public surface (isSpeaking / isEnabled / volume / rate / speak /
/// speakAndWait / stop / increaseRate / decreaseRate) is unchanged so the UI
/// keeps binding to it.
@MainActor
@Observable
final class SpeechOutput: NSObject, @unchecked Sendable {
    @ObservationIgnored nonisolated(unsafe) let synthesizer = AVSpeechSynthesizer()

    /// Shared engine for AEC-referenced playback. Set by VoiceCoordinator.
    @ObservationIgnored weak var audio: AudioGraph?

    private let continuationLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _speakContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var _engineSpeaking = false

    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitch: Float = 1.0
    var volume: Float = 1.0
    var voiceIdentifier: String?
    var isEnabled = true

    /// True while speaking (engine path or synth path).
    var isSpeaking: Bool {
        _engineSpeaking || synthesizer.isSpeaking
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        u.pitchMultiplier = pitch
        u.volume = volume
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        return u
    }

    /// Speak text (fire and forget).
    func speak(_ text: String) {
        guard isEnabled else { return }
        let cleaned = cleanForSpeech(text)
        guard !cleaned.isEmpty else { return }
        let utterance = makeUtterance(cleaned)
        if let audio, audio.isConfigured {
            renderThroughEngine(utterance, audio: audio, onDone: nil)
        } else {
            synthesizer.speak(utterance)
        }
    }

    /// Speak text and suspend until synthesis completes.
    func speakAndWait(_ text: String) async {
        guard isEnabled else { return }
        let cleaned = cleanForSpeech(text)
        guard !cleaned.isEmpty else { return }
        let utterance = makeUtterance(cleaned)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuationLock.lock()
            _speakContinuation = cont
            continuationLock.unlock()
            if let audio, audio.isConfigured {
                renderThroughEngine(utterance, audio: audio) { [weak self] in
                    self?.completeSpeaking()
                }
            } else {
                synthesizer.speak(utterance)
                // completion arrives via the delegate
            }
        }
    }

    /// Render an utterance to PCM and play it through the AEC engine.
    private func renderThroughEngine(_ utterance: AVSpeechUtterance,
                                     audio: AudioGraph,
                                     onDone: (@Sendable () -> Void)?) {
        _engineSpeaking = true
        let outFormat = audio.playerFormat
        synthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                // Terminal zero-length buffer = synthesis finished. (The synth
                // delegate's didFinish does NOT fire for write().)
                self._engineSpeaking = false
                onDone?()
                return
            }
            if let converted = Self.convert(pcm, to: outFormat) {
                audio.play(converted)
            }
        }
    }

    /// Convert a synthesized buffer (often Int16) to the engine's output format.
    private static func convert(_ input: AVAudioPCMBuffer, to outFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input.format == outFormat { return input }
        guard let converter = AVAudioConverter(from: input.format, to: outFormat) else { return nil }
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }

    private nonisolated func completeSpeaking() {
        continuationLock.lock()
        let cont = _speakContinuation
        _speakContinuation = nil
        continuationLock.unlock()
        cont?.resume()
    }

    /// Stop speaking immediately (also used for barge-in).
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        audio?.stopPlayback()
        _engineSpeaking = false
        completeSpeaking()
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }

    func increaseRate() { rate = min(rate + 0.05, AVSpeechUtteranceMaximumSpeechRate) }
    func decreaseRate() { rate = max(rate - 0.05, AVSpeechUtteranceMinimumSpeechRate) }

    private func cleanForSpeech(_ text: String) -> String {
        var result = text
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: ">", with: "")
        return result
    }

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
