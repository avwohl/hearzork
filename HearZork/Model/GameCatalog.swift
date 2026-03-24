import Foundation

/// A game entry from the remote games.xml catalog.
struct CatalogGame: Identifiable, Sendable {
    let id: String
    let title: String
    let author: String
    let year: String
    let description: String
    let filename: String
    let version: Int
    let sha256: String
    let url: URL
    let copyrightURL: URL
    let category: String
    let difficulty: String

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    var localURL: URL {
        GameStorage.gamesDirectory.appendingPathComponent(filename)
    }
}

/// Parses the games.xml catalog from a remote or local source.
final class GameCatalog: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var games: [CatalogGame] = []
    private var currentElement = ""
    private var currentAttrs: [String: String] = [:]
    private var currentText = ""

    static let catalogURL = URL(string: "https://raw.githubusercontent.com/avwohl/hearzork/main/games.xml")!

    /// Fetch and parse the catalog from GitHub.
    func fetch() async -> [CatalogGame] {
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.catalogURL)
            return parse(data: data)
        } catch {
            // Fall back to bundled catalog
            if let bundledURL = Bundle.main.url(forResource: "games", withExtension: "xml"),
               let data = try? Data(contentsOf: bundledURL) {
                return parse(data: data)
            }
            return []
        }
    }

    /// Parse catalog XML data.
    func parse(data: Data) -> [CatalogGame] {
        games = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return games
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        currentElement = element
        if element == "game" {
            currentAttrs = [:]
            if let id = attributes["id"] {
                currentAttrs["id"] = id
            }
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch element {
        case "title", "author", "year", "description", "filename",
             "version", "sha256", "url", "copyright_url", "category", "difficulty":
            currentAttrs[element] = text
        case "game":
            if let id = currentAttrs["id"],
               let title = currentAttrs["title"],
               let author = currentAttrs["author"],
               let filename = currentAttrs["filename"],
               let urlStr = currentAttrs["url"],
               let url = URL(string: urlStr),
               let copyrightStr = currentAttrs["copyright_url"],
               let copyrightURL = URL(string: copyrightStr) {
                let game = CatalogGame(
                    id: id,
                    title: title,
                    author: author,
                    year: currentAttrs["year"] ?? "",
                    description: currentAttrs["description"] ?? "",
                    filename: filename,
                    version: Int(currentAttrs["version"] ?? "5") ?? 5,
                    sha256: currentAttrs["sha256"] ?? "",
                    url: url,
                    copyrightURL: copyrightURL,
                    category: currentAttrs["category"] ?? "community",
                    difficulty: currentAttrs["difficulty"] ?? "intermediate"
                )
                games.append(game)
            }
        default:
            break
        }
        currentElement = ""
    }
}
