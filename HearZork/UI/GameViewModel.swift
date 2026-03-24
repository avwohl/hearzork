import Foundation
import SwiftUI

/// Bridges the Z-machine processor and the SwiftUI console view.
/// Implements IOSystem so the processor can print text and request input.
@MainActor
@Observable
final class GameViewModel: IOSystem, @unchecked Sendable {
    // MARK: - Published state for the UI

    var outputLines: [OutputLine] = []
    var statusLeft: String = ""
    var statusRight: String = ""
    var isWaitingForInput = false
    var isWaitingForChar = false
    var isRunning = false
    var gameName: String = ""
    var fontSize: CGFloat = 18

    // Upper window state
    var upperWindowLines: Int = 0
    var upperWindowContent: [[Character]] = []
    var upperCursorLine: Int = 0
    var upperCursorCol: Int = 0

    // MARK: - Internal state

    private var processor: Processor?
    private var inputContinuation: CheckedContinuation<String, Never>?
    private var charContinuation: CheckedContinuation<UInt8, Never>?
    private var currentWindow: Int = 0
    private var pendingText: String = ""
    private var gameTask: Task<Void, Never>?

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let style: TextStyle
    }

    enum TextStyle {
        case normal, bold, italic, fixed, reverse
    }

    // MARK: - Game lifecycle

    func loadGame(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let memory = try Memory(storyData: data)
        let header = Header(memory)
        gameName = url.deletingPathExtension().lastPathComponent
        outputLines = []
        statusLeft = ""
        statusRight = ""
        upperWindowLines = 0
        isRunning = true

        let proc = Processor(memory: memory, io: self)
        self.processor = proc

        gameTask = Task { [weak self] in
            await proc.start()
            await MainActor.run {
                self?.isRunning = false
                self?.flushPendingText()
            }
        }
    }

    func stopGame() {
        processor?.running = false
        gameTask?.cancel()
        gameTask = nil
        isRunning = false
        // Resume any waiting continuations
        inputContinuation?.resume(returning: "")
        inputContinuation = nil
        charContinuation?.resume(returning: 13)
        charContinuation = nil
    }

    /// Called by the UI when the user submits text input.
    func submitInput(_ text: String) {
        guard isWaitingForInput else { return }
        isWaitingForInput = false
        // Echo input
        appendOutput(text + "\n")
        inputContinuation?.resume(returning: text.lowercased())
        inputContinuation = nil
    }

    /// Called by the UI when the user presses a key (for read_char).
    func submitChar(_ char: UInt8) {
        guard isWaitingForChar else { return }
        isWaitingForChar = false
        charContinuation?.resume(returning: char)
        charContinuation = nil
    }

    // MARK: - IOSystem implementation

    nonisolated func print(_ text: String) {
        Task { @MainActor in
            if self.currentWindow == 0 {
                self.pendingText += text
                // Flush on newlines for responsiveness
                if text.contains("\n") {
                    self.flushPendingText()
                }
            } else {
                self.writeToUpperWindow(text)
            }
        }
    }

    nonisolated func printToUpper(_ text: String) {
        Task { @MainActor in
            self.writeToUpperWindow(text)
        }
    }

    nonisolated func readLine(maxChars: Int) async -> String {
        await MainActor.run {
            self.flushPendingText()
            self.isWaitingForInput = true
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.inputContinuation = continuation
            }
        }
    }

    nonisolated func readChar() async -> UInt8 {
        await MainActor.run {
            self.flushPendingText()
            self.isWaitingForChar = true
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.charContinuation = continuation
            }
        }
    }

    nonisolated func showStatusBar(location: String, rightSide: String) {
        Task { @MainActor in
            self.statusLeft = location
            self.statusRight = rightSide
        }
    }

    nonisolated func splitWindow(lines: Int) {
        Task { @MainActor in
            self.upperWindowLines = lines
            // Initialize upper window grid
            if lines > 0 {
                let cols = 80
                self.upperWindowContent = Array(repeating: Array(repeating: Character(" "), count: cols), count: lines)
            } else {
                self.upperWindowContent = []
            }
            self.upperCursorLine = 0
            self.upperCursorCol = 0
        }
    }

    nonisolated func setWindow(_ window: Int) {
        Task { @MainActor in
            if self.currentWindow == 0 {
                self.flushPendingText()
            }
            self.currentWindow = window
            if window == 1 {
                self.upperCursorLine = 0
                self.upperCursorCol = 0
            }
        }
    }

    nonisolated func eraseWindow(_ window: Int) {
        Task { @MainActor in
            if window == -1 || window == -2 || window == 0 {
                self.outputLines = []
                self.pendingText = ""
            }
            if window == -1 || window == -2 || window == 1 {
                for row in 0..<self.upperWindowContent.count {
                    for col in 0..<self.upperWindowContent[row].count {
                        self.upperWindowContent[row][col] = " "
                    }
                }
            }
            if window == -2 {
                self.upperWindowLines = 0
                self.upperWindowContent = []
            }
        }
    }

    nonisolated func setCursor(line: Int, column: Int) {
        Task { @MainActor in
            self.upperCursorLine = max(0, line - 1)
            self.upperCursorCol = max(0, column - 1)
        }
    }

    nonisolated func setTextStyle(_ style: Int) {
        // TODO: track current style for styled output
    }

    nonisolated func setColor(foreground: Int, background: Int) {
        // TODO: track colors
    }

    nonisolated func setBufferMode(_ flag: Bool) {
        if !flag {
            Task { @MainActor in
                self.flushPendingText()
            }
        }
    }

    nonisolated func soundEffect(number: Int, effect: Int, volume: Int) {
        // TODO: sound support
    }

    nonisolated func showMore() async {
        // For now, just continue. Voice mode will handle this differently.
    }

    // MARK: - Private helpers

    private func flushPendingText() {
        guard !pendingText.isEmpty else { return }
        // Split by newlines and append as output lines
        let text = pendingText
        pendingText = ""
        // Append to last line or create new ones
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            if i == 0 && !outputLines.isEmpty {
                // Append to last line
                let last = outputLines.removeLast()
                outputLines.append(OutputLine(text: last.text + String(part), style: .normal))
            } else {
                outputLines.append(OutputLine(text: String(part), style: .normal))
            }
        }
    }

    private func appendOutput(_ text: String) {
        pendingText += text
        flushPendingText()
    }

    private func writeToUpperWindow(_ text: String) {
        for ch in text {
            guard upperCursorLine < upperWindowContent.count else { break }
            guard upperCursorCol < upperWindowContent[upperCursorLine].count else {
                upperCursorLine += 1
                upperCursorCol = 0
                guard upperCursorLine < upperWindowContent.count else { break }
                continue
            }
            upperWindowContent[upperCursorLine][upperCursorCol] = ch
            upperCursorCol += 1
        }
    }

    /// Get the dictionary words for voice recognition vocabulary.
    func dictionaryWords() -> [String] {
        guard let proc = processor else { return [] }
        return proc.dictionary.allWords(decoder: proc.textDecoder)
    }
}
