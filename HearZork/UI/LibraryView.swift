import SwiftUI
import UniformTypeIdentifiers

/// Game library: browse catalog, manage downloaded games, import files.
/// Supports full voice navigation for visually impaired users.
struct LibraryView: View {
    var voice: VoiceCoordinator

    @State private var localGames: [GameFile] = []
    @State private var catalogGames: [CatalogGame] = []
    @State private var showFilePicker = false
    @State private var showURLInput = false
    @State private var showAbout = false
    @State private var urlText = ""
    @State private var selectedGame: GameFile?
    @State private var launchWithVoice = false
    @State private var errorMessage: String?
    @State private var downloader = GameDownloader()
    @State private var selectedTab = 0
    @State private var voiceListenTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                picker
                TabView(selection: $selectedTab) {
                    catalogTab.tag(0)
                    myGamesTab.tag(1)
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif

                // Voice listening indicator
                if voice.voiceEnabled {
                    voiceStatusBar
                }
            }
            .navigationTitle("HearZork")
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showURLInput) { urlInputSheet }
            .sheet(isPresented: $showAbout) { AboutView() }
            .alert("Error", isPresented: .init(
                get: { (errorMessage ?? downloader.errorMessage) != nil },
                set: { if !$0 { errorMessage = nil; downloader.errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil; downloader.errorMessage = nil }
            } message: {
                Text(errorMessage ?? downloader.errorMessage ?? "")
            }
            #if os(iOS)
            .fullScreenCover(item: $selectedGame) { game in
                gameScreen(for: game)
            }
            #else
            .sheet(item: $selectedGame) { game in
                gameScreen(for: game)
                    .frame(minWidth: 600, minHeight: 400)
            }
            #endif
            .task { await loadAll() }
            .onDisappear { voiceListenTask?.cancel() }
        }
    }

    // MARK: - Tab picker

    private var picker: some View {
        Picker("View", selection: $selectedTab) {
            Text("Browse Games").tag(0)
            Text("My Games").tag(1)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityLabel("Library sections")
    }

    // MARK: - Catalog tab

    private var catalogTab: some View {
        Group {
            if catalogGames.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading game catalog...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                catalogList
            }
        }
    }

    private var catalogList: some View {
        List {
            let classics = catalogGames.filter { $0.category == "classic" }
            let community = catalogGames.filter { $0.category == "community" }

            if !classics.isEmpty {
                Section("Classics") {
                    ForEach(classics) { game in
                        catalogRow(game)
                    }
                }
            }
            if !community.isEmpty {
                Section("Community Favorites") {
                    ForEach(community) { game in
                        catalogRow(game)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func catalogRow(_ game: CatalogGame) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.headline)
                Text(game.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(game.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("V\(game.version)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                    Text(game.year)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(game.difficulty.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            catalogAction(game)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.title) by \(game.author), \(game.year)")
        .accessibilityHint(game.isDownloaded ? "Double tap to play" : "Double tap to download")
    }

    @ViewBuilder
    private func catalogAction(_ game: CatalogGame) -> some View {
        if downloader.activeDownloads.contains(game.id) {
            ProgressView()
                .accessibilityLabel("Downloading")
        } else if game.isDownloaded {
            Button {
                launchCatalogGame(game)
            } label: {
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(game.title)")
        } else {
            Button {
                Task { await downloadAndRefresh(game) }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download \(game.title)")
        }
    }

    // MARK: - My Games tab

    private var myGamesTab: some View {
        Group {
            if localGames.isEmpty {
                emptyState
            } else {
                gameList
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No Games Yet")
                .font(.title2)
            Text("Browse the catalog, import a file, or enter a URL")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("Browse Catalog") { selectedTab = 0 }
                    .buttonStyle(.borderedProminent)
                Button("Import File") { showFilePicker = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private var gameList: some View {
        List {
            ForEach(Array(localGames.enumerated()), id: \.element.id) { _, game in
                gameRow(game)
            }
        }
    }

    private func gameRow(_ game: GameFile) -> some View {
        Button {
            selectedGame = game
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.displayName)
                        .font(.headline)
                    HStack(spacing: 12) {
                        Text("V\(game.version)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                        Text("Serial: \(game.serial)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Release \(game.release)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "play.fill")
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityLabel("\(game.displayName), version \(game.version)")
        .accessibilityHint("Double tap to play")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteGame(game)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - URL input sheet

    private var urlInputSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Enter the URL of a Z-machine story file (.z3, .z5, .z8)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)

                TextField("https://example.com/game.z5", text: $urlText)
                    .font(.system(.body, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Game URL")

                Button("Download") {
                    Task {
                        showURLInput = false
                        if let _ = await downloader.downloadFromURL(urlText) {
                            urlText = ""
                            loadLocalGames()
                            selectedTab = 1
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.isEmpty)

                Spacer()
            }
            .padding(.horizontal, 20)
            .navigationTitle("Load from URL")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showURLInput = false }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 12) {
                Button {
                    Task { await toggleVoice() }
                } label: {
                    Image(systemName: voice.voiceEnabled ? "mic.fill" : "mic.slash")
                }
                .accessibilityLabel(voice.voiceEnabled ? "Voice mode on" : "Voice mode off")
                .accessibilityHint("Double tap to toggle voice navigation")

                Menu {
                    Button("Import File", systemImage: "doc.badge.plus") {
                        showFilePicker = true
                    }
                    Button("Load from URL", systemImage: "link") {
                        showURLInput = true
                    }
                    Divider()
                    Button("About HearZork", systemImage: "info.circle") {
                        showAbout = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add game or view info")
            }
        }
    }

    // MARK: - Game screen

    @ViewBuilder
    private func gameScreen(for game: GameFile) -> some View {
        let vm = GameViewModel()
        GameScreen(vm: vm, game: game, voice: voice) {
            selectedGame = nil
            launchWithVoice = false
            // Restart voice listening in library if voice is still on
            if voice.voiceEnabled {
                startVoiceLoop()
            }
        }
        .onAppear {
            do {
                try vm.loadGame(from: game.url)
                // If launched via voice or voice is enabled, auto-enable voice in game
                if voice.voiceEnabled {
                    Task { await vm.setVoiceMode(true, coordinator: voice) }
                }
            } catch {
                errorMessage = "Failed to load game: \(error.localizedDescription)"
                selectedGame = nil
            }
        }
    }

    // MARK: - Voice status bar

    private var voiceStatusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: voice.isListening ? "waveform.circle.fill" : (voice.speechOutput.isSpeaking ? "speaker.wave.2.fill" : "mic.circle"))
                .font(.title3)
                .foregroundStyle(voice.isListening ? .green : (voice.speechOutput.isSpeaking ? .blue : .secondary))
                .symbolEffect(.pulse, isActive: voice.isListening)

            if let err = voice.speechInput.errorMessage {
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if voice.isListening {
                Text(voice.speechInput.partialResult.isEmpty ? "Listening — speak a command..." : voice.speechInput.partialResult)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else if voice.speechOutput.isSpeaking {
                Text("Speaking...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Voice mode active")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .accessibilityLabel(voice.isListening ? "Listening for voice command" : "Voice mode active")
    }

    // MARK: - Voice navigation

    private func toggleVoice() async {
        if voice.voiceEnabled {
            voice.disableVoice()
            voiceListenTask?.cancel()
            voiceListenTask = nil
        } else {
            let ok = await voice.enableVoice()
            if ok {
                startVoiceLoop()
            }
        }
    }

    private func startVoiceLoop() {
        voiceListenTask?.cancel()
        voiceListenTask = Task {
            // Welcome announcement
            await announceLibrary()
            // Voice command loop
            while !Task.isCancelled && voice.voiceEnabled {
                let command = await voice.listen()
                guard !Task.isCancelled, !command.isEmpty else { continue }
                await handleVoiceCommand(command)
            }
        }
    }

    private func announceLibrary() async {
        let downloadedCount = localGames.count
        let catalogCount = catalogGames.count

        var greeting = "Welcome to HearZork."
        if downloadedCount > 0 {
            greeting += " You have \(downloadedCount) game\(downloadedCount == 1 ? "" : "s") ready to play."
        }
        if catalogCount > 0 {
            greeting += " \(catalogCount) games available to browse."
        }
        greeting += " Say the name of a game to play it, or say help for commands."
        await voice.speak(greeting)
    }

    private func handleVoiceCommand(_ command: String) async {
        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Help
        if lower == "help" || lower == "commands" {
            await voice.speak(
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
            voice.disableVoice()
            voiceListenTask?.cancel()
            voiceListenTask = nil
            return
        }

        // List my games
        if lower == "list games" || lower == "my games" || lower == "list" {
            selectedTab = 1
            if localGames.isEmpty {
                await voice.speak("You don't have any downloaded games yet. Say browse to hear available games.")
            } else {
                let names = localGames.map(\.displayName).joined(separator: ". ")
                await voice.speak("Your games: \(names). Say a game name to play it.")
            }
            return
        }

        // Browse catalog
        if lower == "browse" || lower == "browse games" || lower == "catalog" || lower == "browse catalog" {
            selectedTab = 0
            if catalogGames.isEmpty {
                await voice.speak("The catalog is still loading. Please try again in a moment.")
            } else {
                await readCatalog()
            }
            return
        }

        // Download command
        if lower.hasPrefix("download ") {
            let gameName = String(lower.dropFirst("download ".count))
            await handleDownloadCommand(gameName)
            return
        }

        // Try to match as a game name to play
        if let game = findLocalGame(lower) {
            await voice.speak("Playing \(game.displayName).")
            selectedGame = game
            return
        }

        // Try matching catalog game that's downloaded
        if let catGame = findCatalogGame(lower), catGame.isDownloaded {
            launchCatalogGame(catGame)
            if selectedGame != nil {
                await voice.speak("Playing \(catGame.title).")
                return
            }
        }

        // Try matching catalog game that needs download
        if let catGame = findCatalogGame(lower), !catGame.isDownloaded {
            await voice.speak("\(catGame.title) is not downloaded yet. Downloading now.")
            await handleDownloadCommand(lower)
            return
        }

        // Didn't understand
        await voice.speak("I didn't understand \(command). Say help for available commands.")
    }

    private func readCatalog() async {
        let classics = catalogGames.filter { $0.category == "classic" }
        let community = catalogGames.filter { $0.category == "community" }

        if !classics.isEmpty {
            let names = classics.map { "\($0.title) by \($0.author)" }.joined(separator: ". ")
            await voice.speak("Classics: \(names).")
        }
        if !community.isEmpty {
            let names = community.map { "\($0.title) by \($0.author)" }.joined(separator: ". ")
            await voice.speak("Community favorites: \(names).")
        }
        await voice.speak("Say download and a game name to download, or say a game name to play.")
    }

    private func handleDownloadCommand(_ gameName: String) async {
        guard let catGame = findCatalogGame(gameName) else {
            await voice.speak("I couldn't find a game matching \(gameName). Say browse to hear available games.")
            return
        }

        if catGame.isDownloaded {
            await voice.speak("\(catGame.title) is already downloaded. Say \(catGame.title) to play it.")
            return
        }

        await voice.speak("Downloading \(catGame.title).")
        let ok = await downloader.download(catGame)
        if ok {
            loadLocalGames()
            await voice.speak("\(catGame.title) downloaded. Say \(catGame.title) to play it.")
        } else {
            await voice.speak("Download failed. \(downloader.errorMessage ?? "Please try again.")")
        }
    }

    private func findLocalGame(_ name: String) -> GameFile? {
        let lower = name.lowercased()
        // Exact match
        if let game = localGames.first(where: { $0.displayName.lowercased() == lower }) {
            return game
        }
        // Contains match
        if let game = localGames.first(where: { $0.displayName.lowercased().contains(lower) }) {
            return game
        }
        // Name contained in query
        if let game = localGames.first(where: { lower.contains($0.displayName.lowercased()) }) {
            return game
        }
        return nil
    }

    private func findCatalogGame(_ name: String) -> CatalogGame? {
        let lower = name.lowercased()
        // Exact title match
        if let game = catalogGames.first(where: { $0.title.lowercased() == lower }) {
            return game
        }
        // Title contained in query
        if let game = catalogGames.first(where: { lower.contains($0.title.lowercased()) }) {
            return game
        }
        // Query contained in title
        if let game = catalogGames.first(where: { $0.title.lowercased().contains(lower) }) {
            return game
        }
        return nil
    }

    // MARK: - Actions

    private func loadAll() async {
        loadLocalGames()
        let catalog = GameCatalog()
        catalogGames = await catalog.fetch()
        if catalogGames.isEmpty {
            let localPath = Bundle.main.path(forResource: "games", ofType: "xml")
                ?? "/Users/wohl/src/hearzork/games.xml"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)) {
                catalogGames = catalog.parse(data: data)
            }
        }
        // Auto-start voice: request authorization and begin listening
        if voice.voiceEnabled {
            let ok = await voice.enableVoice()
            if ok {
                startVoiceLoop()
            }
        }
    }

    private func downloadAndRefresh(_ game: CatalogGame) async {
        let ok = await downloader.download(game)
        if ok {
            loadLocalGames()
        }
    }

    private func launchCatalogGame(_ game: CatalogGame) {
        if let local = localGames.first(where: { $0.url.lastPathComponent == game.filename }) {
            voiceListenTask?.cancel()
            selectedGame = local
        } else {
            if let parsed = parseGameFile(game.localURL) {
                voiceListenTask?.cancel()
                selectedGame = parsed
            }
        }
    }

    private func loadLocalGames() {
        let dir = GameStorage.gamesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        localGames = files.compactMap { url -> GameFile? in
            let ext = url.pathExtension.lowercased()
            guard ext.hasPrefix("z") && ext.count <= 2 else { return nil }
            return parseGameFile(url)
        }.sorted { $0.displayName < $1.displayName }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                let dest = GameStorage.gamesDirectory.appendingPathComponent(url.lastPathComponent)
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: url, to: dest)
                } catch {
                    errorMessage = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            loadLocalGames()
            selectedTab = 1
        case .failure(let error):
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func deleteGame(_ game: GameFile) {
        try? FileManager.default.removeItem(at: game.url)
        loadLocalGames()
    }

    private func parseGameFile(_ url: URL) -> GameFile? {
        guard let data = try? Data(contentsOf: url),
              data.count >= 64 else { return nil }
        let version = Int(data[0x00])
        guard (1...8).contains(version), version != 6 else { return nil }
        let release = Int(data[0x02]) << 8 | Int(data[0x03])
        let serial = String((0x12...0x17).map { Character(UnicodeScalar(data[$0])) })
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return GameFile(
            url: url,
            displayName: name.prefix(1).uppercased() + name.dropFirst(),
            version: version,
            release: release,
            serial: serial
        )
    }

    static var gamesDirectory: URL { GameStorage.gamesDirectory }
}

// MARK: - GameFile model

struct GameFile: Identifiable {
    let id = UUID()
    let url: URL
    let displayName: String
    let version: Int
    let release: Int
    let serial: String
}

// MARK: - Game screen wrapper

struct GameScreen: View {
    let vm: GameViewModel
    let game: GameFile
    var voice: VoiceCoordinator
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ConsoleView(vm: vm)
                .navigationTitle(vm.gameName)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Library") {
                            vm.stopGame()
                            onDismiss()
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    await vm.setVoiceMode(!vm.voiceMode, coordinator: voice)
                                }
                            } label: {
                                Image(systemName: vm.voiceMode ? "mic.fill" : "mic.slash")
                            }
                            .accessibilityLabel(vm.voiceMode ? "Voice mode on" : "Voice mode off")
                            .accessibilityHint("Double tap to toggle voice mode")

                            Menu {
                                fontSizeControls
                                Divider()
                                Toggle("Show Console", isOn: Binding(
                                    get: { vm.showConsole },
                                    set: { vm.showConsole = $0 }
                                ))
                                Toggle("Speech Output", isOn: Binding(
                                    get: { vm.speechOutput.isEnabled },
                                    set: { vm.speechOutput.isEnabled = $0 }
                                ))
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel("Settings")
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var fontSizeControls: some View {
        Button("Bigger Text") {
            vm.fontSize = min(vm.fontSize + 4, 72)
        }
        Button("Smaller Text") {
            vm.fontSize = max(vm.fontSize - 4, 12)
        }
        Divider()
        Text("Size: \(Int(vm.fontSize))pt")
    }
}
