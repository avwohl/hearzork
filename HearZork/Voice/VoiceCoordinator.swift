import SwiftUI

/// App-level voice coordinator shared between the library and game screens.
///
/// Owns the single shared AudioGraph (echo-cancelled engine) and wires it into
/// both the recogniser and the TTS player. The library command loop is a plain
/// async `Task` on the main actor — no background GCD queue, no
/// `DispatchQueue.main.sync`, no semaphores, no wall-clock sleeps. The old
/// design needed all of that to work around the missing echo cancellation; with
/// AEC the loop is just speak → listen → handle.
@MainActor
@Observable
final class VoiceCoordinator {
    let audio = AudioGraph()
    let speechInput = SpeechInput()
    let speechOutput = SpeechOutput()

    var isAuthorized = false
    var isListening = false

    private var _voiceEnabled = true
    var voiceEnabled: Bool {
        get { _voiceEnabled }
        set { _voiceEnabled = newValue; UserDefaults.standard.set(newValue, forKey: "voiceEnabled") }
    }

    // Library loop data, set by LibraryView.
    var libraryLocalGames: [GameFile] = []
    var libraryCatalogGames: [CatalogGame] = []
    var onPlayGame: (@MainActor (GameFile) -> Void)?
    var onDownloadGame: (@MainActor (CatalogGame, @escaping (Bool) -> Void) -> Void)?
    var onSelectTab: (@MainActor (Int) -> Void)?
    var onRefreshLocalGames: (@MainActor () -> Void)?

    private var loopTask: Task<Void, Never>?

    init() {
        speechInput.audio = audio
        speechOutput.audio = audio
        if UserDefaults.standard.object(forKey: "voiceEnabled") != nil {
            _voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
        }
    }

    func enableVoice() async -> Bool {
        if !isAuthorized {
            guard await speechInput.requestAuthorization() else { return false }
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

    func stopSpeaking() { speechOutput.stop() }

    // MARK: - Library voice loop

    func startLibraryLoop() {
        stopLibraryLoop()
        let localGames = libraryLocalGames
        let catalogCount = libraryCatalogGames.count
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.speechOutput.speakAndWait(self.buildAnnouncement(localGames: localGames, catalogCount: catalogCount))
            while !Task.isCancelled && self.voiceEnabled {
                self.isListening = true
                let command = await self.speechInput.listen()
                self.isListening = false
                if Task.isCancelled { break }
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                await self.handleLibraryCommand(trimmed)
            }
        }
    }

    func stopLibraryLoop() {
        loopTask?.cancel()
        loopTask = nil
        speechInput.stopListeningCore()
        speechOutput.stop()
    }

    // MARK: - Library command handling

    private func handleLibraryCommand(_ command: String) async {
        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if lower == "help" || lower == "commands" {
            var help = ""
            if !libraryLocalGames.isEmpty {
                help += "Your games: \(libraryLocalGames.map(\.displayName).joined(separator: ", ")). Say a game name to play it. "
            } else {
                help += "Say the name of a game to play it. "
            }
            help += "Say download and a game name to download it. Say browse to hear the catalog. Say voice off to disable voice mode."
            await speechOutput.speakAndWait(help)
            return
        }

        if lower == "voice off" || lower == "stop voice" || lower == "disable voice" {
            disableVoice()
            return
        }

        if lower == "list games" || lower == "my games" || lower == "list" {
            onSelectTab?(1)
            if libraryLocalGames.isEmpty {
                await speechOutput.speakAndWait("You don't have any downloaded games yet. Say browse to hear available games.")
            } else {
                await speechOutput.speakAndWait("Your games: \(libraryLocalGames.map(\.displayName).joined(separator: ". ")). Say a game name to play it.")
            }
            return
        }

        if lower == "browse" || lower == "browse games" || lower == "catalog" || lower == "browse catalog" {
            onSelectTab?(0)
            if libraryCatalogGames.isEmpty {
                await speechOutput.speakAndWait("The catalog is still loading. Please try again in a moment.")
            } else {
                await readCatalog(libraryCatalogGames)
            }
            return
        }

        if lower.hasPrefix("download ") {
            await handleDownload(String(lower.dropFirst("download ".count)))
            return
        }

        if let game = findLocalGame(lower, in: libraryLocalGames) {
            await speechOutput.speakAndWait("Playing \(game.displayName).")
            onPlayGame?(game)
            return
        }

        let catalog = libraryCatalogGames
        if let catGame = findCatalogGame(lower, in: catalog), catGame.isDownloaded,
           let local = libraryLocalGames.first(where: { $0.url.lastPathComponent == catGame.filename }) {
            await speechOutput.speakAndWait("Playing \(catGame.title).")
            onPlayGame?(local)
            return
        }

        if let catGame = findCatalogGame(lower, in: catalog), !catGame.isDownloaded {
            await speechOutput.speakAndWait("\(catGame.title) is not downloaded yet. Downloading now.")
            await handleDownload(lower)
            return
        }

        await speechOutput.speakAndWait("I didn't understand \(command). Say help for available commands.")
    }

    private func readCatalog(_ catalog: [CatalogGame]) async {
        let classics = catalog.filter { $0.category == "classic" }
        let community = catalog.filter { $0.category == "community" }
        if !classics.isEmpty {
            await speechOutput.speakAndWait("Classics: \(classics.map { "\($0.title) by \($0.author)" }.joined(separator: ". ")).")
        }
        if !community.isEmpty {
            await speechOutput.speakAndWait("Community favorites: \(community.map { "\($0.title) by \($0.author)" }.joined(separator: ". ")).")
        }
        await speechOutput.speakAndWait("Say download and a game name to download, or say a game name to play.")
    }

    private func handleDownload(_ gameName: String) async {
        guard let catGame = findCatalogGame(gameName, in: libraryCatalogGames) else {
            await speechOutput.speakAndWait("I couldn't find a game matching \(gameName). Say browse to hear available games.")
            return
        }
        if catGame.isDownloaded {
            await speechOutput.speakAndWait("\(catGame.title) is already downloaded. Say \(catGame.title) to play it.")
            return
        }
        await speechOutput.speakAndWait("Downloading \(catGame.title).")
        let success = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if let onDownloadGame {
                onDownloadGame(catGame) { cont.resume(returning: $0) }
            } else {
                cont.resume(returning: false)
            }
        }
        if success {
            onRefreshLocalGames?()
            await speechOutput.speakAndWait("\(catGame.title) downloaded. Say \(catGame.title) to play it.")
        } else {
            await speechOutput.speakAndWait("Download failed. Please try again.")
        }
    }

