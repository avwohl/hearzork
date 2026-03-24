import Foundation

/// Protocol for Z-machine I/O. Implementations handle text output, input,
/// status bar, and screen management. The voice layer and console are both
/// implementations of this protocol.
protocol IOSystem: AnyObject {
    /// Print a string to the lower window.
    func print(_ text: String)

    /// Print to the upper (status) window.
    func printToUpper(_ text: String)

    /// Read a line of input. Returns the entered text (lowercase).
    func readLine(maxChars: Int) async -> String

    /// Read a single character. Returns the ZSCII code.
    func readChar() async -> UInt8

    /// Show the status bar (V1-3). Left side: location name. Right side: score/turns or time.
    func showStatusBar(location: String, rightSide: String)

    /// Split the screen into upper and lower windows.
    func splitWindow(lines: Int)

    /// Select the active window (0=lower, 1=upper).
    func setWindow(_ window: Int)

    /// Erase a window (-1=both, -2=both and unsplit, 0=lower, 1=upper).
    func eraseWindow(_ window: Int)

    /// Set cursor position in the upper window.
    func setCursor(line: Int, column: Int)

    /// Set text style (0=roman, 1=reverse, 2=bold, 4=italic, 8=fixed).
    func setTextStyle(_ style: Int)

    /// Set text colors (foreground, background). Color numbers per Z-spec.
    func setColor(foreground: Int, background: Int)

    /// Enable or disable buffered output.
    func setBufferMode(_ flag: Bool)

    /// Play a sound effect (number, effect, volume).
    func soundEffect(number: Int, effect: Int, volume: Int)

    /// Called when the game requests a [MORE] prompt.
    func showMore() async
}

/// Minimal test harness that records output and provides scripted input.
final class TestIO: IOSystem {
    var outputBuffer: String = ""
    var upperBuffer: String = ""
    var inputLines: [String] = []
    var inputChars: [UInt8] = []
    private var inputIndex = 0
    private var charIndex = 0
    var statusLocation = ""
    var statusRight = ""
    var currentWindow = 0
    var upperLines = 0

    func print(_ text: String) {
        if currentWindow == 0 {
            outputBuffer += text
        } else {
            upperBuffer += text
        }
    }

    func printToUpper(_ text: String) {
        upperBuffer += text
    }

    func readLine(maxChars: Int) async -> String {
        guard inputIndex < inputLines.count else { return "" }
        let line = inputLines[inputIndex]
        inputIndex += 1
        return String(line.prefix(maxChars)).lowercased()
    }

    func readChar() async -> UInt8 {
        guard charIndex < inputChars.count else { return 13 }
        let ch = inputChars[charIndex]
        charIndex += 1
        return ch
    }

    func showStatusBar(location: String, rightSide: String) {
        statusLocation = location
        statusRight = rightSide
    }

    func splitWindow(lines: Int) { upperLines = lines }
    func setWindow(_ window: Int) { currentWindow = window }
    func eraseWindow(_ window: Int) {
        if window == -1 || window == -2 || window == 0 { outputBuffer = "" }
        if window == -1 || window == -2 || window == 1 { upperBuffer = "" }
    }
    func setCursor(line: Int, column: Int) {}
    func setTextStyle(_ style: Int) {}
    func setColor(foreground: Int, background: Int) {}
    func setBufferMode(_ flag: Bool) {}
    func soundEffect(number: Int, effect: Int, volume: Int) {}
    func showMore() async {}
}
