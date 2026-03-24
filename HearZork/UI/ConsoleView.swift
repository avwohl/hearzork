import SwiftUI

/// The main game console: scrollable text output, optional upper window, and text input.
struct ConsoleView: View {
    @Bindable var vm: GameViewModel
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            if !vm.statusLeft.isEmpty || !vm.statusRight.isEmpty {
                statusBar
            }

            // Upper window (if split)
            if vm.upperWindowLines > 0 && vm.showConsole {
                upperWindow
            }

            if vm.showConsole {
                // Main scrollable text output
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(vm.outputLines) { line in
                                Text(line.text)
                                    .font(.system(size: vm.fontSize, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: vm.outputLines.count) {
                        if let last = vm.outputLines.last {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                // Voice-only mode: show listening indicator
                Spacer()
                voiceOnlyIndicator
                Spacer()
            }

            // Input area
            if vm.isWaitingForInput && vm.showConsole && !vm.voiceMode {
                inputBar
            } else if vm.isWaitingForInput && vm.voiceMode {
                voiceInputBar
            } else if vm.isWaitingForChar {
                charPrompt
            }
        }
        .background(platformBackground)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Text(vm.statusLeft)
                .lineLimit(1)
            Spacer()
            Text(vm.statusRight)
                .lineLimit(1)
        }
        .font(.system(size: max(vm.fontSize - 2, 12), design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary)
        .foregroundStyle(platformBackground)
        .accessibilityLabel("Status: \(vm.statusLeft). \(vm.statusRight)")
    }

    // MARK: - Upper window

    private var upperWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<vm.upperWindowLines, id: \.self) { row in
                if row < vm.upperWindowContent.count {
                    Text(String(vm.upperWindowContent[row]))
                        .font(.system(size: vm.fontSize, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(platformSecondaryBackground)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text(">")
                .font(.system(size: vm.fontSize, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Type a command", text: $inputText)
                .font(.system(size: vm.fontSize, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .focused($inputFocused)
                .onSubmit {
                    let text = inputText
                    inputText = ""
                    vm.submitInput(text)
                }
                .accessibilityLabel("Game command input")
                .accessibilityHint("Type your command and press return")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(platformSecondaryBackground)
        .onAppear {
            inputFocused = true
        }
    }

    private var voiceOnlyIndicator: some View {
        VStack(spacing: 16) {
            Image(systemName: vm.speechInput.isListening ? "waveform.circle.fill" : "mic.circle")
                .font(.system(size: 64))
                .foregroundStyle(vm.speechInput.isListening ? .green : .secondary)
                .accessibilityHidden(true)
            if vm.speechInput.isListening {
                Text(vm.speechInput.partialResult.isEmpty ? "Listening..." : vm.speechInput.partialResult)
                    .font(.system(size: vm.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if vm.speechOutput.isSpeaking {
                Text("Speaking...")
                    .font(.system(size: vm.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("Voice Mode")
                    .font(.system(size: vm.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .accessibilityLabel(vm.speechInput.isListening ? "Listening for your command" : "Voice mode active")
    }

    private var voiceInputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: vm.speechInput.isListening ? "waveform" : "mic")
                .foregroundStyle(vm.speechInput.isListening ? .green : .secondary)
                .accessibilityHidden(true)
            if vm.speechInput.isListening {
                Text(vm.speechInput.partialResult.isEmpty ? "Listening..." : vm.speechInput.partialResult)
                    .font(.system(size: vm.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Tap to speak")
                    .font(.system(size: vm.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(platformSecondaryBackground)
        .onTapGesture {
            Task { await vm.listenForInput() }
        }
        .accessibilityLabel(vm.speechInput.isListening ? "Listening" : "Tap to speak a command")
        .accessibilityAddTraits(.isButton)
    }

    private var charPrompt: some View {
        Text("Press any key...")
            .font(.system(size: vm.fontSize, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(platformSecondaryBackground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onTapGesture {
                vm.submitChar(32) // space
            }
            .accessibilityLabel("Press any key to continue")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Platform colors

    private var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }

    private var platformSecondaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }
}
