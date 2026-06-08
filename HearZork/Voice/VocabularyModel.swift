@preconcurrency import Speech
import Foundation

/// Turns a game's Z-machine dictionary into recognition biasing: an on-device
/// custom language model (iOS 17+) plus a contextual-strings fallback, and a
/// truncation-aware matcher.
///
/// Truncation is handled in the parser, never the recognizer (the Z-machine
/// only matches the first 6 (V1-3) / 9 (V4+) Z-characters of each word, and it
/// truncates typed/recognized input itself at lookup). So we recognise full
/// words and pass them straight through; we only use truncation to test whether
/// a recognised token is in-vocabulary.
final class VocabularyModel: @unchecked Sendable {
    let words: [String]
    let version: Int
    private let wordSet: Set<String>

    /// Up to ~100 of the most unusual words, for the no-custom-LM fallback.
    let contextualStrings: [String]

    /// Prepared custom-LM configuration (iOS 17+), once built. Stored as Any to
    /// keep the type out of pre-iOS-17 paths.
    private var preparedConfiguration: Any?
    private let identifier: String

    var significantChars: Int { version <= 3 ? 6 : 9 }

    init(words rawWords: [String], version: Int, identifier: String = "com.awohl.hearzork.game") {
        self.version = version
        self.identifier = identifier
        // Clean: lowercase, drop empties and pure separators/punctuation.
        let cleaned = rawWords
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { w in !w.isEmpty && w.contains(where: { $0.isLetter }) }
        self.words = cleaned
        self.wordSet = Set(cleaned)
        // Rank the fallback contextual strings by "unusualness": longer / less
        // common words first; cap at 100 (the documented contextualStrings limit).
        self.contextualStrings = Array(
            cleaned.filter { $0.count >= 4 }
                   .sorted { $0.count > $1.count }
                   .prefix(100)
        )
    }

    // MARK: - Matching

    /// Truncate a recognised token the way the Z-machine will, for membership.
    func truncated(_ token: String) -> String {
        String(token.lowercased().prefix(significantChars))
    }

    /// True if a recognised token resolves to a dictionary word.
    func contains(_ token: String) -> Bool {
        let t = truncated(token)
        if wordSet.contains(token.lowercased()) { return true }
        return words.contains { truncated($0) == t }
    }

    /// Default policy: pass the recognised phrase straight through (the parser
    /// truncates at lookup). Callers may use `contains` to score alternatives.
    func canonicalize(_ phrase: String) -> String {
        phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Custom language model

    /// Build + prepare the on-device custom LM off the main thread. Best-effort:
    /// on any failure we silently fall back to contextualStrings.
    func prepareLanguageModel() async {
        guard #available(iOS 17.0, macOS 14.0, *), !words.isEmpty else { return }
        do {
            let data = SFCustomLanguageModelData(
                locale: Locale(identifier: "en_US"),
                identifier: identifier,
                version: "1.0"
            ) {
                for w in words.prefix(2000) {
                    SFCustomLanguageModelData.PhraseCount(phrase: w, count: 10)
                }
            }
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let assetURL = caches.appendingPathComponent("hz-lm-\(abs(identifier.hashValue)).bin")
            try await data.export(to: assetURL)

            let lmURL = caches.appendingPathComponent("hz-lm-\(abs(identifier.hashValue)).prepared")
            let config = SFSpeechLanguageModel.Configuration(languageModel: lmURL)
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(
                for: assetURL, clientIdentifier: identifier, configuration: config)
            self.preparedConfiguration = config
        } catch {
            self.preparedConfiguration = nil
        }
    }

    /// Apply biasing to a recognition request: the custom LM if prepared,
    /// otherwise the contextual-strings fallback.
    func apply(to request: SFSpeechRecognitionRequest, onDeviceAvailable: Bool) {
        if onDeviceAvailable, #available(iOS 17.0, macOS 14.0, *),
           let config = preparedConfiguration as? SFSpeechLanguageModel.Configuration {
            request.requiresOnDeviceRecognition = true
            request.customizedLanguageModel = config
        } else {
            request.contextualStrings = contextualStrings
        }
    }
}
