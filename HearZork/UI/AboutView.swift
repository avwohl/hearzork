import SwiftUI

/// About screen with app info, credits, and GitHub link.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // App icon and name
                    VStack(spacing: 8) {
                        Image(systemName: "ear.and.waveform")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("HearZork")
                            .font(.largeTitle.bold())
                        Text("Version \(appVersion) (\(buildNumber))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)

                    // Description
                    VStack(spacing: 12) {
                        Text("A voice-controlled Z-machine interpreter designed for visually impaired players.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                        Text("Play classic interactive fiction games like Zork entirely by voice. No touch or keyboard required.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 20)

                    // Features
                    VStack(alignment: .leading, spacing: 12) {
                        featureRow("mic.fill", "Full voice control with on-device speech recognition")
                        featureRow("speaker.wave.2.fill", "Text-to-speech reads game output aloud")
                        featureRow("textformat.size", "Adjustable large text console")
                        featureRow("eye.slash", "Voice-only mode hides all visuals")
                        featureRow("cpu", "Z-machine versions 1-5, 7, 8")
                        featureRow("checkmark.seal", "Passes Czech compliance test suite")
                    }
                    .padding(.horizontal, 20)

                    Divider().padding(.horizontal, 20)

                    // Links
                    VStack(spacing: 12) {
                        Link(destination: URL(string: "https://github.com/avwohl/hearzork")!) {
                            HStack {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                Text("Source Code on GitHub")
                            }
                            .font(.body)
                        }
                        .accessibilityLabel("Open HearZork source code on GitHub")

                        Link(destination: URL(string: "https://github.com/avwohl/hearzork/issues")!) {
                            HStack {
                                Image(systemName: "exclamationmark.bubble")
                                Text("Report an Issue")
                            }
                            .font(.body)
                        }
                        .accessibilityLabel("Report a bug or request a feature")
                    }

                    Divider().padding(.horizontal, 20)

                    // Credits
                    VStack(spacing: 8) {
                        Text("Credits")
                            .font(.headline)
                        Text("Z-machine specification by Graham Nelson and the IF community")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Czech test suite by Amir Karger")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Games sourced from the Interactive Fiction Archive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 20)
                }
            }
            .navigationTitle("About")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
        }
    }
}