    // MARK: - Announcement + fuzzy matching

    private func buildAnnouncement(localGames: [GameFile], catalogCount: Int) -> String {
        var greeting = "Welcome to HearZork."
        if !localGames.isEmpty {
            greeting += " You have \(localGames.count) game\(localGames.count == 1 ? "" : "s") ready to play: \(localGames.map(\.displayName).joined(separator: ", "))."
            greeting += " Say the name of a game to play it."
        }
        if catalogCount > 0 { greeting += " \(catalogCount) games available to browse." }
        greeting += " Say help for commands."
        return greeting
    }

    private func findLocalGame(_ name: String, in games: [GameFile]) -> GameFile? {
        let lower = name.lowercased()
        if let g = games.first(where: { $0.displayName.lowercased() == lower }) { return g }
        if let g = games.first(where: { $0.displayName.lowercased().contains(lower) }) { return g }
        if let g = games.first(where: { lower.contains($0.displayName.lowercased()) }) { return g }
        let stripped = lower.filter { $0.isLetter || $0.isNumber }
        for g in games {
            let gs = g.displayName.lowercased().filter { $0.isLetter || $0.isNumber }
            if stripped == gs || stripped.contains(gs) || gs.contains(stripped) { return g }
        }
        let romanized = Self.romanizeNumbers(lower)
        if romanized != lower {
            if let g = games.first(where: { $0.displayName.lowercased().contains(romanized) }) { return g }
            if let g = games.first(where: { romanized.contains($0.displayName.lowercased()) }) { return g }
        }
        return nil
    }

    private func findCatalogGame(_ name: String, in games: [CatalogGame]) -> CatalogGame? {
        let lower = name.lowercased()
        if let g = games.first(where: { $0.title.lowercased() == lower }) { return g }
        if let g = games.first(where: { lower.contains($0.title.lowercased()) }) { return g }
        if let g = games.first(where: { $0.title.lowercased().contains(lower) }) { return g }
        let stripped = lower.filter { $0.isLetter || $0.isNumber }
        for g in games {
            let gs = g.title.lowercased().filter { $0.isLetter || $0.isNumber }
            if stripped == gs || gs.contains(stripped) { return g }
        }
        let romanized = Self.romanizeNumbers(lower)
        if romanized != lower, let g = games.first(where: { $0.title.lowercased().contains(romanized) }) { return g }
        return nil
    }

    private static func romanizeNumbers(_ text: String) -> String {
        let map = ["10": "x", "9": "ix", "8": "viii", "7": "vii", "6": "vi",
                   "5": "v", "4": "iv", "3": "iii", "2": "ii", "1": "i"]
        return text.split(separator: " ").map { map[String($0)] ?? String($0) }.joined(separator: " ")
    }
}
