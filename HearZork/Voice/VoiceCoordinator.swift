import SwiftUI
import AVFoundation

/// App-level voice coordinator shared between library and game screens.
///
/// The library voice loop runs on a dedicated background DispatchQueue to avoid
/// MainActor stalling issues with Swift concurrency on macOS. All speech I/O
/// in the loop uses blocking synchronous calls — no `await` in the voice path.
@MainActor
@Observable
final class VoiceCoordinator: @unchecked Sendable {
    let speechInput = SpeechInput()
    let speechOutput = SpeechOutput()

    var isAuthorized = false
    var isListening = false

    /// Persisted in UserDefaults. Defaults to true (voice-first app).
    /// Backed by nonisolated(unsafe) storage so the background voice loop can read it.
    @ObservationIgnored nonisolated(unsafe) private var _voiceEnabled = true
    var voiceEnabled: Bool {
        get { _voiceEnabled }
        set {
            _voiceEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: "voiceEnabled")
        }
    }

    // MARK: - Library voice loop data

    /// Current game lists — set by LibraryView, read by voice loop.
    @ObservationIgnored nonisolated(unsafe) var libraryLocalGames: [GameFile] = []
    @ObservationIgnored nonisolated(unsafe) var libraryCatalogGames: [CatalogGame] = []

    /// Callbacks for library actions — set by LibraryView before starting the loop.
    @ObservationIgnored nonisolated(unsafe) var onPlayGame: (@MainActor (GameFile) -> Void)?
    @ObservationIgnored nonisolated(unsafe) var onDownloadGame: (@MainActor (CatalogGame, @escaping (Bool) -> Void) -> Void)?
    @ObservationIgnored nonisolated(unsafe) var onSelectTab: (@MainActor (Int) -> Void)?
    @ObservationIgnored nonisolated(unsafe) var onRefreshLocalGames: (@MainActor () -> Void)?

    /// Voice loop control flag.
    @ObservationIgnored nonisolated(unsafe) private var _loopActive = false

    init() {
        if UserDefaults.standard.object(forKey: "voiceEnabled") != nil {
            _voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
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
        stopLibraryLoop()
        speechInput.stopListening()
        speechOutput.stop()
    }

    // MARK: - Library voice loop

    /// Start the library voice loop on a background GCD queue.
    /// The loop announces the library, then repeatedly listens for commands.
    func startLibraryLoop() {
        stopLibraryLoop()
        _loopActive = true

        let localCount = libraryLocalGames.count
        let catalogCount = libraryCatalogGames.count

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Welcome announcement
            let greeting = buildAnnouncement(localCount: localCount, catalogCount: catalogCount)
            speakSync(greeting)

            // Command loop
            while self._loopActive && self._voiceEnabled {
                let command = listenSync()
                guard _loopActive, !command.isEmpty else { continue }
                handleLibraryCommand(command)
            }
        }
    }

    /// Stop the library voice loop.
    func stopLibraryLoop() {
        _loopActive = false
        speechInput.stopListeningCore()
        speechOutput.stop()
    }

    // MARK: - Synchronous voice I/O (background queue only)

    /// Speak text and block until done. Must be called from a background queue.
    nonisolated func speakSync(_ text: String) {
        // Stop mic and start speech synchronously on main — ensures isListening
        // is false and speech has started before we begin polling.
        speechInput.stopListeningCore()
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.speechInput.isListening = false
                self.speechOutput.speak(text)
            }
        }
        // Wait for speech to start
        Thread.sleep(forTimeInterval: 0.1)
        // Poll until speech finishes
        while speechOutput.synthesizer.isSpeaking {
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Echo gap — prevent mic from picking up trailing speaker output
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Listen for a command and block until result. Must be called from a background queue.
    nonisolated func listenSync() -> String {
        // Make sure TTS is done
        while speechOutput.synthesizer.isSpeaking {
            Thread.sleep(forTimeInterval: 0.05)
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.isListening = true }
        }

        let result = speechInput.listenSync()

        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.isListening = false }
        }

        return result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stop any current speech.
    func stopSpeaking() {
        speechOutput.stop()
    }

    // MARK: - Library command handling (runs on background queue)

    nonisolated private func buildAnnouncement(localCount: Int, catalogCount: Int) -> String {
        var greeting = "Welcome to HearZork."
        if localCount > 0 {
            greeting += " You have \(localCount) game\(localCount == 1 ? "" : "s") ready to play."
        }
        if catalogCount > 0 {
            greeting += " \(catalogCount) games available to browse."
        }
        greeting += " Say the name of a game to play it, or say help for commands."
        return greeting
    }

    nonisolated private func handleLibraryCommand(_ command: String) {
        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Help
        if lower == "help" || lower == "commands" {
            speakSync(
                "Say the name of a game to play it. " +
                "Say download and a game name to download it. " +
                "Say list games to hear your downloaded games. " +
                "Say browse to hear the catalog. " +
                "Say voice off to disable voice mode."
            )
            return
        }

        // Voice off
        if lower == "voice off" || lower == "stop voice" || lower == "disable voice" {
            _loopActive = false
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.disableVoice() }
            }
            return
        }

        // List my games
        if lower == "list games" || lower == "my games" || lower == "list" {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onSelectTab?(1) }
            }
            let games = libraryLocalGames
            if games.isEmpty {
                speakSync("You don't have any downloaded games yet. Say browse to hear available games.")
            } else {
                let names = games.map(\.displayName).joined(separator: ". ")
                speakSync("Your games: \(names). Say a game name to play it.")
            }
            return
        }

        // Browse catalog
        if lower == "browse" || lower == "browse games" || lower == "catalog" || lower == "browse catalog" {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onSelectTab?(0) }
            }
            let catalog = libraryCatalogGames
            if catalog.isEmpty {
                speakSync("The catalog is still loading. Please try again in a moment.")
            } else {
                readCatalogSync(catalog)
            }
            return
        }

        // Download command
        if lower.hasPrefix("download ") {
            let gameName = String(lower.dropFirst("download ".count))
            handleDownloadSync(gameName)
            return
        }

        // Try to match as a local game name to play
        let locals = libraryLocalGames
        if let game = findLocalGame(lower, in: locals) {
            speakSync("Playing \(game.displayName).")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onPlayGame?(game) }
            }
            return
        }

        // Try matching catalog game that's already downloaded
        let catalog = libraryCatalogGames
        if let catGame = findCatalogGame(lower, in: catalog), catGame.isDownloaded {
            speakSync("Playing \(catGame.title).")
            // Find the local file for this catalog game
            if let local = locals.first(where: { $0.url.lastPathComponent == catGame.filename }) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.onPlayGame?(local) }
                }
            }
            return
        }

        // Try matching catalog game that needs download
        if let catGame = findCatalogGame(lower, in: catalog), !catGame.isDownloaded {
            speakSync("\(catGame.title) is not downloaded yet. Downloading now.")
            handleDownloadSync(lower)
            return
        }

        // Didn't understand
        speakSync("I didn't understand \(command). Say help for available commands.")
    }

    nonisolated private func readCatalogSync(_ catalog: [CatalogGame]) {
        let classics = catalog.filter { $0.category == "classic" }
        let community = catalog.filter { $0.category == "community" }

        if !classics.isEmpty {
            let names = classics.map { "\($0.title) by \($0.author)" }.joined(separator: ". ")
            speakSync("Classics: \(names).")
        }
        if !community.isEmpty {
            let names = community.map { "\($0.title) by \($0.author)" }.joined(separator: ". ")
            speakSync("Community favorites: \(names).")
        }
        speakSync("Say download and a game name to download, or say a game name to play.")
    }

    nonisolated private func handleDownloadSync(_ gameName: String) {
        let catalog = libraryCatalogGames
        guard let catGame = findCatalogGame(gameName, in: catalog) else {
            speakSync("I couldn't find a game matching \(gameName). Say browse to hear available games.")
            return
        }

        if catGame.isDownloaded {
            speakSync("\(catGame.title) is already downloaded. Say \(catGame.title) to play it.")
            return
        }

        speakSync("Downloading \(catGame.title).")

        // Download on main thread via callback, block until done
        let sem = DispatchSemaphore(value: 0)
        let box = SendableBox(false)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.onDownloadGame?(catGame) { ok in
                    box.value = ok
                    sem.signal()
                }
            }
        }
        sem.wait()
        let success = box.value

        if success {
            // Refresh game list
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onRefreshLocalGames?() }
            }
            // Brief pause for list to refresh
            Thread.sleep(forTimeInterval: 0.2)
            speakSync("\(catGame.title) downloaded. Say \(catGame.title) to play it.")
        } else {
            speakSync("Download failed. Please try again.")
        }
    }

    nonisolated private func findLocalGame(_ name: String, in games: [GameFile]) -> GameFile? {
        let lower = name.lowercased()
        if let game = games.first(where: { $0.displayName.lowercased() == lower }) {
            return game
        }
        if let game = games.first(where: { $0.displayName.lowercased().contains(lower) }) {
            return game
        }
        if let game = games.first(where: { lower.contains($0.displayName.lowercased()) }) {
            return game
        }
        return nil
    }

    nonisolated private func findCatalogGame(_ name: String, in games: [CatalogGame]) -> CatalogGame? {
        let lower = name.lowercased()
        if let game = games.first(where: { $0.title.lowercased() == lower }) {
            return game
        }
        if let game = games.first(where: { lower.contains($0.title.lowercased()) }) {
            return game
        }
        if let game = games.first(where: { $0.title.lowercased().contains(lower) }) {
            return game
        }
        return nil
    }
}

/// Thread-safe mutable box for passing values across isolation boundaries.
private final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
