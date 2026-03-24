import SwiftUI
import AVFoundation

/// App-level voice coordinator shared between library and game screens.
/// Persists voice mode preference and provides speech input/output for library navigation.
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
        // Default to true unless user has explicitly turned it off
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

    /// Speak text and wait for completion.
    func speak(_ text: String) async {
        guard voiceEnabled else { return }
        await speechOutput.speakAndWait(text)
    }

    /// Speak text without waiting.
    func speakAsync(_ text: String) {
        guard voiceEnabled else { return }
        speechOutput.speak(text)
    }

    /// Listen for a voice command and return the recognized text.
    func listen() async -> String {
        guard voiceEnabled, isAuthorized else { return "" }
        isListening = true
        let result = await speechInput.listen()
        isListening = false
        return result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stop any current speech.
    func stopSpeaking() {
        speechOutput.stop()
    }
}
