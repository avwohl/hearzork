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
            if vm.upperWindowLines > 0 {
                upperWindow
            }

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

            // Input area
            if vm.isWaitingForInput {
                inputBar
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
