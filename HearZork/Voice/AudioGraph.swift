import AVFoundation

/// The single, long-lived audio engine for the whole voice session.
///
/// This is the heart of the redesign. Unlike the old code — which tore the
/// engine down and rebuilt the mic tap on every listen cycle and tried to avoid
/// "hearing itself" by muting the mic with wall-clock sleeps — this engine is
/// created once, enables the **voice-processing I/O unit** (hardware/software
/// acoustic echo cancellation + AGC + noise suppression), installs its mic tap
/// **once**, and stays running for the session. TTS is rendered *through* this
/// same engine's player node so the echo canceller has a reference signal and
/// removes the app's own speech from the mic. Nothing ever needs muting, so the
/// timing problems disappear.
///
/// Wraps non-Sendable AVFoundation objects; access is serialised by the voice
/// loop (one listen / one configure at a time), hence `@unchecked Sendable`.
final class AudioGraph: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private(set) var isConfigured = false
    private(set) var inputFormat: AVAudioFormat?

    /// Called on the realtime audio thread for every captured mic buffer.
    /// The recognizer sets this to append buffers to its recognition request
    /// (which is thread-safe). Cleared when not listening.
    nonisolated(unsafe) var micSink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Configure the session, enable echo cancellation, install the tap, and
    /// start the engine. Idempotent — safe to call before each listen/speak.
    func configureIfNeeded() throws {
        guard !isConfigured else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .voiceChat is the companion mode; AEC itself comes from the
        // voice-processing unit enabled below, not from the mode.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        // Enable AEC/AGC/noise-suppression. Must be done while stopped; it
        // switches both I/O nodes and changes the input format.
        try input.setVoiceProcessingEnabled(true)

        // Read the format AFTER enabling voice processing (channel count/sample
        // rate change), then tap with that format.
        let fmt = input.outputFormat(forBus: 0)
        inputFormat = fmt
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
            self?.micSink?(buffer)
        }

        // Player node for TTS, so synthesized audio is part of the engine output
        // and therefore part of the AEC reference signal.
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        engine.prepare()
        try engine.start()
        isConfigured = true
    }

    /// The format TTS buffers must be converted to before scheduling.
    var playerFormat: AVAudioFormat {
        engine.mainMixerNode.outputFormat(forBus: 0)
    }

    /// Schedule a (correctly-formatted) TTS buffer for playback through the engine.
    func play(_ buffer: AVAudioPCMBuffer) {
        guard isConfigured else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Stop TTS playback immediately (for barge-in / "stop").
    func stopPlayback() {
        player.stop()
    }

    /// Gate the mic without tearing anything down (half-duplex fallback).
    func setInputMuted(_ muted: Bool) {
        guard isConfigured else { return }
        engine.inputNode.isVoiceProcessingInputMuted = muted
    }

    /// Fully stop the engine (on voice-session teardown).
    func shutdown() {
        micSink = nil
        if isConfigured {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isConfigured = false
        }
    }
}
