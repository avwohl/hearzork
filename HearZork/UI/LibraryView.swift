import SwiftUI
import UniformTypeIdentifiers

/// Game library: lists imported .z files and lets users add new ones.
struct LibraryView: View {
    @State private var games: [GameFile] = []
    @State private var showFilePicker = false
    @State private var selectedGame: GameFile?
    @State private var activeVM: GameViewModel?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if games.isEmpty {
                    emptyState
                } else {
                    gameList
                }
            }
            .navigationTitle("HearZork")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Game", systemImage: "plus") {
                        showFilePicker = true
                    }
                    .accessibilityLabel("Import a game file")
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
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
            .onAppear { loadGames() }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Games")
                .font(.title2)
            Text("Tap + to import a Z-machine story file (.z3, .z5, .z8)")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Import Game") {
                showFilePicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Game list

    private var gameList: some View {
        List {
            ForEach(Array(games.enumerated()), id: \.element.id) { _, game in
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

    // MARK: - Game screen

    @ViewBuilder
    private func gameScreen(for game: GameFile) -> some View {
        let vm = GameViewModel()
        GameScreen(vm: vm, game: game) {
            selectedGame = nil
        }
        .onAppear {
            do {
                try vm.loadGame(from: game.url)
            } catch {
                errorMessage = "Failed to load game: \(error.localizedDescription)"
                selectedGame = nil
            }
        }
    }

    // MARK: - File management

    private func loadGames() {
        let dir = Self.gamesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        games = files.compactMap { url -> GameFile? in
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
                let dest = Self.gamesDirectory.appendingPathComponent(url.lastPathComponent)
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: url, to: dest)
                } catch {
                    errorMessage = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            loadGames()
        case .failure(let error):
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func deleteGame(_ game: GameFile) {
        try? FileManager.default.removeItem(at: game.url)
        loadGames()
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

    static var gamesDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Games")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
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
                                    await vm.setVoiceMode(!vm.voiceMode)
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
