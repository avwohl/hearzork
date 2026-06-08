import SwiftUI

/// One-tap on-device test for acoustic echo cancellation: speaks a known phrase
/// through the engine with the mic open and reports whether the recognizer
/// hears the app's own speech. See AECProbe.
struct AECProbeView: View {
    var voice: VoiceCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var probe: AECProbe?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Plays a fixed phrase through the speaker with the mic open, then checks whether speech recognition picked up the app's own voice. Run it on a real device — echo cancellation does not work in the Simulator.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    GroupBox("Phrase") {
                        Text(probe?.phrase ?? "")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let probe {
                        verdictBadge(probe.verdict)

                        GroupBox("Recognizer heard") {
                            Text(probe.heard.isEmpty ? "—" : probe.heard)
                                .font(.body.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel("Recognizer heard: \(probe.heard.isEmpty ? "nothing" : probe.heard)")
                        }

                        Text(probe.status)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle("Mute mic during speech (half-duplex fallback)", isOn: Binding(
                            get: { probe.muteDuringSpeech },
                            set: { probe.muteDuringSpeech = $0 }
                        ))
                        .disabled(probe.isRunning)

                        Button {
                            Task { await probe.run() }
                        } label: {
                            Label(probe.isRunning ? "Running…" : "Run probe", systemImage: "waveform.badge.mic")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(probe.isRunning)
                        .accessibilityHint("Speaks a phrase and reports whether the microphone hears it")
                    }
                }
                .padding()
            }
            .navigationTitle("AEC Probe")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { if probe == nil { probe = AECProbe(voice: voice) } }
        }
    }

    @ViewBuilder
    private func verdictBadge(_ verdict: AECProbe.Verdict) -> some View {
        let (text, color, icon): (String, Color, String) = {
            switch verdict {
            case .idle:          return ("Not run yet", .secondary, "circle")
            case .running:       return ("Running…", .blue, "waveform")
            case .clear:         return ("AEC working — no echo heard", .green, "checkmark.circle.fill")
            case .leaked:        return ("Echo leaked — AEC not cancelling TTS", .red, "exclamationmark.triangle.fill")
            case .inconclusive:  return ("Inconclusive — rerun in a quiet room", .orange, "questionmark.circle.fill")
            case .failed(let m): return ("Failed: \(m)", .red, "xmark.octagon.fill")
            }
        }()
        Label(text, systemImage: icon)
            .font(.headline)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Result: \(text)")
    }
}
