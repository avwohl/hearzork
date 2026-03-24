import Foundation
import CryptoKit

/// Downloads game files from URLs with SHA-256 verification.
@MainActor
@Observable
final class GameDownloader {
    var activeDownloads: Set<String> = []
    var progress: [String: Double] = [:]
    var errorMessage: String?

    /// Download a game from the catalog.
    func download(_ game: CatalogGame) async -> Bool {
        guard !activeDownloads.contains(game.id) else { return false }
        activeDownloads.insert(game.id)
        progress[game.id] = 0
        defer {
            activeDownloads.remove(game.id)
            progress.removeValue(forKey: game.id)
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: game.url)
            progress[game.id] = 0.8

            // Verify SHA-256 if provided
            if !game.sha256.isEmpty {
                let hash = SHA256.hash(data: data)
                let hashString = hash.map { String(format: "%02x", $0) }.joined()
                guard hashString == game.sha256 else {
                    errorMessage = "Checksum mismatch for \(game.title). File may be corrupted."
                    return false
                }
            }
            progress[game.id] = 0.9

            // Save to games directory
            let dest = game.localURL
            try data.write(to: dest)
            progress[game.id] = 1.0
            return true
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Download a game from an arbitrary URL.
    func downloadFromURL(_ urlString: String) async -> URL? {
        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL"
            return nil
        }
        return await downloadFromURL(url)
    }

    /// Download a game from an arbitrary URL.
    func downloadFromURL(_ url: URL) async -> URL? {
        let filename = url.lastPathComponent
        guard !filename.isEmpty else {
            errorMessage = "Could not determine filename from URL"
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard data.count >= 64 else {
                errorMessage = "File too small to be a Z-machine story"
                return nil
            }
            // Basic Z-machine header check
            let version = Int(data[0])
            guard (1...8).contains(version), version != 6 else {
                errorMessage = "Not a supported Z-machine file (version \(Int(data[0])))"
                return nil
            }

            let dest = GameStorage.gamesDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try data.write(to: dest)
            return dest
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            return nil
        }
    }
}
