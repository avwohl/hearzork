import SwiftUI
import AVFoundation

/// App-level voice coordinator shared between library and game screens.
///
/// Ensures TTS and mic never overlap — the mic picks up speaker output on macOS
/// (no echo cancellation like iOS AVAudioSession provides).
@MainActor
@Observable
final class VoiceCoordinator: @unchecked Sendable {
    let speechInput = SpeechInput()
    let speechOutput = SpeechOutput()

    var isAuthorized = false
    var isListening = false

    /// Persisted in UserDefaults. Defaults to true (voice-first app).
    var voiceEnabled = true {
        didSet {
            UserDefaults.standard.set(voiceEnabled, forKey: "voiceEnabled")
        }
    }

    init() {
        if UserDefaults.standard.object(forKey: "voiceEnabled") != nil {
            voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
        }
    }

    /// Enable voice, requesting authorization if needed.
    func enableVoice() async -> Bool {
        if !isAuthorized {
            let ok = await speechInput.requestAuthorization()
            guard ok else { return false }
            isAuthorized = true
        }
        voiceEnabled = true
        return true
    }

    func disableVoice() {
        voiceEnabled = false
        speechInput.stopListening()
        speechOutput.stop()
    }

    /// Speak text and wait for completion. Stops any active listening first.
    func speak(_ text: String) async {
        guard voiceEnabled else { return }
        speechInput.stopListening()
        await speechOutput.speakAndWait(text)
        // Brief pause for echo/reverb to fade — use GCD, not Task.sleep
        await delayMs(300)
    }

    /// Speak text without waiting.
    func speakAsync(_ text: String) {
        guard voiceEnabled else { return }
        speechInput.stopListening()
        speechOutput.speak(text)
    }

    /// Listen for a voice command and return the recognized text.
    /// Ensures TTS is stopped first to avoid hearing our own output.
    func listen() async -> String {
        guard voiceEnabled, isAuthorized else { return "" }
        if speechOutput.isSpeaking {
            speechOutput.stop()
            await delayMs(300)
        }
        isListening = true
        let result = await speechInput.listen()
        isListening = false
        return result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stop any current speech.
    func stopSpeaking() {
        speechOutput.stop()
    }

    /// Delay using GCD instead of Task.sleep (which stalls on MainActor).
    private func delayMs(_ ms: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) {
                continuation.resume()
            }
        }
    }
}
